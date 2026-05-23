const std = @import("std");
const lx = @import("../platform/linux.zig");
const backend = @import("../backend.zig");

const UINPUT_MAX_NAME_SIZE = 80;

fn UI_SET_EVBIT() u32 {
    return lx.iow('U', 100, @sizeOf(c_int));
}
fn UI_SET_KEYBIT() u32 {
    return lx.iow('U', 101, @sizeOf(c_int));
}
fn UI_SET_RELBIT() u32 {
    return lx.iow('U', 102, @sizeOf(c_int));
}
fn UI_DEV_SETUP() u32 {
    return lx.iow('U', 3, @sizeOf(UinputSetup));
}
fn UI_DEV_CREATE() u32 {
    return lx.io('U', 1);
}
fn UI_DEV_DESTROY() u32 {
    return lx.io('U', 2);
}

const InputId = extern struct { bustype: u16, vendor: u16, product: u16, version: u16 };
const UinputSetup = extern struct {
    id: InputId,
    name: [UINPUT_MAX_NAME_SIZE]u8,
    ff_effects_max: u32,
};

const BUS_VIRTUAL: u16 = 0x06;
const REL_X: u16 = 0x00;

/// Output backend that creates a virtual mouse and clicks left via uinput.
/// No daemon, lower latency than ydotool. Needs /dev/uinput writable
/// (root, or a udev rule granting your user/group rw).
pub const Uinput = struct {
    fd: std.posix.fd_t,

    pub fn init() !Uinput {
        const fd = try lx.openRdwr("/dev/uinput");
        errdefer lx.closeFd(fd);

        try ioctlInt(fd, UI_SET_EVBIT(), lx.EV_KEY);
        try ioctlInt(fd, UI_SET_KEYBIT(), lx.BTN_LEFT);
        try ioctlInt(fd, UI_SET_EVBIT(), lx.EV_REL); // a rel axis keeps it classified as a mouse
        try ioctlInt(fd, UI_SET_RELBIT(), REL_X);

        var setup = std.mem.zeroes(UinputSetup);
        setup.id = .{ .bustype = BUS_VIRTUAL, .vendor = 0x1234, .product = 0x5678, .version = 1 };
        const name = "zclicker-virtual-mouse";
        @memcpy(setup.name[0..name.len], name);
        try ioctlPtr(fd, UI_DEV_SETUP(), @intFromPtr(&setup));
        try ioctlNone(fd, UI_DEV_CREATE());

        // Let udev create the node before the first write.
        // std.Thread.sleep is absent in this compiler; use the raw nanosleep syscall.
        const ts = std.os.linux.timespec{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
        _ = std.os.linux.nanosleep(&ts, null);

        return .{ .fd = fd };
    }

    pub fn deinit(self: *Uinput) void {
        if (self.fd < 0) return; // idempotent: safe to call from both a signal handler and defer
        _ = std.os.linux.ioctl(self.fd, UI_DEV_DESTROY(), 0);
        lx.closeFd(self.fd);
        self.fd = -1;
    }

    pub fn interface(self: *Uinput) backend.OutputBackend {
        return .{ .ptr = self, .clickFn = clickImpl };
    }

    fn clickImpl(ptr: *anyopaque) anyerror!void {
        const self: *Uinput = @ptrCast(@alignCast(ptr));
        try self.emit(lx.EV_KEY, lx.BTN_LEFT, 1);
        try self.emit(lx.EV_SYN, lx.SYN_REPORT, 0);
        try self.emit(lx.EV_KEY, lx.BTN_LEFT, 0);
        try self.emit(lx.EV_SYN, lx.SYN_REPORT, 0);
    }

    fn emit(self: *Uinput, typ: u16, code: u16, value: i32) !void {
        const ev = lx.InputEvent{ .sec = 0, .usec = 0, .type = typ, .code = code, .value = value };
        const bytes = std.mem.asBytes(&ev);
        // std.posix.write is absent in this compiler; use the raw Linux write syscall.
        var written: usize = 0;
        while (written < bytes.len) {
            written += try rawWrite(self.fd, bytes[written..]);
        }
    }
};

/// Raw write via the Linux syscall — std.posix.write is not present in
/// Zig 0.17.0-dev builds targeting this project's compiler revision.
fn rawWrite(fd: std.posix.fd_t, buf: []const u8) !usize {
    const rc = std.os.linux.write(fd, buf.ptr, buf.len);
    const s = @as(isize, @bitCast(rc));
    if (s <= 0) return error.WriteFailed; // <=0 guards against a 0-byte write spinning emit() forever
    return @intCast(s);
}

fn ioctlInt(fd: std.posix.fd_t, req: u32, arg: u32) !void {
    if (@as(isize, @bitCast(std.os.linux.ioctl(fd, req, @as(usize, arg)))) < 0) return error.IoctlFailed;
}
fn ioctlPtr(fd: std.posix.fd_t, req: u32, arg: usize) !void {
    if (@as(isize, @bitCast(std.os.linux.ioctl(fd, req, arg))) < 0) return error.IoctlFailed;
}
fn ioctlNone(fd: std.posix.fd_t, req: u32) !void {
    if (@as(isize, @bitCast(std.os.linux.ioctl(fd, req, 0))) < 0) return error.IoctlFailed;
}
