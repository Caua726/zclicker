const std = @import("std");
const OutputBackend = @import("output.zig").OutputBackend;

/// Output backend that performs a left click by spawning `ydotool click 0xC0`.
/// 0xC0 = left button down + up in ydotool's hex button encoding
/// (see `ydotool click --help`). Requires `ydotoold` to be running.
pub const Ydotool = struct {
    io: std.Io,

    pub fn init(io: std.Io) Ydotool {
        return .{ .io = io };
    }

    pub fn backend(self: *Ydotool) OutputBackend {
        return .{ .ptr = self, .clickFn = clickImpl };
    }

    fn clickImpl(ptr: *anyopaque) anyerror!void {
        const self: *Ydotool = @ptrCast(@alignCast(ptr));
        var child = try std.process.spawn(self.io, .{
            .argv = &[_][]const u8{ "ydotool", "click", "0xC0" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        _ = try child.wait(self.io);
    }
};
