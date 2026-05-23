const std = @import("std");

/// Runtime interface every platform output backend implements. For now the only
/// action is a left click; future backends (X11 XTest, Windows SendInput) just
/// provide their own `clickFn`.
pub const OutputBackend = struct {
    ptr: *anyopaque,
    clickFn: *const fn (ptr: *anyopaque) anyerror!void,

    pub fn click(self: OutputBackend) anyerror!void {
        return self.clickFn(self.ptr);
    }
};
