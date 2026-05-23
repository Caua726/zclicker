const std = @import("std");
const backend = @import("../backend.zig");
const lx = @import("../platform/linux.zig");

const InputBackend = backend.InputBackend;
const TriggerEvent = backend.TriggerEvent;

const MAX_EVENT_NODES: usize = 64;
const MAX_DEVICES: usize = 16;

/// EVIOCGRAB: grab/release exclusive access. arg 1 grabs, 0 releases.
const EVIOCGRAB = lx.iow('E', 0x90, @sizeOf(c_int));
fn eviocgbit(ev: u32, len: u32) u32 {
    return lx.ior('E', 0x20 + ev, len);
}
fn eviocgname(len: u32) u32 {
    return lx.ior('E', 0x06, len);
}
fn eviocgid() u32 {
    return lx.ior('E', 0x02, @sizeOf(InputId));
}

const InputId = extern struct { bustype: u16, vendor: u16, product: u16, version: u16 };
const BUS_VIRTUAL: u16 = 0x06;

/// True for uinput/virtual devices (ydotoold's, and zclicker's own passthrough/output
/// nodes). The multi-device scan skips these so it never grabs or reads a synthetic
/// device — which would otherwise capture our own passthrough and freeze the mouse.
fn deviceIsVirtual(fd: std.posix.fd_t) bool {
    var id: InputId = undefined;
    const rc = std.os.linux.ioctl(fd, eviocgid(), @intFromPtr(&id));
    if (@as(isize, @bitCast(rc)) < 0) return false; // can't tell → treat as real
    return id.bustype == BUS_VIRTUAL;
}

/// One opened input device that holds at least one configured trigger code.
const Device = struct {
    fd: std.posix.fd_t,
    name_buf: [256]u8 = undefined,
    name_len: usize = 0,
    is_mouse: bool = false,
    grabbed: bool = false,
    passthrough_fd: std.posix.fd_t = -1,

    fn name(self: *const Device) []const u8 {
        if (self.name_len == 0) return "(desconhecido)";
        return self.name_buf[0..self.name_len];
    }

    fn close(self: *Device) void {
        if (self.grabbed and self.fd >= 0) {
            _ = std.os.linux.ioctl(self.fd, EVIOCGRAB, 0);
            self.grabbed = false;
        }
        if (self.passthrough_fd >= 0) {
            lx.destroyUinputDevice(self.passthrough_fd);
            lx.closeFd(self.passthrough_fd);
            self.passthrough_fd = -1;
        }
        if (self.fd >= 0) {
            lx.closeFd(self.fd);
            self.fd = -1;
        }
    }
};

