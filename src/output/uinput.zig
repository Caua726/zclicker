const std = @import("std");
const lx = @import("../platform/linux.zig");
const backend = @import("../backend.zig");

/// Output backend: virtual mouse via /dev/uinput, left click without ydotool.
pub const Uinput = struct {
    fd: std.posix.fd_t,

    pub fn init() !Uinput {
        return .{ .fd = try lx.createUinputDevice("zclicker-virtual-mouse", &.{lx.BTN_LEFT}, &.{lx.REL_X}) };
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
        try lx.writeEvent(self.fd, lx.EV_KEY, lx.BTN_LEFT, 1);
        try lx.writeEvent(self.fd, lx.EV_SYN, lx.SYN_REPORT, 0);
        try lx.writeEvent(self.fd, lx.EV_KEY, lx.BTN_LEFT, 0);
        try lx.writeEvent(self.fd, lx.EV_SYN, lx.SYN_REPORT, 0);
    }
};
