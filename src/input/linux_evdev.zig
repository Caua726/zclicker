const std = @import("std");
const iface = @import("input.zig");

const InputBackend = iface.InputBackend;
const TriggerEvent = iface.TriggerEvent;

const EV_KEY: u16 = 0x01;
const KEY_MAX: usize = 0x2ff;
const MAX_EVENT_NODES: usize = 64;

/// evdev `struct input_event` on 64-bit Linux (sizeof == 24).
const InputEvent = extern struct {
    sec: isize,
    usec: isize,
    type: u16,
    code: u16,
    value: i32,
};

// --- ioctl request-number helpers (the kernel's _IOC macros) ---
const IOC_READ: u32 = 2;

fn ioc(dir: u32, typ: u32, nr: u32, size: u32) u32 {
    return (dir << 30) | (size << 16) | (typ << 8) | nr;
}
fn eviocgbit(ev: u32, len: u32) u32 {
    return ioc(IOC_READ, 'E', 0x20 + ev, len);
}
fn eviocgname(len: u32) u32 {
    return ioc(IOC_READ, 'E', 0x06, len);
}

fn testBit(bits: []const u8, n: usize) bool {
    return (bits[n / 8] & (@as(u8, 1) << @intCast(n % 8))) != 0;
}

const OpenError = error{ AccessDenied, FileNotFound, OpenFailed };

/// Open a device node read-only/non-blocking via the raw Linux `open` syscall
/// (std.posix.open no longer exists, and a raw fd is what poll/read/ioctl want).
fn openDevice(path: [:0]const u8) OpenError!std.posix.fd_t {
    const rc = std.os.linux.open(path.ptr, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0);
    const signed = @as(isize, @bitCast(rc));
    if (signed >= 0) return @intCast(signed);
    const e: std.os.linux.E = @enumFromInt(@as(u16, @intCast(-signed)));
    return switch (e) {
        .ACCES, .PERM => error.AccessDenied,
        .NOENT, .NXIO, .NODEV => error.FileNotFound,
        else => error.OpenFailed,
    };
}

fn closeFd(fd: std.posix.fd_t) void {
    _ = std.os.linux.close(fd);
}

/// Monotonic clock in milliseconds, independent of the Io interface so the
/// input backend stays self-contained.
fn monoMillis() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), std.time.ns_per_ms);
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

    pub fn init(device: ?[]const u8, codes: []const u16) !LinuxEvdev {
        var self = LinuxEvdev{ .fd = -1 };
        self.fd = if (device) |path| blk: {
            var zbuf: [256]u8 = undefined;
            const pz = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{path}, 0) catch return error.OpenFailed;
            break :blk try openDevice(pz);
        } else try findDevice(codes);
        self.name_len = nameInto(self.fd, &self.name_buf);
        return self;
    }

    pub fn deinit(self: *LinuxEvdev) void {
        if (self.fd >= 0) closeFd(self.fd);
        self.fd = -1;
    }

    pub fn backend(self: *LinuxEvdev) InputBackend {
        return .{ .ptr = self, .nextEventFn = nextEventImpl };
    }

    pub fn deviceName(self: *const LinuxEvdev) []const u8 {
        if (self.name_len == 0) return "(desconhecido)";
        return self.name_buf[0..self.name_len];
    }

    fn nextEventImpl(ptr: *anyopaque, timeout_ms: i32) anyerror!?TriggerEvent {
        const self: *LinuxEvdev = @ptrCast(@alignCast(ptr));
        return self.nextEvent(timeout_ms);
    }

    fn nextEvent(self: *LinuxEvdev, timeout_ms: i32) !?TriggerEvent {
        if (self.popPending()) |ev| return ev;

        const deadline: ?i64 = if (timeout_ms < 0) null else monoMillis() + timeout_ms;
        while (true) {
            var remaining: i32 = -1;
            if (deadline) |d| {
                const now = monoMillis();
                if (now >= d) return null;
                remaining = @intCast(d - now);
            }
            var fds = [_]std.posix.pollfd{.{
                .fd = self.fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            if (try std.posix.poll(&fds, remaining) == 0) return null; // timed out
            try self.fill();
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
        var buf: [64]InputEvent = undefined;
        const bytes = std.posix.read(self.fd, std.mem.sliceAsBytes(buf[0..])) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
        const count = bytes / @sizeOf(InputEvent);
        for (buf[0..count]) |ev| {
            if (ev.type != EV_KEY) continue;
            const pressed = switch (ev.value) {
                1 => true,
                0 => false,
                else => continue, // 2 == autorepeat, irrelevant for mouse buttons
            };
            if (self.pending_len >= self.pending.len) break;
            self.pending[self.pending_len] = .{ .button = ev.code, .pressed = pressed };
            self.pending_len += 1;
        }
    }

    fn findDevice(codes: []const u16) !std.posix.fd_t {
        var n: usize = 0;
        while (n < MAX_EVENT_NODES) : (n += 1) {
            var pathbuf: [32]u8 = undefined;
            const path = std.fmt.bufPrintSentinel(&pathbuf, "/dev/input/event{d}", .{n}, 0) catch continue;
            const fd = openDevice(path) catch continue;
            if (deviceHasButtons(fd, codes)) return fd;
            closeFd(fd);
        }
        return error.NoDeviceFound;
    }

    fn deviceHasButtons(fd: std.posix.fd_t, codes: []const u16) bool {
        var keybits: [KEY_MAX / 8 + 1]u8 = @splat(0);
        const rc = std.os.linux.ioctl(fd, eviocgbit(EV_KEY, keybits.len), @intFromPtr(&keybits));
        if (@as(isize, @bitCast(rc)) < 0) return false;
        for (codes) |c| {
            if (@as(usize, c) / 8 >= keybits.len) return false;
            if (!testBit(&keybits, c)) return false;
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
            const fd = openDevice(path) catch continue;
            defer closeFd(fd);
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

/// Query a device's name via EVIOCGNAME. Returns the length written to `buf`.
fn nameInto(fd: std.posix.fd_t, buf: []u8) usize {
    const rc = std.os.linux.ioctl(fd, eviocgname(@intCast(buf.len)), @intFromPtr(buf.ptr));
    const n = @as(isize, @bitCast(rc));
    if (n <= 0) return 0;
    var len: usize = @intCast(n);
    if (len > 0 and buf[len - 1] == 0) len -= 1; // drop trailing NUL
    return len;
}