/// Linux input backend. Reads button/key events from every `/dev/input/eventX` that
/// holds a configured trigger code, so triggers can be mouse buttons or keyboard keys.
/// Suppression (`EVIOCGRAB` + uinput passthrough) is applied only to mouse devices.
pub const LinuxEvdev = struct {
    devices: [MAX_DEVICES]Device = undefined,
    device_count: usize = 0,
    pending: [64]TriggerEvent = undefined,
    pending_len: usize = 0,
    pending_idx: usize = 0,
    codes: []const u16,
    suppress: bool,

    pub fn init(device: ?[]const u8, codes: []const u16, suppress: bool) !LinuxEvdev {
        var self = LinuxEvdev{ .codes = codes, .suppress = suppress };
        errdefer self.deinit();
        if (device) |path| {
            var zbuf: [256]u8 = undefined;
            const pz = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{path}, 0) catch return error.OpenFailed;
            const fd = try lx.openRdonlyNonblock(pz);
            errdefer lx.closeFd(fd); // addDevice only ungrabs on error; caller owns the fd
            try self.addDevice(fd);
        } else {
            self.scanDevices();
        }
        if (self.device_count == 0) return error.NoDeviceFound;
        return self;
    }

    pub fn deinit(self: *LinuxEvdev) void {
        var i: usize = 0;
        while (i < self.device_count) : (i += 1) self.devices[i].close();
        self.device_count = 0;
    }

    pub fn interface(self: *LinuxEvdev) InputBackend {
        return .{ .ptr = self, .caps = .{ .can_suppress = true }, .nextEventFn = nextEventImpl };
    }

    /// Name of the first device (for the banner).
    pub fn deviceName(self: *const LinuxEvdev) []const u8 {
        if (self.device_count == 0) return "(nenhum)";
        return self.devices[0].name();
    }

    pub fn deviceCount(self: *const LinuxEvdev) usize {
        return self.device_count;
    }

    /// Open every event node whose key caps include any configured code.
    fn scanDevices(self: *LinuxEvdev) void {
        var n: usize = 0;
        while (n < MAX_EVENT_NODES and self.device_count < MAX_DEVICES) : (n += 1) {
            var pathbuf: [32]u8 = undefined;
            const path = std.fmt.bufPrintSentinel(&pathbuf, "/dev/input/event{d}", .{n}, 0) catch continue;
            const fd = lx.openRdonlyNonblock(path) catch continue;
            if (deviceIsVirtual(fd) or !deviceHasAnyCode(fd, self.codes)) {
                lx.closeFd(fd);
                continue;
            }
            self.addDevice(fd) catch lx.closeFd(fd);
        }
    }

    /// Take ownership of an open fd: record name, detect mouse-ness, and (when
    /// suppressing a mouse) grab it and create a passthrough.
    fn addDevice(self: *LinuxEvdev, fd: std.posix.fd_t) !void {
        if (self.device_count >= MAX_DEVICES) {
            lx.closeFd(fd);
            return;
        }
        var dev = Device{ .fd = fd };
        dev.name_len = nameInto(fd, &dev.name_buf);
        dev.is_mouse = deviceIsMouse(fd);
        if (self.suppress and dev.is_mouse) {
            if (@as(isize, @bitCast(std.os.linux.ioctl(fd, EVIOCGRAB, 1))) < 0) return error.GrabFailed;
            dev.grabbed = true;
            errdefer {
                _ = std.os.linux.ioctl(fd, EVIOCGRAB, 0);
                dev.grabbed = false;
            }
            dev.passthrough_fd = try lx.createUinputDevice(
                "zclicker-passthrough",
                &.{ lx.BTN_LEFT, lx.BTN_RIGHT, lx.BTN_MIDDLE, lx.BTN_SIDE, lx.BTN_EXTRA, lx.BTN_FORWARD, lx.BTN_BACK, lx.BTN_TASK },
                &.{ lx.REL_X, lx.REL_Y, lx.REL_WHEEL, lx.REL_HWHEEL, lx.REL_WHEEL_HI_RES, lx.REL_HWHEEL_HI_RES },
            );
        }
        self.devices[self.device_count] = dev;
        self.device_count += 1;
    }

    fn nextEventImpl(ptr: *anyopaque, timeout_ms: i32) anyerror!?TriggerEvent {
        const self: *LinuxEvdev = @ptrCast(@alignCast(ptr));
        return self.nextEvent(timeout_ms);
    }

    fn nextEvent(self: *LinuxEvdev, timeout_ms: i32) !?TriggerEvent {
        if (self.popPending()) |ev| return ev;

        const deadline: ?i64 = if (timeout_ms < 0) null else lx.monoMillis() + timeout_ms;
        while (true) {
            if (self.device_count == 0) self.rescan();

            var remaining: i32 = -1;
            if (deadline) |d| {
                const now = lx.monoMillis();
                if (now >= d) return null;
                remaining = @intCast(d - now);
            }

            var fds: [MAX_DEVICES]std.posix.pollfd = undefined;
            var i: usize = 0;
            while (i < self.device_count) : (i += 1) {
                fds[i] = .{ .fd = self.devices[i].fd, .events = std.posix.POLL.IN, .revents = 0 };
            }
            const n = try std.posix.poll(fds[0..self.device_count], remaining);
            if (n == 0) return null; // timed out

            // Fresh batch for this poll round (pending is empty here — see popPending guard above).
            self.pending_len = 0;
            self.pending_idx = 0;

            const err_mask: i16 = std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL;
            var lost = false;
            i = 0;
            while (i < self.device_count) : (i += 1) {
                const re: i16 = fds[i].revents;
                if ((re & err_mask) != 0) {
                    self.devices[i].close();
                    lost = true;
                    continue;
                }
                if ((re & @as(i16, std.posix.POLL.IN)) != 0) {
                    self.fillFrom(&self.devices[i]) catch {
                        self.devices[i].close();
                        lost = true;
                    };
                }
            }
            if (lost) self.compactDevices();
            if (self.popPending()) |ev| return ev;
            // Only non-trigger events arrived; loop and keep waiting.
        }
    }

    fn popPending(self: *LinuxEvdev) ?TriggerEvent {
        if (self.pending_idx >= self.pending_len) return null;
        const ev = self.pending[self.pending_idx];
        self.pending_idx += 1;
        return ev;
    }

    /// Read one batch from a device, queueing configured trigger presses/releases and
    /// re-injecting everything else through the device's passthrough when suppressing.
    fn fillFrom(self: *LinuxEvdev, dev: *Device) !void {
        var buf: [64]lx.InputEvent = undefined;
        const bytes = std.posix.read(dev.fd, std.mem.sliceAsBytes(buf[0..])) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
        const count = bytes / @sizeOf(lx.InputEvent);
        for (buf[0..count]) |ev| {
            const is_trigger = ev.type == lx.EV_KEY and codeInList(self.codes, ev.code) and (ev.value == 0 or ev.value == 1);
            if (is_trigger) {
                if (self.pending_len >= self.pending.len) continue;
                self.pending[self.pending_len] = .{ .button = ev.code, .pressed = ev.value == 1 };
                self.pending_len += 1;
            } else if (dev.passthrough_fd >= 0 and ev.type != lx.EV_MSC) {
                // Re-inject non-trigger events so the grabbed mouse keeps working.
                // EV_MSC (MSC_SCAN) dropped to avoid leaking a scancode for a suppressed button.
                lx.writeEvent(dev.passthrough_fd, ev.type, ev.code, ev.value) catch {};
            }
        }
    }

    /// Drop devices whose fd was closed (fd < 0), preserving order.
    fn compactDevices(self: *LinuxEvdev) void {
        var w: usize = 0;
        var r: usize = 0;
        while (r < self.device_count) : (r += 1) {
            if (self.devices[r].fd >= 0) {
                if (w != r) self.devices[w] = self.devices[r];
                w += 1;
            }
        }
        self.device_count = w;
    }

    /// All devices gone (unplugged). Block-retry the scan until at least one returns.
    fn rescan(self: *LinuxEvdev) void {
        std.debug.print("[zclicker] dispositivos de gatilho sumiram; aguardando...\n", .{});
        while (self.device_count == 0) {
            self.scanDevices();
            if (self.device_count > 0) {
                std.debug.print("[zclicker] reconectado ({d} dispositivo(s))\n", .{self.device_count});
                return;
            }
            var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 500 * std.time.ns_per_ms };
            _ = std.os.linux.nanosleep(&ts, null);
        }
    }

    /// Print every device that holds any of the requested trigger codes.
    pub fn listDevices(codes: []const u16) !void {
        var found = false;
        var n: usize = 0;
        while (n < MAX_EVENT_NODES) : (n += 1) {
            var pathbuf: [32]u8 = undefined;
            const path = std.fmt.bufPrintSentinel(&pathbuf, "/dev/input/event{d}", .{n}, 0) catch continue;
            const fd = lx.openRdonlyNonblock(path) catch continue;
            defer lx.closeFd(fd);
            if (deviceIsVirtual(fd) or !deviceHasAnyCode(fd, codes)) continue;
            var namebuf: [256]u8 = undefined;
            const nm = nameInto(fd, &namebuf);
            const name: []const u8 = if (nm == 0) "(desconhecido)" else namebuf[0..nm];
            const kind: []const u8 = if (deviceIsMouse(fd)) "mouse" else "outro";
            std.debug.print("{s}\t{s}\t[{s}]\n", .{ path, name, kind });
            found = true;
        }
        if (!found) std.debug.print("nenhum dispositivo com os códigos pedidos.\n", .{});
    }
};

