const std = @import("std");
const lx = @import("zclicker").platform;

const MAX_EVENT_NODES: usize = 64;

pub const Entry = struct { path: [:0]const u8, name: [:0]const u8 };

/// Enumerate non-virtual, key-capable input devices (the ones usable as a trigger
/// source). Caller passes an arena; returned slices are owned by it.
pub fn listDevices(arena: std.mem.Allocator) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    var n: usize = 0;
    while (n < 64) : (n += 1) {
        var pathbuf: [32]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&pathbuf, "/dev/input/event{d}", .{n}, 0) catch continue;
        const fd = lx.openRdonlyNonblock(path) catch continue;
        defer lx.closeFd(fd);
        if (isVirtual(fd) or !hasAnyKey(fd)) continue;
        var namebuf: [256]u8 = undefined;
        const nm = nameOf(fd, &namebuf);
        const name = if (nm == 0) "(desconhecido)" else namebuf[0..nm];
        try out.append(arena, .{
            .path = try arena.dupeSentinel(u8, path, 0),
            .name = try arena.dupeSentinel(u8, name, 0),
        });
    }
    return out.toOwnedSlice(arena);
}

fn nameOf(fd: std.posix.fd_t, buf: []u8) usize {
    const rc = std.os.linux.ioctl(fd, lx.ior('E', 0x06, @intCast(buf.len)), @intFromPtr(buf.ptr));
    const n = @as(isize, @bitCast(rc));
    if (n <= 0) return 0;
    var len: usize = @intCast(n);
    if (len > 0 and buf[len - 1] == 0) len -= 1;
    return len;
}

/// Block until the user presses any key/button on any real input device, then return
/// its evdev code. Skips virtual devices. Needs read access to /dev/input (input group).
pub fn captureNext() !u16 {
    var fds: [MAX_EVENT_NODES]std.posix.pollfd = undefined;
    var paths_open: [MAX_EVENT_NODES]std.posix.fd_t = undefined;
    var count: usize = 0;
    defer for (paths_open[0..count]) |fd| lx.closeFd(fd);

    var n: usize = 0;
    while (n < MAX_EVENT_NODES and count < MAX_EVENT_NODES) : (n += 1) {
        var pathbuf: [32]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&pathbuf, "/dev/input/event{d}", .{n}, 0) catch continue;
        const fd = lx.openRdonlyNonblock(path) catch continue;
        // Only key-capable, non-virtual devices.
        if (isVirtual(fd) or !hasAnyKey(fd)) {
            lx.closeFd(fd);
            continue;
        }
        paths_open[count] = fd;
        fds[count] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
        count += 1;
    }
    if (count == 0) return error.NoDevices;

    while (true) {
        _ = try std.posix.poll(fds[0..count], -1);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if ((@as(i16, fds[i].revents) & @as(i16, std.posix.POLL.IN)) == 0) continue;
            var buf: [64]lx.InputEvent = undefined;
            const bytes = std.posix.read(fds[i].fd, std.mem.sliceAsBytes(buf[0..])) catch continue;
            const ne = bytes / @sizeOf(lx.InputEvent);
            for (buf[0..ne]) |ev| {
                if (ev.type == lx.EV_KEY and ev.value == 1) return ev.code; // first press
            }
        }
    }
}

const InputId = extern struct { bustype: u16, vendor: u16, product: u16, version: u16 };
fn isVirtual(fd: std.posix.fd_t) bool {
    var id: InputId = undefined;
    const rc = std.os.linux.ioctl(fd, lx.ior('E', 0x02, @sizeOf(InputId)), @intFromPtr(&id));
    if (@as(isize, @bitCast(rc)) < 0) return false;
    return id.bustype == 0x06;
}
fn hasAnyKey(fd: std.posix.fd_t) bool {
    var keybits: [lx.KEY_MAX / 8 + 1]u8 = @splat(0);
    const rc = std.os.linux.ioctl(fd, lx.ior('E', 0x20 + @as(u32, lx.EV_KEY), keybits.len), @intFromPtr(&keybits));
    return @as(isize, @bitCast(rc)) >= 0;
}
