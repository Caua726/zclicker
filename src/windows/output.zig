//! Windows output backend: SendInput with synthesized mouse down/up pairs.
//! Maps the platform-neutral ClickButton onto the MOUSEEVENTF_* flags.

const std = @import("std");
const z = @import("zclicker");
const backend = z.backend;
const w = @import("win32.zig");

pub const WinOutput = struct {
    down: w.DWORD,
    up: w.DWORD,

    pub fn init(btn: backend.ClickButton) WinOutput {
        return switch (btn) {
            .left => .{ .down = w.MOUSEEVENTF_LEFTDOWN, .up = w.MOUSEEVENTF_LEFTUP },
            .right => .{ .down = w.MOUSEEVENTF_RIGHTDOWN, .up = w.MOUSEEVENTF_RIGHTUP },
            .middle => .{ .down = w.MOUSEEVENTF_MIDDLEDOWN, .up = w.MOUSEEVENTF_MIDDLEUP },
        };
    }

    pub fn interface(self: *WinOutput) backend.OutputBackend {
        return .{ .ptr = self, .clickFn = clickImpl };
    }

    fn ev(flags: w.DWORD) w.INPUT {
        return .{ .type = w.INPUT_MOUSE, .u = .{ .mi = .{ .dx = 0, .dy = 0, .mouseData = 0, .dwFlags = flags, .time = 0, .dwExtraInfo = 0 } } };
    }

    fn clickImpl(ptr: *anyopaque) anyerror!void {
        const self: *WinOutput = @ptrCast(@alignCast(ptr));
        var inputs = [2]w.INPUT{ ev(self.down), ev(self.up) };
        _ = w.SendInput(2, &inputs, @sizeOf(w.INPUT));
    }
};
