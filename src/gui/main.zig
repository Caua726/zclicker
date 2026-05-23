const std = @import("std");
const c = @import("gtk");

fn onActivate(app: *c.GtkApplication, _: c.gpointer) callconv(.c) void {
    const win = c.gtk_application_window_new(app);
    c.gtk_window_set_title(@ptrCast(win), "zclicker");
    c.gtk_window_set_default_size(@ptrCast(win), 360, 280);
    c.gtk_window_present(@ptrCast(win));
}

pub fn main() !void {
    const app = c.gtk_application_new("org.zclicker.gui", c.G_APPLICATION_DEFAULT_FLAGS);
    defer c.g_object_unref(app);
    _ = c.g_signal_connect_data(app, "activate", @ptrCast(&onActivate), null, null, 0);
    _ = c.g_application_run(@ptrCast(app), 0, null);
}
