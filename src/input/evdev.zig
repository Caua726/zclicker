const std = @import("std");
const backend = @import("../backend.zig");
const lx = @import("../platform/linux.zig");

const InputBackend = backend.InputBackend;
const TriggerEvent = backend.TriggerEvent;

const MAX_EVENT_NODES: usize = 64;

/// EVIOCGRAB: grab/release exclusive access to the device. arg 1 grabs, 0 releases.
const EVIOCGRAB = lx.iow('E', 0x90, @sizeOf(c_int));

fn eviocgbit(ev: u32, len: u32) u32 {
    return lx.ior('E', 0x20 + ev, len);
}
fn eviocgname(len: u32) u32 {
    return lx.ior('E', 0x06, len);
}

/// Linux input backend: reads button events straight from `/dev/input/eventX`.
/// Works under Wayland because it taps the kernel input layer, below the
/// compositor. v1 is passive (read-only): it does not grab the device, so the
/// side buttons still perform their normal back/forward action.
pub const LinuxEvdev = struct {
    fd: std.posix.fd_t,
    name_buf: [256]u8 = undefined,
    name_len: usize = 0,
    // Trigger events drained from one read, served one per nextEvent call.
    pending: [64]TriggerEvent = undefined,
    pending_len: usize = 0,
    pending_idx: usize = 0,
    codes: []const u16 = &.{},
    suppress: bool = false,
    passthrough_fd: std.posix.fd_t = -1,

    pub fn init(device: ?[]const u8, codes: []const u16, suppress: bool) !LinuxEvdev {
        var self = LinuxEvdev{ .fd = -1, .codes = codes, .suppress = suppress };
        self.fd = if (device) |path| blk: {
            var zbuf: [256]u8 = undefined;
            const pz = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{path}, 0) catch return error.OpenFailed;
            break :blk try lx.openRdonlyNonblock(pz);
        } else try findDevice(codes);
        errdefer lx.closeFd(self.fd);
        self.name_len = nameInto(self.fd, &self.name_buf);

        if (suppress) {
            // Grab the physical device so its events stop reaching the compositor.
            if (@as(isize, @bitCast(std.os.linux.ioctl(self.fd, EVIOCGRAB, 1))) < 0) return error.GrabFailed;
            // CRITICAL: ungrab on any later failure so the real mouse is never left grabbed.
            errdefer _ = std.os.linux.ioctl(self.fd, EVIOCGRAB, 0);
            self.passthrough_fd = try lx.createUinputDevice(
                "zclicker-passthrough",
                &.{ lx.BTN_LEFT, lx.BTN_RIGHT, lx.BTN_MIDDLE, lx.BTN_SIDE, lx.BTN_EXTRA, lx.BTN_FORWARD, lx.BTN_BACK, lx.BTN_TASK },
                &.{ lx.REL_X, lx.REL_Y, lx.REL_WHEEL, lx.REL_HWHEEL, lx.REL_WHEEL_HI_RES, lx.REL_HWHEEL_HI_RES },
            );
        }
        return self;
    }

    pub fn deinit(self: *LinuxEvdev) void {
        // ALWAYS ungrab first: the physical mouse must never be left grabbed.
        if (self.fd >= 0 and self.suppress) _ = std.os.linux.ioctl(self.fd, EVIOCGRAB, 0);
        if (self.passthrough_fd >= 0) {
            lx.destroyUinputDevice(self.passthrough_fd);
            lx.closeFd(self.passthrough_fd);
            self.passthrough_fd = -1;
        }
        if (self.fd >= 0) lx.closeFd(self.fd);
        self.fd = -1;
    }

    pub fn interface(self: *LinuxEvdev) InputBackend {
        return .{ .ptr = self, .caps = .{ .can_suppress = true }, .nextEventFn = nextEventImpl };
    }

    pub fn deviceName(self: *const LinuxEvdev) []const u8 {
        if (self.name_len == 0) return "(desconhecido)";
        return self.name_buf[0..self.name_len];
    }

    fn nextEventImpl(ptr: *anyopaque, timeout_ms: i32) anyerror!?TriggerEvent {
        const self: *LinuxEvdev = @ptrCast(@alignCast(ptr));
        return self.nextEvent(timeout_ms);
    }

    /// The physical device went away (unplugged). Close it, then block-retry until a
    /// matching device reappears, re-grabbing if we were suppressing. The passthrough
    /// uinput device is left intact.
    fn reopen(self: *LinuxEvdev) void {
        if (self.fd >= 0) {
            if (self.suppress) _ = std.os.linux.ioctl(self.fd, EVIOCGRAB, 0);
            lx.closeFd(self.fd);
            self.fd = -1;
        }
        std.debug.print("[zclicker] mouse desconectado; aguardando reconexão...\n", .{});
        while (true) {
            self.fd = findDevice(self.codes) catch {
                var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 500 * std.time.ns_per_ms };
                _ = std.os.linux.nanosleep(&ts, null);
                continue;
            };
            if (self.suppress) _ = std.os.linux.ioctl(self.fd, EVIOCGRAB, 1);
            self.name_len = nameInto(self.fd, &self.name_buf);
            std.debug.print("[zclicker] mouse reconectado: {s}\n", .{self.deviceName()});
            return;
        }
    }

    fn nextEvent(self: *LinuxEvdev, timeout_ms: i32) !?TriggerEvent {
        if (self.popPending()) |ev| return ev;

        const deadline: ?i64 = if (timeout_ms < 0) null else lx.monoMillis() + timeout_ms;
        while (true) {
            var remaining: i32 = -1;
            if (deadline) |d| {
                const now = lx.monoMillis();
                if (now >= d) return null;
                remaining = @intCast(d - now);
            }
            var fds = [_]std.posix.pollfd{.{
                .fd = self.fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const n = try std.posix.poll(&fds, remaining);
            if ((@as(i16, fds[0].revents) & @as(i16, std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL)) != 0) {
                self.reopen();
                continue;
            }
            if (n == 0) return null; // timed out
            self.fill() catch {
                self.reopen();
                continue;
            };
            if (self.popPending()) |ev| return ev;
            // Only non-trigger events (movement, scroll) arrived; keep waiting.
        }
    }

    fn popPending(self: *LinuxEvdev) ?TriggerEvent {
        if (self.pending_idx >= self.pending_len) return null;
        const ev = self.pending[self.pending_idx];
        self.pending_idx += 1;
        return ev;
    }

    /// Read one batch of events and keep the trigger button presses/releases.
    fn fill(self: *LinuxEvdev) !void {
        self.pending_len = 0;
        self.pending_idx = 0;
        var buf: [64]lx.InputEvent = undefined;
        const bytes = std.posix.read(self.fd, std.mem.sliceAsBytes(buf[0..])) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
        const count = bytes / @sizeOf(lx.InputEvent);
        for (buf[0..count]) |ev| {
            // Only configured trigger buttons (press/release, not autorepeat) become TriggerEvents.
            const is_trigger = ev.type == lx.EV_KEY and codeInList(self.codes, ev.code) and (ev.value == 0 or ev.value == 1);
            if (is_trigger) {
                if (self.pending_len >= self.pending.len) continue;
                self.pending[self.pending_len] = .{ .button = ev.code, .pressed = ev.value == 1 };
                self.pending_len += 1;
            } else if (self.suppress and ev.type != lx.EV_MSC) {
                // Re-inject every non-trigger event through the passthrough so the
                // grabbed device's normal behaviour (movement, clicks, scroll) survives.
                // EV_MSC (MSC_SCAN) is dropped: the kernel emits a scancode right before
                // each button's EV_KEY, so re-injecting it for a *suppressed* trigger button
                // would leak a scancode with no matching key. Dropping all MSC_SCAN is safe —
                // it's supplementary hardware info the compositor doesn't need from a virtual device.
                lx.writeEvent(self.passthrough_fd, ev.type, ev.code, ev.value) catch {};
            }
        }
    }

    fn findDevice(codes: []const u16) !std.posix.fd_t {
        var n: usize = 0;
        while (n < MAX_EVENT_NODES) : (n += 1) {
            var pathbuf: [32]u8 = undefined;
            const path = std.fmt.bufPrintSentinel(&pathbuf, "/dev/input/event{d}", .{n}, 0) catch continue;
            const fd = lx.openRdonlyNonblock(path) catch continue;
            if (deviceHasButtons(fd, codes)) return fd;
            lx.closeFd(fd);
        }
        return error.NoDeviceFound;
    }

    fn deviceHasButtons(fd: std.posix.fd_t, codes: []const u16) bool {
        var keybits: [lx.KEY_MAX / 8 + 1]u8 = @splat(0);
        const rc = std.os.linux.ioctl(fd, eviocgbit(lx.EV_KEY, keybits.len), @intFromPtr(&keybits));
        if (@as(isize, @bitCast(rc)) < 0) return false;
        for (codes) |c| {
            if (@as(usize, c) / 8 >= keybits.len) return false;
            if (!lx.testBit(&keybits, c)) return false;
        }
        return true;
    }

    /// Print every input device that exposes all the requested trigger buttons.
    pub fn listDevices(codes: []const u16) !void {
        var found = false;
        var n: usize = 0;
        while (n < MAX_EVENT_NODES) : (n += 1) {
            var pathbuf: [32]u8 = undefined;
            const path = std.fmt.bufPrintSentinel(&pathbuf, "/dev/input/event{d}", .{n}, 0) catch continue;
            const fd = lx.openRdonlyNonblock(path) catch continue;
            defer lx.closeFd(fd);
            if (!deviceHasButtons(fd, codes)) continue;
            var namebuf: [256]u8 = undefined;
            const nm = nameInto(fd, &namebuf);
            const name: []const u8 = if (nm == 0) "(desconhecido)" else namebuf[0..nm];
            std.debug.print("{s}\t{s}\n", .{ path, name });
            found = true;
        }
        if (!found) std.debug.print("nenhum dispositivo com os botões pedidos.\n", .{});
    }
};

fn codeInList(codes: []const u16, code: u16) bool {
    for (codes) |c| if (c == code) return true;
    return false;
}

/// Query a device's name via EVIOCGNAME. Returns the length written to `buf`.
fn nameInto(fd: std.posix.fd_t, buf: []u8) usize {
    const rc = std.os.linux.ioctl(fd, eviocgname(@intCast(buf.len)), @intFromPtr(buf.ptr));
    const n = @as(isize, @bitCast(rc));
    if (n <= 0) return 0;
    var len: usize = @intCast(n);
    if (len > 0 and buf[len - 1] == 0) len -= 1; // drop trailing NUL
    return len;
}
