const std = @import("std");
const backend = @import("../backend.zig");

const Display = opaque {};
extern fn XOpenDisplay(name: ?[*:0]const u8) ?*Display;
extern fn XCloseDisplay(dpy: *Display) c_int;
extern fn XFlush(dpy: *Display) c_int;
extern fn XTestFakeButtonEvent(dpy: *Display, button: c_uint, is_press: c_int, delay: c_ulong) c_int;

/// Output backend using the X11 XTest extension. X11 button numbers differ from
/// evdev: left=1, middle=2, right=3.
pub const X11 = struct {
    dpy: *Display,
    button: c_uint,

    pub fn init(btn: backend.ClickButton) !X11 {
        const dpy = XOpenDisplay(null) orelse return error.X11Unavailable;
        return .{ .dpy = dpy, .button = btn.x11Button() };
    }
    pub fn deinit(self: *X11) void {
        _ = XCloseDisplay(self.dpy);
    }
    pub fn interface(self: *X11) backend.OutputBackend {
        return .{ .ptr = self, .clickFn = clickImpl };
    }
    fn clickImpl(ptr: *anyopaque) anyerror!void {
        const self: *X11 = @ptrCast(@alignCast(ptr));
        _ = XTestFakeButtonEvent(self.dpy, self.button, 1, 0); // press
        _ = XTestFakeButtonEvent(self.dpy, self.button, 0, 0); // release
        _ = XFlush(self.dpy);
    }
};
