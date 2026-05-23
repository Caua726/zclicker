const std = @import("std");
const backend = @import("../backend.zig");
const OutputBackend = backend.OutputBackend;

/// Output backend that clicks the configured button via `ydotool click <hex>`.
/// Requires `ydotoold` to be running.
pub const Ydotool = struct {
    io: std.Io,
    hex: []const u8,

    pub fn init(io: std.Io, button: backend.ClickButton) Ydotool {
        return .{ .io = io, .hex = button.ydotoolHex() };
    }

    pub fn interface(self: *Ydotool) OutputBackend {
        return .{ .ptr = self, .clickFn = clickImpl };
    }

    fn clickImpl(ptr: *anyopaque) anyerror!void {
        const self: *Ydotool = @ptrCast(@alignCast(ptr));
        var child = try std.process.spawn(self.io, .{
            .argv = &[_][]const u8{ "ydotool", "click", self.hex },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        _ = try child.wait(self.io);
    }
};
