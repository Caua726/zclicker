const std = @import("std");
const backend = @import("../backend.zig");

extern fn zc_wlr_init() c_int;
extern fn zc_wlr_click(button: c_uint) void;
extern fn zc_wlr_deinit() void;

/// Output backend using the wlroots zwlr_virtual_pointer_v1 protocol (Hyprland/Sway,
/// no daemon, no /dev/uinput). The Wayland work lives in wlr_shim.c.
pub const Wlr = struct {
    button: u16,

    pub fn init(button: backend.ClickButton) !Wlr {
        if (zc_wlr_init() != 0) return error.WlrUnavailable;
        return .{ .button = button.evdevCode() };
    }
    pub fn deinit(_: *Wlr) void {
        zc_wlr_deinit();
    }
    pub fn interface(self: *Wlr) backend.OutputBackend {
        return .{ .ptr = self, .clickFn = clickImpl };
    }
    fn clickImpl(ptr: *anyopaque) anyerror!void {
        const self: *Wlr = @ptrCast(@alignCast(ptr));
        zc_wlr_click(self.button);
    }
};
