const std = @import("std");
const gtk = @import("gtk.zig");

fn onActivate(app: *gtk.GtkApplication, _: gtk.gpointer) callconv(.c) void {
    const win = gtk.gtk_application_window_new(app);
    gtk.gtk_window_set_title(@ptrCast(win), "zclicker");
    gtk.gtk_window_set_default_size(@ptrCast(win), 360, 300);
    gtk.gtk_window_present(@ptrCast(win));
}

pub fn main() !void {
    const app = gtk.gtk_application_new("org.zclicker.gui", gtk.G_APPLICATION_DEFAULT_FLAGS);
    defer gtk.g_object_unref(app);
    _ = gtk.g_signal_connect_data(app, "activate", @ptrCast(&onActivate), null, null, 0);
    _ = gtk.g_application_run(@ptrCast(app), 0, null);
}
