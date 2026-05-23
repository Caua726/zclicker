//! Hand-written GTK4 / GLib bindings — only the symbols zclicker-gui uses.
//! @cImport was removed in this Zig and translate-c chokes on GTK headers, so we
//! declare the C ABI directly and link `gtk4` + libc.

pub const GtkApplication = opaque {};
pub const GApplication = opaque {};
pub const GtkWidget = opaque {};
pub const GtkWindow = opaque {};
pub const GtkBox = opaque {};
pub const GtkLabel = opaque {};
pub const GtkButton = opaque {};
pub const GtkEntry = opaque {};
pub const GtkEditable = opaque {};
pub const GtkSpinButton = opaque {};
pub const GtkDropDown = opaque {};
pub const GtkCheckButton = opaque {};
pub const GSubprocess = opaque {};
pub const GCancellable = opaque {};
pub const GAsyncResult = opaque {};
pub const GError = extern struct { domain: u32, code: c_int, message: ?[*:0]u8 };

pub const gpointer = ?*anyopaque;
pub const GCallback = *const fn () callconv(.c) void;
pub const GAsyncReadyCallback = *const fn (source: ?*anyopaque, res: *GAsyncResult, data: gpointer) callconv(.c) void;

pub const GTK_ORIENTATION_HORIZONTAL: c_int = 0;
pub const GTK_ORIENTATION_VERTICAL: c_int = 1;
pub const G_APPLICATION_DEFAULT_FLAGS: c_uint = 0;
pub const G_SUBPROCESS_FLAGS_NONE: c_uint = 0;

pub extern fn gtk_application_new(application_id: [*:0]const u8, flags: c_uint) *GtkApplication;
pub extern fn g_application_run(application: *GApplication, argc: c_int, argv: ?[*]?[*:0]u8) c_int;
pub extern fn g_object_unref(object: gpointer) void;
pub extern fn g_signal_connect_data(instance: gpointer, detailed_signal: [*:0]const u8, c_handler: GCallback, data: gpointer, destroy_data: gpointer, connect_flags: c_uint) c_ulong;

pub extern fn gtk_application_window_new(application: *GtkApplication) *GtkWidget;
pub extern fn gtk_window_set_title(window: *GtkWindow, title: [*:0]const u8) void;
pub extern fn gtk_window_set_default_size(window: *GtkWindow, width: c_int, height: c_int) void;
pub extern fn gtk_window_present(window: *GtkWindow) void;
pub extern fn gtk_window_set_child(window: *GtkWindow, child: ?*GtkWidget) void;
pub extern fn gtk_box_new(orientation: c_int, spacing: c_int) *GtkWidget;
pub extern fn gtk_box_append(box: *GtkBox, child: *GtkWidget) void;
pub extern fn gtk_widget_set_margin_top(widget: *GtkWidget, margin: c_int) void;
pub extern fn gtk_widget_set_margin_bottom(widget: *GtkWidget, margin: c_int) void;
pub extern fn gtk_widget_set_margin_start(widget: *GtkWidget, margin: c_int) void;
pub extern fn gtk_widget_set_margin_end(widget: *GtkWidget, margin: c_int) void;

pub extern fn gtk_label_new(str: ?[*:0]const u8) *GtkWidget;
pub extern fn gtk_label_set_text(label: *GtkLabel, str: [*:0]const u8) void;
pub extern fn gtk_button_new_with_label(label: [*:0]const u8) *GtkWidget;
pub extern fn gtk_button_set_label(button: *GtkButton, label: [*:0]const u8) void;
pub extern fn gtk_entry_new() *GtkWidget;
pub extern fn gtk_editable_get_text(editable: *GtkEditable) [*:0]const u8;
pub extern fn gtk_spin_button_new_with_range(min: f64, max: f64, step: f64) *GtkWidget;
pub extern fn gtk_spin_button_get_value_as_int(spin_button: *GtkSpinButton) c_int;
pub extern fn gtk_spin_button_set_value(spin_button: *GtkSpinButton, value: f64) void;
pub extern fn gtk_drop_down_new_from_strings(strings: [*]const ?[*:0]const u8) *GtkWidget;
pub extern fn gtk_drop_down_get_selected(self: *GtkDropDown) c_uint;
pub extern fn gtk_check_button_new_with_label(label: [*:0]const u8) *GtkWidget;
pub extern fn gtk_check_button_get_active(self: *GtkCheckButton) c_int;
pub extern fn gtk_check_button_set_active(self: *GtkCheckButton, setting: c_int) void;
pub extern fn gtk_check_button_set_group(self: *GtkCheckButton, group: ?*GtkCheckButton) void;

pub extern fn g_subprocess_newv(argv: [*]const ?[*:0]const u8, flags: c_uint, @"error": ?*?*GError) ?*GSubprocess;
pub extern fn g_subprocess_send_signal(subprocess: *GSubprocess, signal_num: c_int) void;
pub extern fn g_subprocess_wait_async(subprocess: *GSubprocess, cancellable: ?*GCancellable, callback: GAsyncReadyCallback, user_data: gpointer) void;

pub const GtkGrid = opaque {};
pub const GtkHeaderBar = opaque {};
pub const GtkCssProvider = opaque {};
pub const GtkStyleProvider = opaque {};
pub const GdkDisplay = opaque {};

pub const GTK_STYLE_PROVIDER_PRIORITY_APPLICATION: c_uint = 600;

pub extern fn gtk_grid_new() *GtkWidget;
pub extern fn gtk_grid_attach(grid: *GtkGrid, child: *GtkWidget, column: c_int, row: c_int, width: c_int, height: c_int) void;
pub extern fn gtk_grid_set_row_spacing(grid: *GtkGrid, spacing: c_uint) void;
pub extern fn gtk_grid_set_column_spacing(grid: *GtkGrid, spacing: c_uint) void;
pub extern fn gtk_label_set_xalign(label: *GtkLabel, xalign: f32) void;
pub extern fn gtk_widget_set_hexpand(widget: *GtkWidget, expand: c_int) void;
pub extern fn gtk_widget_add_css_class(widget: *GtkWidget, css_class: [*:0]const u8) void;
pub extern fn gtk_widget_remove_css_class(widget: *GtkWidget, css_class: [*:0]const u8) void;
pub extern fn gtk_header_bar_new() *GtkWidget;
pub extern fn gtk_window_set_titlebar(window: *GtkWindow, titlebar: *GtkWidget) void;
pub extern fn gtk_css_provider_new() *GtkCssProvider;
pub extern fn gtk_css_provider_load_from_string(css_provider: *GtkCssProvider, string: [*:0]const u8) void;
pub extern fn gtk_style_context_add_provider_for_display(display: *GdkDisplay, provider: *GtkStyleProvider, priority: c_uint) void;
pub extern fn gdk_display_get_default() ?*GdkDisplay;
