const std = @import("std");
const gtk = @import("gtk.zig");
const command = @import("command.zig");
const capture = @import("capture.zig");

// evdev button codes used for friendly trigger labels.
const BTN_LEFT: u16 = 0x110;
const BTN_RIGHT: u16 = 0x111;
const BTN_MIDDLE: u16 = 0x112;
const BTN_SIDE: u16 = 0x113;
const BTN_EXTRA: u16 = 0x114;

const Ui = struct {
    // Start card
    start_card: *gtk.GtkWidget,
    on_toggle: *gtk.GtkToggleButton,
    off_toggle: *gtk.GtkToggleButton,
    rate_label: *gtk.GtkLabel,

    // Trigger card
    keycap: *gtk.GtkLabel,

    // Click card
    click: [3]*gtk.GtkToggleButton, // left, right, middle
    interval: *gtk.GtkScale,
    interval_label: *gtk.GtkLabel,

    // Mode card
    mode_hold: *gtk.GtkToggleButton,
    mode_toggle: *gtk.GtkToggleButton,

    // Advanced
    output: *gtk.GtkDropDown,
    suppress: *gtk.GtkSwitch,
    device_dd: *gtk.GtkDropDown,
    device_paths: [][:0]const u8, // parallel to dropdown indices 1..N; index 0 = "auto"

    // Status
    status: *gtk.GtkLabel,

    codes: std.ArrayList(u16) = .empty,
    child: ?*gtk.GSubprocess = null,
    gpa: std.mem.Allocator,
};

