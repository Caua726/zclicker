const std = @import("std");
const backend = @import("backend.zig");

pub const TriggerEvent = backend.TriggerEvent;

/// Tracks which configured trigger buttons are currently held. `codes` and the
/// first `codes.len` entries of `held` run in parallel.
pub const Triggers = struct {
    codes: []const u16,
    held: [8]bool = @splat(false),

    pub fn apply(self: *Triggers, ev: backend.TriggerEvent) void {
        for (self.codes, 0..) |code, i| {
            if (code == ev.button) self.held[i] = ev.pressed;
        }
    }

    pub fn anyHeld(self: *const Triggers) bool {
        for (self.codes, 0..) |_, i| {
            if (self.held[i]) return true;
        }
        return false;
    }
};

/// Toggle-mode activation: each trigger press flips it.
pub const Toggle = struct {
    active: bool = false,
    pub fn press(self: *Toggle) void {
        self.active = !self.active;
    }
};

/// Main event loop. While any trigger button is held (hold mode) or toggle is
/// active (toggle mode), emit a click every `interval_ms`. Single-threaded:
/// the timing comes from the input backend's poll timeout, so there are no
/// locks and no races.
pub fn run(
    in_backend: backend.InputBackend,
    out_backend: backend.OutputBackend,
    triggers: *Triggers,
    mode: backend.Mode,
    interval_ms: i32,
    verbose: bool,
) !void {
    var toggle = Toggle{};
    while (true) {
        const clicking = switch (mode) {
            .hold => triggers.anyHeld(),
            .toggle => toggle.active,
        };
        const timeout: i32 = if (clicking) interval_ms else -1;
        if (try in_backend.nextEvent(timeout)) |ev| {
            // The input backend only emits events for configured trigger codes,
            // so in toggle mode every press is a toggle.
            switch (mode) {
                .hold => triggers.apply(ev),
                .toggle => if (ev.pressed) toggle.press(),
            }
            if (verbose) {
                std.debug.print("[trigger] 0x{x} {s}\n", .{
                    ev.button,
                    if (ev.pressed) "down" else "up",
                });
            }
        } else {
            try out_backend.click();
            if (verbose) std.debug.print("[click]\n", .{});
        }
    }
}

test "anyHeld reflects press and release" {
    const t = std.testing;
    var codes = [_]u16{ backend.BTN_SIDE, backend.BTN_EXTRA };
    var trig = Triggers{ .codes = &codes };

    try t.expect(!trig.anyHeld());
    trig.apply(.{ .button = backend.BTN_SIDE, .pressed = true });
    try t.expect(trig.anyHeld());
    trig.apply(.{ .button = backend.BTN_SIDE, .pressed = false });
    try t.expect(!trig.anyHeld());
}

test "held until all buttons released" {
    const t = std.testing;
    var codes = [_]u16{ backend.BTN_SIDE, backend.BTN_EXTRA };
    var trig = Triggers{ .codes = &codes };

    trig.apply(.{ .button = backend.BTN_SIDE, .pressed = true });
    trig.apply(.{ .button = backend.BTN_EXTRA, .pressed = true });
    trig.apply(.{ .button = backend.BTN_SIDE, .pressed = false });
    try t.expect(trig.anyHeld()); // EXTRA still down
    trig.apply(.{ .button = backend.BTN_EXTRA, .pressed = false });
    try t.expect(!trig.anyHeld());
}

test "unconfigured button is ignored" {
    const t = std.testing;
    var codes = [_]u16{backend.BTN_SIDE};
    var trig = Triggers{ .codes = &codes };
    trig.apply(.{ .button = 0x110, .pressed = true }); // BTN_LEFT
    try t.expect(!trig.anyHeld());
}

test "Toggle flips active on each press" {
    const t = std.testing;
    var tg = Toggle{};
    try t.expect(!tg.active);
    tg.press();
    try t.expect(tg.active);
    tg.press();
    try t.expect(!tg.active);
}
