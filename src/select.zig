const std = @import("std");
const backend = @import("backend.zig");
const Id = backend.BackendId;

pub const Session = enum { wayland, x11, unknown };

/// Snapshot of the environment relevant to backend choice. Filled by `probe`
/// in main; constructed directly in tests.
pub const Env = struct {
    session: Session = .unknown,
    has_uinput: bool = false, // /dev/uinput writable
    has_ydotoold: bool = false, // ydotool socket present
};

pub const Choice = struct {
    input: Id,
    output: Id,
};

pub const SelectError = error{ NoOutputAvailable, SuppressUnavailable };

pub const Request = struct {
    input: ?Id = null,
    output: ?Id = null,
    suppress: bool = false,
};

/// Resolve a concrete input+output pair. Input is always evdev on Linux for now
/// (only backend that reads buttons). Output prefers uinput, falls back to ydotool.
pub fn resolve(env: Env, req: Request) SelectError!Choice {
    const input: Id = req.input orelse .evdev;
    // Suppression is an evdev capability; only evdev can honor it today.
    if (req.suppress and input != .evdev) return error.SuppressUnavailable;

    const output: Id = req.output orelse blk: {
        if (env.has_uinput) break :blk .uinput;
        if (env.has_ydotoold) break :blk .ydotool;
        break :blk .uinput; // optimistic default; open will surface the real error
    };
    return .{ .input = input, .output = output };
}

test "default prefers uinput when available" {
    const t = std.testing;
    const c = try resolve(.{ .has_uinput = true, .has_ydotoold = true }, .{});
    try t.expectEqual(Id.evdev, c.input);
    try t.expectEqual(Id.uinput, c.output);
}

test "falls back to ydotool without uinput" {
    const t = std.testing;
    const c = try resolve(.{ .has_uinput = false, .has_ydotoold = true }, .{});
    try t.expectEqual(Id.ydotool, c.output);
}

test "explicit output override wins" {
    const t = std.testing;
    const c = try resolve(.{ .has_uinput = true }, .{ .output = .ydotool });
    try t.expectEqual(Id.ydotool, c.output);
}

test "suppress with non-evdev input is rejected" {
    const t = std.testing;
    try t.expectError(error.SuppressUnavailable, resolve(.{}, .{ .input = .uinput, .suppress = true }));
}
