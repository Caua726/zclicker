const std = @import("std");
const backend = @import("backend.zig");
const lx = @import("platform/linux.zig");

pub const Config = struct {
    interval_ms: i32 = 50,
    device: ?[]const u8 = null,
    buttons: [8]u16 = @splat(0),
    button_count: usize = 0,
    verbose: bool = false,
    list: bool = false,
    help: bool = false,
    input: ?backend.BackendId = null,
    output: ?backend.BackendId = null,
    suppress: bool = false,
    list_backends: bool = false,
    click: backend.ClickButton = .left,
    mode: backend.Mode = .hold,

    pub fn buttonCodes(self: *const Config) []const u16 {
        return self.buttons[0..self.button_count];
    }
};

pub const Error = error{ UnknownArgument, MissingValue, InvalidInterval, InvalidButton, UnknownBackend, InvalidClick, InvalidMode };

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Map a trigger token to an evdev code. Accepts named aliases (mouse buttons) or a
/// raw decimal evdev code (covers keyboard keys, e.g. 183 = KEY_F13).
fn buttonCode(name: []const u8) ?u16 {
    if (eq(name, "left")) return lx.BTN_LEFT;
    if (eq(name, "right")) return lx.BTN_RIGHT;
    if (eq(name, "middle")) return lx.BTN_MIDDLE;
    if (eq(name, "4") or eq(name, "side")) return lx.BTN_SIDE;
    if (eq(name, "5") or eq(name, "extra")) return lx.BTN_EXTRA;
    if (eq(name, "forward")) return lx.BTN_FORWARD;
    if (eq(name, "back")) return lx.BTN_BACK;
    if (eq(name, "task")) return lx.BTN_TASK;
    return std.fmt.parseInt(u16, name, 10) catch null;
}

fn parseButtons(cfg: *Config, spec: []const u8) Error!void {
    cfg.button_count = 0;
    var it = std.mem.tokenizeScalar(u8, spec, ',');
    while (it.next()) |tok| {
        if (cfg.button_count >= cfg.buttons.len) return Error.InvalidButton;
        cfg.buttons[cfg.button_count] = buttonCode(tok) orelse return Error.InvalidButton;
        cfg.button_count += 1;
    }
    if (cfg.button_count == 0) return Error.InvalidButton;
}

/// Parse argv (including argv[0]) into a Config.
pub fn parse(args: []const [:0]const u8) Error!Config {
    var cfg = Config{};
    // Default trigger buttons: 4 and 5.
    cfg.buttons[0] = backend.BTN_SIDE;
    cfg.buttons[1] = backend.BTN_EXTRA;
    cfg.button_count = 2;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eq(a, "-h") or eq(a, "--help")) {
            cfg.help = true;
        } else if (eq(a, "-l") or eq(a, "--list")) {
            cfg.list = true;
        } else if (eq(a, "-v") or eq(a, "--verbose")) {
            cfg.verbose = true;
        } else if (eq(a, "-i") or eq(a, "--interval")) {
            i += 1;
            if (i >= args.len) return Error.MissingValue;
            cfg.interval_ms = std.fmt.parseInt(i32, args[i], 10) catch return Error.InvalidInterval;
            if (cfg.interval_ms <= 0) return Error.InvalidInterval;
        } else if (eq(a, "-d") or eq(a, "--device")) {
            i += 1;
            if (i >= args.len) return Error.MissingValue;
            cfg.device = args[i];
        } else if (eq(a, "-b") or eq(a, "--buttons")) {
            i += 1;
            if (i >= args.len) return Error.MissingValue;
            try parseButtons(&cfg, args[i]);
        } else if (eq(a, "--input")) {
            i += 1;
            if (i >= args.len) return Error.MissingValue;
            cfg.input = backend.BackendId.parse(args[i]) orelse return Error.UnknownBackend;
        } else if (eq(a, "--output")) {
            i += 1;
            if (i >= args.len) return Error.MissingValue;
            cfg.output = backend.BackendId.parse(args[i]) orelse return Error.UnknownBackend;
        } else if (eq(a, "--suppress")) {
            cfg.suppress = true;
        } else if (eq(a, "--list-backends")) {
            cfg.list_backends = true;
        } else if (eq(a, "--click")) {
            i += 1;
            if (i >= args.len) return Error.MissingValue;
            cfg.click = backend.ClickButton.parse(args[i]) orelse return Error.InvalidClick;
        } else if (eq(a, "--mode")) {
            i += 1;
            if (i >= args.len) return Error.MissingValue;
            cfg.mode = backend.Mode.parse(args[i]) orelse return Error.InvalidMode;
        } else {
            return Error.UnknownArgument;
        }
    }
    return cfg;
}

