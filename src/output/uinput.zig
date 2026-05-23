const std = @import("std");
const lx = @import("../platform/linux.zig");
const backend = @import("../backend.zig");

/// Output backend: virtual mouse via /dev/uinput, clicks the configured button.
pub const Uinput = struct {
    fd: std.posix.fd_t,
    button: u16,

    pub fn init(button: backend.ClickButton) !Uinput {
        return .{
            .fd = try lx.createUinputDevice("zclicker-virtual-mouse", &.{button.evdevCode()}, &.{lx.REL_X}),
            .button = button.evdevCode(),
        };
    }

    pub fn deinit(self: *Uinput) void {
        if (self.fd < 0) return;
        lx.destroyUinputDevice(self.fd);
        lx.closeFd(self.fd);
        self.fd = -1;
    }

    pub fn interface(self: *Uinput) backend.OutputBackend {
        return .{ .ptr = self, .clickFn = clickImpl };
    }

    fn clickImpl(ptr: *anyopaque) anyerror!void {
        const self: *Uinput = @ptrCast(@alignCast(ptr));
        try lx.writeEvent(self.fd, lx.EV_KEY, self.button, 1);
        try lx.writeEvent(self.fd, lx.EV_SYN, lx.SYN_REPORT, 0);
        try lx.writeEvent(self.fd, lx.EV_KEY, self.button, 0);
        try lx.writeEvent(self.fd, lx.EV_SYN, lx.SYN_REPORT, 0);
    }
};