fn setupCss() void {
    const css =
        \\.card { background-color: alpha(currentColor, 0.04); border: 1px solid alpha(currentColor, 0.12); border-radius: 12px; padding: 12px; }
        \\.start-card.running { border: 2px solid #2ec27e; }
        \\.heading { font-weight: bold; }
        \\.dim { opacity: 0.6; }
        \\.keycap { background-color: alpha(currentColor, 0.10); border: 1px solid alpha(currentColor, 0.18); border-radius: 6px; padding: 2px 10px; font-weight: bold; }
        \\.rate { opacity: 0.8; }
        \\.status { font-weight: bold; margin-top: 4px; }
        \\.status.running { color: #2ec27e; }
    ;
    const provider = gtk.gtk_css_provider_new();
    gtk.gtk_css_provider_load_from_string(provider, css);
    const display = gtk.gdk_display_get_default() orelse return;
    gtk.gtk_style_context_add_provider_for_display(display, @ptrCast(provider), gtk.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
}

/// A vertical box styled as a rounded "card". If `heading` is non-null, a bold
/// label is appended first.
fn card(heading: ?[*:0]const u8) *gtk.GtkWidget {
    const box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 8);
    gtk.gtk_widget_add_css_class(box, "card");
    if (heading) |h| {
        const lbl = gtk.gtk_label_new(h);
        gtk.gtk_label_set_xalign(@ptrCast(lbl), 0.0);
        gtk.gtk_widget_add_css_class(lbl, "heading");
        gtk.gtk_box_append(@ptrCast(box), lbl);
    }
    return box;
}

/// A horizontal row box (used to lay out a label + control side by side).
fn row() *gtk.GtkWidget {
    return gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 8);
}

/// A dim left-aligned descriptive label.
fn dimLabel(text: [*:0]const u8) *gtk.GtkWidget {
    const lbl = gtk.gtk_label_new(text);
    gtk.gtk_label_set_xalign(@ptrCast(lbl), 0.0);
    gtk.gtk_widget_add_css_class(lbl, "dim");
    return lbl;
}

/// Build a segmented (`.linked`) control of grouped toggle buttons and append it
/// to `box_into`. The `active` index is set active; each created button is stored
/// into `out` (same length as `labels`).
fn segmented(box_into: *gtk.GtkWidget, labels: []const [*:0]const u8, active: usize, out: []*gtk.GtkToggleButton) void {
    const linked = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(linked, "linked");
    var first: ?*gtk.GtkToggleButton = null;
    for (labels, 0..) |label, i| {
        const btn = gtk.gtk_toggle_button_new_with_label(label);
        gtk.gtk_widget_set_hexpand(btn, 1);
        const tb: *gtk.GtkToggleButton = @ptrCast(btn);
        if (first) |f| {
            gtk.gtk_toggle_button_set_group(tb, f);
        } else {
            first = tb;
        }
        if (i == active) gtk.gtk_toggle_button_set_active(tb, 1);
        out[i] = tb;
        gtk.gtk_box_append(@ptrCast(linked), btn);
    }
    gtk.gtk_box_append(@ptrCast(box_into), linked);
}

fn refreshRate(ui: *Ui) void {
    const ms_f = gtk.gtk_range_get_value(@ptrCast(ui.interval));
    const ms: i64 = @intFromFloat(ms_f);
    const cps: i64 = if (ms > 0) @divTrunc(1000, ms) else 0;

    var rate_buf: [64]u8 = undefined;
    const rate = std.fmt.bufPrintSentinel(&rate_buf, "{d} CPS · {d} ms", .{ cps, ms }, 0) catch "—";
    gtk.gtk_label_set_text(@ptrCast(ui.rate_label), rate);

    var iv_buf: [32]u8 = undefined;
    const iv = std.fmt.bufPrintSentinel(&iv_buf, "{d} ms", .{ms}, 0) catch "—";
    gtk.gtk_label_set_text(@ptrCast(ui.interval_label), iv);
}

fn refreshTriggers(ui: *Ui) void {
    if (ui.codes.items.len == 0) {
        gtk.gtk_label_set_text(@ptrCast(ui.keycap), "(nenhum)");
        return;
    }
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    for (ui.codes.items, 0..) |code, i| {
        if (len + 8 >= buf.len) break; // room for " + NNNNN" + NUL
        if (i != 0) {
            const sep = " + ";
            @memcpy(buf[len .. len + sep.len], sep);
            len += sep.len;
        }
        const name: ?[]const u8 = switch (code) {
            BTN_SIDE => "M4",
            BTN_EXTRA => "M5",
            BTN_LEFT => "LMB",
            BTN_RIGHT => "RMB",
            BTN_MIDDLE => "MMB",
            else => null,
        };
        if (name) |nm| {
            if (len + nm.len >= buf.len) break;
            @memcpy(buf[len .. len + nm.len], nm);
            len += nm.len;
        } else {
            const s = std.fmt.bufPrint(buf[len..], "{d}", .{code}) catch break;
            len += s.len;
        }
    }
    buf[len] = 0; // len < buf.len guaranteed by the room checks above
    gtk.gtk_label_set_text(@ptrCast(ui.keycap), @ptrCast(buf[0..len :0]));
}

fn setRunning(ui: *Ui, running: bool) void {
    gtk.gtk_toggle_button_set_active(ui.on_toggle, if (running) 1 else 0);
    gtk.gtk_toggle_button_set_active(ui.off_toggle, if (running) 0 else 1);
    if (running) {
        gtk.gtk_widget_add_css_class(ui.start_card, "running");
        gtk.gtk_label_set_text(@ptrCast(ui.status), "● running");
        gtk.gtk_widget_add_css_class(@ptrCast(ui.status), "running");
    } else {
        gtk.gtk_widget_remove_css_class(ui.start_card, "running");
        gtk.gtk_label_set_text(@ptrCast(ui.status), "● parado");
        gtk.gtk_widget_remove_css_class(@ptrCast(ui.status), "running");
    }
}

fn setStatus(ui: *Ui, s: [*:0]const u8) void {
    gtk.gtk_label_set_text(@ptrCast(ui.status), s);
    gtk.gtk_widget_remove_css_class(@ptrCast(ui.status), "running");
}

fn readConfig(ui: *Ui) command.Config {
    const click: command.Click = blk: {
        if (gtk.gtk_toggle_button_get_active(ui.click[1]) != 0) break :blk .right;
        if (gtk.gtk_toggle_button_get_active(ui.click[2]) != 0) break :blk .middle;
        break :blk .left;
    };
    const output: command.Output = switch (gtk.gtk_drop_down_get_selected(ui.output)) {
        0 => .auto,
        1 => .uinput,
        2 => .ydotool,
        3 => .wlr,
        4 => .x11,
        else => .auto,
    };
    const ms: i64 = @intFromFloat(gtk.gtk_range_get_value(@ptrCast(ui.interval)));
    return .{
        .interval_ms = @intCast(ms),
        .mode = if (gtk.gtk_toggle_button_get_active(ui.mode_toggle) != 0) .toggle else .hold,
        .click = click,
        .codes = ui.codes.items,
        .output = output,
        .device = blk: {
            const sel = gtk.gtk_drop_down_get_selected(ui.device_dd);
            break :blk if (sel == 0 or sel > ui.device_paths.len) "" else ui.device_paths[sel - 1];
        },
        .suppress = gtk.gtk_switch_get_active(ui.suppress) != 0,
    };
}

/// Resolve the path of the currently-running executable (reads /proc/self/exe),
/// so the GUI spawns itself with engine flags.
fn resolveBin(arena: std.mem.Allocator) []const u8 {
    var buf: [4096]u8 = undefined;
    const n = std.os.linux.readlink("/proc/self/exe", &buf, buf.len);
    const sn = @as(isize, @bitCast(n));
    if (sn <= 0) return "zclicker";
    return arena.dupe(u8, buf[0..@intCast(sn)]) catch "zclicker";
}

fn onValueChanged(_: *gtk.GtkRange, data: gtk.gpointer) callconv(.c) void {
    const ui: *Ui = @ptrCast(@alignCast(data));
    refreshRate(ui);
}

fn onCapture(_: *gtk.GtkButton, data: gtk.gpointer) callconv(.c) void {
    const ui: *Ui = @ptrCast(@alignCast(data));
    const code = capture.captureNext() catch {
        setStatus(ui, "captura falhou (você está no grupo 'input'?)");
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
    setRunning(ui, false);
}

fn doStart(ui: *Ui) void {
    if (ui.child != null) return; // already running

    var arena_inst = std.heap.ArenaAllocator.init(ui.gpa);
    defer arena_inst.deinit(); // GSubprocess copies argv, so freeing after spawn is fine
    const arena = arena_inst.allocator();

    const bin = resolveBin(arena);
    const argv = command.buildArgv(arena, bin, readConfig(ui)) catch {
        setStatus(ui, "erro montando comando");
        setRunning(ui, false);
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
        setStatus(ui, "falha ao iniciar (zclicker no PATH? acesso a /dev/uinput?)");
        setRunning(ui, false);
        return;
    }
    ui.child = child;
    setRunning(ui, true);
    gtk.g_subprocess_wait_async(child.?, null, @ptrCast(&onChildExit), ui);
}

fn onOn(_: *gtk.GtkToggleButton, data: gtk.gpointer) callconv(.c) void {
    const ui: *Ui = @ptrCast(@alignCast(data));
    if (gtk.gtk_toggle_button_get_active(ui.on_toggle) == 0) return; // only react to activation
    doStart(ui);
}

fn onOff(_: *gtk.GtkToggleButton, data: gtk.gpointer) callconv(.c) void {
    const ui: *Ui = @ptrCast(@alignCast(data));
    if (gtk.gtk_toggle_button_get_active(ui.off_toggle) == 0) return; // only react to activation
    if (ui.child) |child| {
        gtk.g_subprocess_send_signal(child, @intFromEnum(std.posix.SIG.TERM));
        // onChildExit resets the UI fully when the process actually dies.
    }
}

fn onActivate(app: *gtk.GtkApplication, _: gtk.gpointer) callconv(.c) void {
    const gpa = std.heap.page_allocator;
    const ui = gpa.create(Ui) catch return;
    setupCss();

    const win = gtk.gtk_application_window_new(app);
    gtk.gtk_window_set_title(@ptrCast(win), "zclicker");
    gtk.gtk_window_set_default_size(@ptrCast(win), 420, 560);

    const header = gtk.gtk_header_bar_new();
    gtk.gtk_window_set_titlebar(@ptrCast(win), header);

    const outer = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 10);
    gtk.gtk_widget_set_margin_top(outer, 16);
    gtk.gtk_widget_set_margin_bottom(outer, 16);
    gtk.gtk_widget_set_margin_start(outer, 16);
    gtk.gtk_widget_set_margin_end(outer, 16);

    // --- 1. Start card -------------------------------------------------------
    const start_card = card(null);
    gtk.gtk_widget_add_css_class(start_card, "start-card");
    const start_row = row();
    const start_lbl = gtk.gtk_label_new("Start");
    gtk.gtk_widget_add_css_class(start_lbl, "heading");
    gtk.gtk_box_append(@ptrCast(start_row), start_lbl);

    var on_off: [2]*gtk.GtkToggleButton = undefined;
    const onoff_labels = [_][*:0]const u8{ "ON", "OFF" };
    const onoff_linked = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(onoff_linked, "linked");
    // build segmented inline so we can place it (not hexpand) in the row
    {
        var first: ?*gtk.GtkToggleButton = null;
        for (onoff_labels, 0..) |label, i| {
            const btn = gtk.gtk_toggle_button_new_with_label(label);
            const tb: *gtk.GtkToggleButton = @ptrCast(btn);
            if (first) |f| gtk.gtk_toggle_button_set_group(tb, f) else first = tb;
            on_off[i] = tb;
            gtk.gtk_box_append(@ptrCast(onoff_linked), btn);
        }
    }
    gtk.gtk_toggle_button_set_active(on_off[1], 1); // OFF active by default
    gtk.gtk_box_append(@ptrCast(start_row), onoff_linked);

    const rate_label = gtk.gtk_label_new("");
    gtk.gtk_widget_add_css_class(rate_label, "rate");
    gtk.gtk_widget_set_hexpand(rate_label, 1);
    gtk.gtk_label_set_xalign(@ptrCast(rate_label), 1.0);
    gtk.gtk_box_append(@ptrCast(start_row), rate_label);

    gtk.gtk_box_append(@ptrCast(start_card), start_row);
    gtk.gtk_box_append(@ptrCast(outer), start_card);

    // --- 2. Trigger card -----------------------------------------------------
    const trigger_card = card("Trigger");
    const trig_row = row();
    gtk.gtk_box_append(@ptrCast(trig_row), dimLabel("Bound input"));
    const keycap = gtk.gtk_label_new("(nenhum)");
    gtk.gtk_widget_add_css_class(keycap, "keycap");
    gtk.gtk_box_append(@ptrCast(trig_row), keycap);
    const rebind = gtk.gtk_button_new_with_label("Rebind");
    gtk.gtk_widget_set_hexpand(rebind, 1);
    gtk.gtk_widget_set_halign(rebind, gtk.GTK_ALIGN_END);
    gtk.gtk_box_append(@ptrCast(trig_row), rebind);
    gtk.gtk_box_append(@ptrCast(trigger_card), trig_row);
    gtk.gtk_box_append(@ptrCast(outer), trigger_card);

    // --- 3. Click card -------------------------------------------------------
    const click_card = card("Click");
    // Mouse button row
    const mb_row = row();
    gtk.gtk_box_append(@ptrCast(mb_row), dimLabel("Mouse button"));
    const mb_seg = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_set_hexpand(mb_seg, 1);
    gtk.gtk_widget_set_halign(mb_seg, gtk.GTK_ALIGN_END);
    var click: [3]*gtk.GtkToggleButton = undefined;
    const click_labels = [_][*:0]const u8{ "Left", "Right", "Middle" };
    segmented(mb_seg, &click_labels, 0, &click);
    gtk.gtk_box_append(@ptrCast(mb_row), mb_seg);
    gtk.gtk_box_append(@ptrCast(click_card), mb_row);

    // Interval row
    const iv_row = row();
    gtk.gtk_box_append(@ptrCast(iv_row), dimLabel("Interval"));
    const interval = gtk.gtk_scale_new_with_range(gtk.GTK_ORIENTATION_HORIZONTAL, 1, 200, 1);
    gtk.gtk_range_set_value(@ptrCast(interval), 50);
    gtk.gtk_widget_set_hexpand(interval, 1);
    gtk.gtk_box_append(@ptrCast(iv_row), interval);
    const interval_label = gtk.gtk_label_new("50 ms");
    gtk.gtk_widget_set_size_request(interval_label, 56, -1);
    gtk.gtk_label_set_xalign(@ptrCast(interval_label), 1.0);
    gtk.gtk_box_append(@ptrCast(iv_row), interval_label);
    gtk.gtk_box_append(@ptrCast(click_card), iv_row);
    gtk.gtk_box_append(@ptrCast(outer), click_card);

    // --- 4. Mode card --------------------------------------------------------
    const mode_card = card("Mode");
    var mode_btns: [2]*gtk.GtkToggleButton = undefined;
    const mode_labels = [_][*:0]const u8{ "Hold", "Toggle" };
    segmented(mode_card, &mode_labels, 0, &mode_btns);
    gtk.gtk_box_append(@ptrCast(outer), mode_card);

    // --- 5. Advanced (expander) ----------------------------------------------
    const advanced = gtk.gtk_expander_new("Advanced");
    gtk.gtk_expander_set_expanded(@ptrCast(advanced), 0);
    const adv_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 8);
    gtk.gtk_widget_set_margin_top(adv_box, 8);

    const out_row = row();
    gtk.gtk_box_append(@ptrCast(out_row), dimLabel("Output backend"));
    const output = gtk.gtk_drop_down_new_from_strings(&[_]?[*:0]const u8{ "auto", "uinput", "ydotool", "wlr", "x11", null });
    gtk.gtk_widget_set_hexpand(output, 1);
    gtk.gtk_widget_set_halign(output, gtk.GTK_ALIGN_END);
    gtk.gtk_box_append(@ptrCast(out_row), output);
    gtk.gtk_box_append(@ptrCast(adv_box), out_row);

    const sup_row = row();
    gtk.gtk_box_append(@ptrCast(sup_row), dimLabel("Suppress back/forward"));
    const suppress = gtk.gtk_switch_new();
    gtk.gtk_widget_set_hexpand(suppress, 1);
    gtk.gtk_widget_set_halign(suppress, gtk.GTK_ALIGN_END);
    gtk.gtk_widget_set_valign(suppress, gtk.GTK_ALIGN_CENTER);
    gtk.gtk_box_append(@ptrCast(sup_row), suppress);
    gtk.gtk_box_append(@ptrCast(adv_box), sup_row);

    const dev_row = row();
    gtk.gtk_box_append(@ptrCast(dev_row), dimLabel("Device"));
    const dev_entries = capture.listDevices(gpa) catch &[_]capture.Entry{};
    const dev_strings = gpa.alloc(?[*:0]const u8, dev_entries.len + 2) catch unreachable;
    dev_strings[0] = "auto (todos)";
    for (dev_entries, 0..) |e, i| dev_strings[i + 1] = e.name.ptr;
    dev_strings[dev_entries.len + 1] = null;
    const device_dd = gtk.gtk_drop_down_new_from_strings(dev_strings.ptr);
    gtk.gtk_widget_set_hexpand(device_dd, 1);
    gtk.gtk_widget_set_halign(device_dd, gtk.GTK_ALIGN_END);
    const dev_paths = gpa.alloc([:0]const u8, dev_entries.len) catch unreachable;
    for (dev_entries, 0..) |e, i| dev_paths[i] = e.path;
    gtk.gtk_box_append(@ptrCast(dev_row), device_dd);
    gtk.gtk_box_append(@ptrCast(adv_box), dev_row);

    gtk.gtk_expander_set_child(@ptrCast(advanced), adv_box);
    gtk.gtk_box_append(@ptrCast(outer), advanced);

    // --- 6. Status line ------------------------------------------------------
    const status = gtk.gtk_label_new("● parado");
    gtk.gtk_widget_add_css_class(status, "status");
    gtk.gtk_label_set_xalign(@ptrCast(status), 0.0);
    gtk.gtk_box_append(@ptrCast(outer), status);

    gtk.gtk_window_set_child(@ptrCast(win), outer);

    ui.* = .{
        .start_card = start_card,
        .on_toggle = on_off[0],
        .off_toggle = on_off[1],
        .rate_label = @ptrCast(rate_label),
        .keycap = @ptrCast(keycap),
        .click = click,
        .interval = @ptrCast(interval),
        .interval_label = @ptrCast(interval_label),
        .mode_hold = mode_btns[0],
        .mode_toggle = mode_btns[1],
        .output = @ptrCast(output),
        .suppress = @ptrCast(suppress),
        .device_dd = @ptrCast(device_dd),
        .device_paths = dev_paths,
        .status = @ptrCast(status),
        .codes = .empty,
        .child = null,
        .gpa = gpa,
    };

    refreshRate(ui);

    _ = gtk.g_signal_connect_data(on_off[0], "clicked", @ptrCast(&onOn), ui, null, 0);
    _ = gtk.g_signal_connect_data(on_off[1], "clicked", @ptrCast(&onOff), ui, null, 0);
    _ = gtk.g_signal_connect_data(rebind, "clicked", @ptrCast(&onCapture), ui, null, 0);
    _ = gtk.g_signal_connect_data(interval, "value-changed", @ptrCast(&onValueChanged), ui, null, 0);

    gtk.gtk_window_present(@ptrCast(win));
}

pub fn launch() !void {
    const app = gtk.gtk_application_new("org.zclicker.gui", gtk.G_APPLICATION_DEFAULT_FLAGS);
    defer gtk.g_object_unref(app);
    _ = gtk.g_signal_connect_data(app, "activate", @ptrCast(&onActivate), null, null, 0);
    _ = gtk.g_application_run(@ptrCast(app), 0, null);
}