fn deviceHasAnyCode(fd: std.posix.fd_t, codes: []const u16) bool {
    var keybits: [lx.KEY_MAX / 8 + 1]u8 = @splat(0);
    const rc = std.os.linux.ioctl(fd, eviocgbit(lx.EV_KEY, keybits.len), @intFromPtr(&keybits));
    if (@as(isize, @bitCast(rc)) < 0) return false;
    for (codes) |c| {
        if (@as(usize, c) / 8 < keybits.len and lx.testBit(&keybits, c)) return true;
    }
    return false;
}

fn deviceIsMouse(fd: std.posix.fd_t) bool {
    var keybits: [lx.KEY_MAX / 8 + 1]u8 = @splat(0);
    const rc = std.os.linux.ioctl(fd, eviocgbit(lx.EV_KEY, keybits.len), @intFromPtr(&keybits));
    if (@as(isize, @bitCast(rc)) < 0) return false;
    return lx.testBit(&keybits, lx.BTN_LEFT); // BTN_LEFT marks a pointer device
}

fn codeInList(codes: []const u16, code: u16) bool {
    for (codes) |c| if (c == code) return true;
    return false;
}

/// Query a device's name via EVIOCGNAME. Returns length written to `buf`.
fn nameInto(fd: std.posix.fd_t, buf: []u8) usize {
    const rc = std.os.linux.ioctl(fd, eviocgname(@intCast(buf.len)), @intFromPtr(buf.ptr));
    const n = @as(isize, @bitCast(rc));
    if (n <= 0) return 0;
    var len: usize = @intCast(n);
    if (len > 0 and buf[len - 1] == 0) len -= 1;
    return len;
}