test "defaults" {
    const t = std.testing;
    const args = [_][:0]const u8{"zclicker"};
    const cfg = try parse(&args);
    try t.expectEqual(@as(i32, 50), cfg.interval_ms);
    try t.expectEqual(@as(usize, 2), cfg.button_count);
    try t.expect(cfg.device == null);
}

test "interval override" {
    const t = std.testing;
    const args = [_][:0]const u8{ "zclicker", "--interval", "100" };
    const cfg = try parse(&args);
    try t.expectEqual(@as(i32, 100), cfg.interval_ms);
}

test "buttons override" {
    const t = std.testing;
    const args = [_][:0]const u8{ "zclicker", "-b", "4" };
    const cfg = try parse(&args);
    try t.expectEqual(@as(usize, 1), cfg.button_count);
    try t.expectEqual(backend.BTN_SIDE, cfg.buttons[0]);
}

test "unknown arg errors" {
    const t = std.testing;
    const args = [_][:0]const u8{ "zclicker", "--nope" };
    try t.expectError(Error.UnknownArgument, parse(&args));
}

test "non-numeric interval errors" {
    const t = std.testing;
    const args = [_][:0]const u8{ "zclicker", "-i", "abc" };
    try t.expectError(Error.InvalidInterval, parse(&args));
}

test "missing value errors" {
    const t = std.testing;
    const args = [_][:0]const u8{ "zclicker", "--interval" };
    try t.expectError(Error.MissingValue, parse(&args));
}

test "input/output/suppress flags parse" {
    const t = std.testing;
    const args = [_][:0]const u8{ "zclicker", "--input", "evdev", "--output", "uinput", "--suppress" };
    const cfg = try parse(&args);
    try t.expectEqual(backend.BackendId.evdev, cfg.input.?);
    try t.expectEqual(backend.BackendId.uinput, cfg.output.?);
    try t.expect(cfg.suppress);
}

test "unknown backend errors" {
    const t = std.testing;
    const args = [_][:0]const u8{ "zclicker", "--output", "nope" };
    try t.expectError(Error.UnknownBackend, parse(&args));
}

test "list-backends flag" {
    const t = std.testing;
    const args = [_][:0]const u8{ "zclicker", "--list-backends" };
    const cfg = try parse(&args);
    try t.expect(cfg.list_backends);
}

test "click and mode flags parse" {
    const t = std.testing;
    const args = [_][:0]const u8{ "zclicker", "--click", "right", "--mode", "toggle" };
    const cfg = try parse(&args);
    try t.expectEqual(backend.ClickButton.right, cfg.click);
    try t.expectEqual(backend.Mode.toggle, cfg.mode);
}

test "click/mode defaults" {
    const t = std.testing;
    const args = [_][:0]const u8{"zclicker"};
    const cfg = try parse(&args);
    try t.expectEqual(backend.ClickButton.left, cfg.click);
    try t.expectEqual(backend.Mode.hold, cfg.mode);
}

test "invalid click errors" {
    const t = std.testing;
    const args = [_][:0]const u8{ "zclicker", "--click", "sideways" };
    try t.expectError(Error.InvalidClick, parse(&args));
}

test "invalid mode errors" {
    const t = std.testing;
    const args = [_][:0]const u8{ "zclicker", "--mode", "spam" };
    try t.expectError(Error.InvalidMode, parse(&args));
}

test "buttons: aliases and raw codes" {
    const t = std.testing;
    {
        const args = [_][:0]const u8{ "zclicker", "-b", "left,right" };
        const cfg = try parse(&args);
        try t.expectEqual(@as(usize, 2), cfg.button_count);
        try t.expectEqual(lx.BTN_LEFT, cfg.buttons[0]);
        try t.expectEqual(lx.BTN_RIGHT, cfg.buttons[1]);
    }
    {
        const args = [_][:0]const u8{ "zclicker", "-b", "183" }; // KEY_F13
        const cfg = try parse(&args);
        try t.expectEqual(@as(usize, 1), cfg.button_count);
        try t.expectEqual(@as(u16, 183), cfg.buttons[0]);
    }
    {
        const args = [_][:0]const u8{ "zclicker", "-b", "4,extra,middle" };
        const cfg = try parse(&args);
        try t.expectEqual(@as(usize, 3), cfg.button_count);
        try t.expectEqual(lx.BTN_SIDE, cfg.buttons[0]);
        try t.expectEqual(lx.BTN_EXTRA, cfg.buttons[1]);
        try t.expectEqual(lx.BTN_MIDDLE, cfg.buttons[2]);
    }
}

test "buttons: invalid token errors" {
    const t = std.testing;
    const args = [_][:0]const u8{ "zclicker", "-b", "wat" };
    try t.expectError(Error.InvalidButton, parse(&args));
}
