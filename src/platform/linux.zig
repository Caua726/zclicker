const std = @import("std");

pub const EV_SYN: u16 = 0x00;
pub const EV_KEY: u16 = 0x01;
pub const EV_REL: u16 = 0x02;
pub const SYN_REPORT: u16 = 0x00;

pub const BTN_LEFT: u16 = 0x110;
pub const BTN_SIDE: u16 = 0x113;
pub const BTN_EXTRA: u16 = 0x114;

pub const KEY_MAX: usize = 0x2ff;

/// evdev `struct input_event` on 64-bit Linux (sizeof == 24).
pub const InputEvent = extern struct {
    sec: isize,
    usec: isize,
    type: u16,
    code: u16,
    value: i32,
};

pub const IOC_NONE: u32 = 0;
pub const IOC_WRITE: u32 = 1;
pub const IOC_READ: u32 = 2;

pub fn ioc(dir: u32, typ: u32, nr: u32, size: u32) u32 {
    return (dir << 30) | (size << 16) | (typ << 8) | nr;
}
pub fn io(typ: u32, nr: u32) u32 {
    return ioc(IOC_NONE, typ, nr, 0);
}
pub fn iow(typ: u32, nr: u32, size: u32) u32 {
    return ioc(IOC_WRITE, typ, nr, size);
}
pub fn ior(typ: u32, nr: u32, size: u32) u32 {
    return ioc(IOC_READ, typ, nr, size);
}

test "ioc encodes known uinput ioctl numbers" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 0x5501), io('U', 1));       // UI_DEV_CREATE  == _IO('U',1)
    try t.expectEqual(@as(u32, 0x5502), io('U', 2));       // UI_DEV_DESTROY == _IO('U',2)
    try t.expectEqual(@as(u32, 0x40045564), iow('U', 100, 4)); // UI_SET_EVBIT == _IOW('U',100,int)
}

/// Monotonic milliseconds, independent of the Io interface.
pub fn monoMillis() i64 {
    var ts: std.os.linux.timespec = undefined;
    // CLOCK_MONOTONIC is always available; assert rather than return garbage from an uninit ts.
    std.debug.assert(@as(isize, @bitCast(std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts))) == 0);
    return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), std.time.ns_per_ms);
}

pub const OpenError = error{ AccessDenied, FileNotFound, OpenFailed };

/// Open a path read-only/non-blocking via the raw Linux `open` syscall.
pub fn openRdonlyNonblock(path: [:0]const u8) OpenError!std.posix.fd_t {
    return decodeOpen(std.os.linux.open(path.ptr, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0));
}

/// Open a path read-write via the raw Linux `open` syscall (for /dev/uinput).
pub fn openRdwr(path: [:0]const u8) OpenError!std.posix.fd_t {
    return decodeOpen(std.os.linux.open(path.ptr, .{ .ACCMODE = .RDWR }, 0));
}

fn decodeOpen(rc: usize) OpenError!std.posix.fd_t {
    const signed = @as(isize, @bitCast(rc));
    if (signed >= 0) return @intCast(signed);
    const e: std.os.linux.E = @enumFromInt(@as(u16, @intCast(-signed)));
    return switch (e) {
        .ACCES, .PERM => error.AccessDenied,
        .NOENT, .NXIO, .NODEV => error.FileNotFound,
        else => error.OpenFailed,
    };
}

pub fn closeFd(fd: std.posix.fd_t) void {
    _ = std.os.linux.close(fd);
}

pub fn testBit(bits: []const u8, n: usize) bool {
    return (bits[n / 8] & (@as(u8, 1) << @intCast(n % 8))) != 0;
}
