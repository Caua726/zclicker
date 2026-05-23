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

// --- additional input codes (used by the suppression passthrough) ---
pub const BTN_RIGHT: u16 = 0x111;
pub const BTN_MIDDLE: u16 = 0x112;
pub const BTN_FORWARD: u16 = 0x115;
pub const BTN_BACK: u16 = 0x116;
pub const BTN_TASK: u16 = 0x117;
pub const REL_X: u16 = 0x00;
pub const REL_Y: u16 = 0x01;
pub const REL_HWHEEL: u16 = 0x06;
pub const REL_WHEEL: u16 = 0x08;
pub const REL_WHEEL_HI_RES: u16 = 0x0b;
pub const REL_HWHEEL_HI_RES: u16 = 0x0c;

// --- uinput device creation (shared by the uinput output backend and the suppression passthrough) ---
const UINPUT_MAX_NAME_SIZE = 80;
const BUS_VIRTUAL: u16 = 0x06;
const InputId = extern struct { bustype: u16, vendor: u16, product: u16, version: u16 };
const UinputSetup = extern struct { id: InputId, name: [UINPUT_MAX_NAME_SIZE]u8, ff_effects_max: u32 };

fn uiIoctl(fd: std.posix.fd_t, req: u32, arg: usize) !void {
    if (@as(isize, @bitCast(std.os.linux.ioctl(fd, req, arg))) < 0) return error.IoctlFailed;
}

/// Create a uinput virtual input device with the given button + relative-axis
/// capabilities. Returns the open fd (caller must `destroyUinputDevice` + `closeFd`).
pub fn createUinputDevice(name: []const u8, key_codes: []const u16, rel_codes: []const u16) !std.posix.fd_t {
    const fd = try openRdwr("/dev/uinput");
    errdefer closeFd(fd);
    if (key_codes.len > 0) {
        try uiIoctl(fd, iow('U', 100, @sizeOf(c_int)), EV_KEY); // UI_SET_EVBIT
        for (key_codes) |c| try uiIoctl(fd, iow('U', 101, @sizeOf(c_int)), c); // UI_SET_KEYBIT
    }
    if (rel_codes.len > 0) {
        try uiIoctl(fd, iow('U', 100, @sizeOf(c_int)), EV_REL); // UI_SET_EVBIT
        for (rel_codes) |c| try uiIoctl(fd, iow('U', 102, @sizeOf(c_int)), c); // UI_SET_RELBIT
    }
    var setup = std.mem.zeroes(UinputSetup);
    setup.id = .{ .bustype = BUS_VIRTUAL, .vendor = 0x1234, .product = 0x5678, .version = 1 };
    const n = @min(name.len, UINPUT_MAX_NAME_SIZE - 1);
    @memcpy(setup.name[0..n], name[0..n]);
    try uiIoctl(fd, iow('U', 3, @sizeOf(UinputSetup)), @intFromPtr(&setup)); // UI_DEV_SETUP
    try uiIoctl(fd, io('U', 1), 0); // UI_DEV_CREATE
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
    _ = std.os.linux.nanosleep(&ts, null); // let udev create the node before first write
    return fd;
}

pub fn destroyUinputDevice(fd: std.posix.fd_t) void {
    _ = std.os.linux.ioctl(fd, io('U', 2), 0); // UI_DEV_DESTROY
}

/// Write one input_event to a uinput fd (timestamp left 0; the kernel stamps it).
pub fn writeEvent(fd: std.posix.fd_t, typ: u16, code: u16, value: i32) !void {
    const ev = InputEvent{ .sec = 0, .usec = 0, .type = typ, .code = code, .value = value };
    const bytes = std.mem.asBytes(&ev);
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = std.os.linux.write(fd, bytes[written..].ptr, bytes.len - written);
        const s = @as(isize, @bitCast(rc));
        if (s <= 0) return error.WriteFailed;
        written += @intCast(s);
    }
}
