const std = @import("std");
const gtk = @import("gtk.zig");
const command = @import("command.zig");
const capture = @import("capture.zig");

const Ui = struct {
    interval: *gtk.GtkSpinButton,
    mode_toggle: *gtk.GtkCheckButton, // checked = toggle, unchecked = hold
    click: *gtk.GtkDropDown,
    output: *gtk.GtkDropDown,
    device: *gtk.GtkEntry,
    suppress: *gtk.GtkCheckButton,
    status: *gtk.GtkLabel,
    start: *gtk.GtkButton,
    triggers_label: *gtk.GtkLabel,
    codes: std.ArrayList(u16) = .empty,
    child: ?*gtk.GSubprocess = null,
    gpa: std.mem.Allocator,
};

fn setStatus(ui: *Ui, s: [*:0]const u8, running: bool) void {
    gtk.gtk_label_set_text(@ptrCast(ui.status), s);
    if (running) gtk.gtk_widget_add_css_class(@ptrCast(ui.status), "running")
    else gtk.gtk_widget_remove_css_class(@ptrCast(ui.status), "running");
}

fn setupCss() void {
    const css =
        \\.dim { opacity: 0.65; }
        \\.status { font-weight: bold; margin-top: 8px; }
        \\.status.running { color: #2ec27e; }
        \\.start { margin-top: 6px; }
    ;
    const provider = gtk.gtk_css_provider_new();
    gtk.gtk_css_provider_load_from_string(provider, css);
    const display = gtk.gdk_display_get_default() orelse return;
    gtk.gtk_style_context_add_provider_for_display(display, @ptrCast(provider), gtk.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
}

fn attachRow(grid: *gtk.GtkGrid, row: c_int, label: [*:0]const u8, control: *gtk.GtkWidget) void {
    const lbl = gtk.gtk_label_new(label);
    gtk.gtk_label_set_xalign(@ptrCast(lbl), 1.0);
    gtk.gtk_widget_add_css_class(lbl, "dim");
    gtk.gtk_grid_attach(grid, lbl, 0, row, 1, 1);
    gtk.gtk_widget_set_hexpand(control, 1);
    gtk.gtk_grid_attach(grid, control, 1, row, 1, 1);
}

fn refreshTriggers(ui: *Ui) void {
    var buf: [256]u8 = undefined;
    if (ui.codes.items.len == 0) {
        gtk.gtk_label_set_text(@ptrCast(ui.triggers_label), "(nenhum)");
        return;
    }
    var len: usize = 0;
    for (ui.codes.items, 0..) |code, i| {
        if (len + 8 >= buf.len) break; // leave room for ", NNNNN" + NUL
        if (i != 0) {
            buf[len] = ',';
            buf[len + 1] = ' ';
            len += 2;
        }
        const s = std.fmt.bufPrint(buf[len..], "{d}", .{code}) catch break;
        len += s.len;
    }
    buf[len] = 0; // len < buf.len guaranteed by the room check above
    gtk.gtk_label_set_text(@ptrCast(ui.triggers_label), @ptrCast(buf[0..len :0]));
}

fn readConfig(ui: *Ui) command.Config {
    const click: command.Click = switch (gtk.gtk_drop_down_get_selected(ui.click)) {
        0 => .left, 1 => .right, 2 => .middle, else => .left,
    };
    const output: command.Output = switch (gtk.gtk_drop_down_get_selected(ui.output)) {
        0 => .auto, 1 => .uinput, 2 => .ydotool, else => .auto,
    };
    return .{
        .interval_ms = @intCast(gtk.gtk_spin_button_get_value_as_int(ui.interval)),
        .mode = if (gtk.gtk_check_button_get_active(ui.mode_toggle) != 0) .toggle else .hold,
        .click = click,
        .codes = ui.codes.items,
        .output = output,
        .device = std.mem.span(gtk.gtk_editable_get_text(@ptrCast(ui.device))),
        .suppress = gtk.gtk_check_button_get_active(ui.suppress) != 0,
    };
}

/// Resolve the zclicker binary: sibling of this exe, else "zclicker" on PATH.
fn resolveBin(arena: std.mem.Allocator) []const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.readlink("/proc/self/exe", &buf, buf.len);
    const n: isize = @bitCast(rc);
    if (n <= 0 or @as(usize, @intCast(n)) >= buf.len) return "zclicker";
    const exe = buf[0..@intCast(n)];
    const dir = std.fs.path.dirname(exe) orelse return "zclicker";
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const sib = std.fmt.bufPrintSentinel(&pbuf, "{s}/zclicker", .{dir}, 0) catch return "zclicker";
    if (@as(isize, @bitCast(std.os.linux.access(sib.ptr, 0))) == 0) {
        return arena.dupe(u8, sib) catch "zclicker";
    }
    return "zclicker";
}

fn onCapture(_: *gtk.GtkButton, data: gtk.gpointer) callconv(.c) void {
    const ui: *Ui = @ptrCast(@alignCast(data));
    const code = capture.captureNext() catch {
        setStatus(ui, "captura falhou (você está no grupo 'input'?)", false);
        return;
    };
    ui.codes.append(ui.gpa, code) catch return;
    refreshTriggers(ui);
}

fn onChildExit(_: ?*anyopaque, _: *gtk.GAsyncResult, data: gtk.gpointer) callconv(.c) void {
    const ui: *Ui = @ptrCast(@alignCast(data));
    if (ui.child) |c| {
        gtk.g_object_unref(c);
        ui.child = null;
    }
    gtk.gtk_button_set_label(@ptrCast(ui.start), "Iniciar");
    setStatus(ui, "parado", false);
}

fn onStart(_: *gtk.GtkButton, data: gtk.gpointer) callconv(.c) void {
    const ui: *Ui = @ptrCast(@alignCast(data));
    if (ui.child) |child| {
        gtk.g_subprocess_send_signal(child, @intFromEnum(std.posix.SIG.TERM));
        return; // onChildExit resets the UI
    }
    var arena_inst = std.heap.ArenaAllocator.init(ui.gpa);
    defer arena_inst.deinit(); // GSubprocess copies argv, so freeing after spawn is fine
    const arena = arena_inst.allocator();

    const bin = resolveBin(arena);
    const argv = command.buildArgv(arena, bin, readConfig(ui)) catch {
        setStatus(ui, "erro montando comando", false);
        return;
    };
    const cargv = arena.allocSentinel(?[*:0]const u8, argv.len, null) catch return;
    for (argv, 0..) |a, i| {
        const z = arena.dupeSentinel(u8, a, 0) catch return;
        cargv[i] = z.ptr;
    }
    var gerr: ?*gtk.GError = null;
    const child = gtk.g_subprocess_newv(cargv.ptr, gtk.G_SUBPROCESS_FLAGS_NONE, &gerr);
    if (child == null) {
        if (gerr) |e| gtk.g_error_free(e);
        setStatus(ui, "falha ao iniciar (zclicker no PATH? acesso a /dev/uinput?)", false);
        return;
    }
    ui.child = child;
    gtk.gtk_button_set_label(@ptrCast(ui.start), "Parar");
    setStatus(ui, "rodando", true);
    gtk.g_subprocess_wait_async(child.?, null, @ptrCast(&onChildExit), data);
}

fn onActivate(app: *gtk.GtkApplication, _: gtk.gpointer) callconv(.c) void {
    const gpa = std.heap.page_allocator;
    const ui = gpa.create(Ui) catch return;
    setupCss();

    const win = gtk.gtk_application_window_new(app);
    gtk.gtk_window_set_title(@ptrCast(win), "zclicker");
    gtk.gtk_window_set_default_size(@ptrCast(win), 420, 380);

    const header = gtk.gtk_header_bar_new();
    gtk.gtk_window_set_titlebar(@ptrCast(win), header);

    const grid = gtk.gtk_grid_new();
    gtk.gtk_grid_set_row_spacing(@ptrCast(grid), 10);
    gtk.gtk_grid_set_column_spacing(@ptrCast(grid), 12);
    gtk.gtk_widget_set_margin_top(grid, 16);
    gtk.gtk_widget_set_margin_bottom(grid, 16);
    gtk.gtk_widget_set_margin_start(grid, 16);
    gtk.gtk_widget_set_margin_end(grid, 16);

    const interval = gtk.gtk_spin_button_new_with_range(1, 100000, 1);
    gtk.gtk_spin_button_set_value(@ptrCast(interval), 50);
    attachRow(@ptrCast(grid), 0, "Intervalo (ms):", interval);

    const click = gtk.gtk_drop_down_new_from_strings(&[_]?[*:0]const u8{ "left", "right", "middle", null });
    attachRow(@ptrCast(grid), 1, "Clicar com:", click);

    const output = gtk.gtk_drop_down_new_from_strings(&[_]?[*:0]const u8{ "auto", "uinput", "ydotool", null });
    attachRow(@ptrCast(grid), 2, "Saída:", output);

    const device = gtk.gtk_entry_new();
    attachRow(@ptrCast(grid), 3, "Dispositivo:", device);

    const triggers_label = gtk.gtk_label_new("(nenhum)");
    gtk.gtk_label_set_xalign(@ptrCast(triggers_label), 0.0);
    attachRow(@ptrCast(grid), 4, "Gatilhos:", triggers_label);

    const cap_btn = gtk.gtk_button_new_with_label("Capturar tecla/botão");
    gtk.gtk_grid_attach(@ptrCast(grid), cap_btn, 1, 5, 1, 1);

    const mode_toggle = gtk.gtk_check_button_new_with_label("Modo alternar (toggle, em vez de segurar)");
    gtk.gtk_grid_attach(@ptrCast(grid), mode_toggle, 0, 6, 2, 1);

    const suppress = gtk.gtk_check_button_new_with_label("Suprimir voltar/avançar (só mouse)");
    gtk.gtk_grid_attach(@ptrCast(grid), suppress, 0, 7, 2, 1);

    const status = gtk.gtk_label_new("parado");
    gtk.gtk_widget_add_css_class(status, "status");
    gtk.gtk_grid_attach(@ptrCast(grid), status, 0, 8, 2, 1);

    const start = gtk.gtk_button_new_with_label("Iniciar");
    gtk.gtk_widget_add_css_class(start, "suggested-action");
    gtk.gtk_widget_add_css_class(start, "start");
    gtk.gtk_widget_set_hexpand(start, 1);
    gtk.gtk_grid_attach(@ptrCast(grid), start, 0, 9, 2, 1);

    gtk.gtk_window_set_child(@ptrCast(win), grid);

    ui.* = .{
        .interval = @ptrCast(interval),
        .mode_toggle = @ptrCast(mode_toggle),
        .click = @ptrCast(click),
        .output = @ptrCast(output),
        .device = @ptrCast(device),
        .suppress = @ptrCast(suppress),
        .status = @ptrCast(status),
        .start = @ptrCast(start),
        .triggers_label = @ptrCast(triggers_label),
        .codes = .empty,
        .child = null,
        .gpa = gpa,
    };

    _ = gtk.g_signal_connect_data(start, "clicked", @ptrCast(&onStart), ui, null, 0);
    _ = gtk.g_signal_connect_data(cap_btn, "clicked", @ptrCast(&onCapture), ui, null, 0);

    gtk.gtk_window_present(@ptrCast(win));
}

pub fn main() !void {
    const app = gtk.gtk_application_new("org.zclicker.gui", gtk.G_APPLICATION_DEFAULT_FLAGS);
    defer gtk.g_object_unref(app);
    _ = gtk.g_signal_connect_data(app, "activate", @ptrCast(&onActivate), null, null, 0);
    _ = gtk.g_application_run(@ptrCast(app), 0, null);
}
