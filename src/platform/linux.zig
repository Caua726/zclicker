const std = @import("std");
const codes = @import("../codes.zig");

// Re-export the platform-neutral evdev constants so existing `lx.*` users keep
// working. The pure definitions live in src/codes.zig (no syscalls).
pub const EV_SYN = codes.EV_SYN;
pub const EV_KEY = codes.EV_KEY;
pub const EV_REL = codes.EV_REL;
pub const EV_MSC = codes.EV_MSC;
pub const SYN_REPORT = codes.SYN_REPORT;
pub const KEY_MAX = codes.KEY_MAX;

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
pub const BTN_LEFT = codes.BTN_LEFT;
pub const BTN_RIGHT = codes.BTN_RIGHT;
pub const BTN_MIDDLE = codes.BTN_MIDDLE;
pub const BTN_SIDE = codes.BTN_SIDE;
pub const BTN_EXTRA = codes.BTN_EXTRA;
pub const BTN_FORWARD = codes.BTN_FORWARD;
pub const BTN_BACK = codes.BTN_BACK;
pub const BTN_TASK = codes.BTN_TASK;
pub const REL_X = codes.REL_X;
pub const REL_Y = codes.REL_Y;
pub const REL_HWHEEL = codes.REL_HWHEEL;
pub const REL_WHEEL = codes.REL_WHEEL;
pub const REL_WHEEL_HI_RES = codes.REL_WHEEL_HI_RES;
pub const REL_HWHEEL_HI_RES = codes.REL_HWHEEL_HI_RES;

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
