const std = @import("std");
const input = @import("input/input.zig");
const output = @import("output/output.zig");

pub const TriggerEvent = input.TriggerEvent;

/// Tracks which configured trigger buttons are currently held. `codes` and the
/// first `codes.len` entries of `held` run in parallel.
pub const Triggers = struct {
    codes: []const u16,
    held: [8]bool = @splat(false),

    pub fn apply(self: *Triggers, ev: input.TriggerEvent) void {
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

/// Main event loop. While any trigger button is held, emit a click every
/// `interval_ms`. Single-threaded: the timing comes from the input backend's
/// poll timeout, so there are no locks and no races. When nothing is held the
/// timeout is infinite, so the loop sleeps until the next button event.
pub fn run(
    in_backend: input.InputBackend,
    out_backend: output.OutputBackend,
    triggers: *Triggers,
    interval_ms: i32,
    verbose: bool,
) !void {
    while (true) {
        const timeout: i32 = if (triggers.anyHeld()) interval_ms else -1;
        if (try in_backend.nextEvent(timeout)) |ev| {
            triggers.apply(ev);
            if (verbose) {
                std.debug.print("[trigger] 0x{x} {s}\n", .{
                    ev.button,
                    if (ev.pressed) "down" else "up",
                });
            }
        } else {
            // Timeout with a button held -> fire one click.
            try out_backend.click();
            if (verbose) std.debug.print("[click]\n", .{});
        }
    }
}

test "anyHeld reflects press and release" {
    const t = std.testing;
    var codes = [_]u16{ input.BTN_SIDE, input.BTN_EXTRA };
    var trig = Triggers{ .codes = &codes };

    try t.expect(!trig.anyHeld());
    trig.apply(.{ .button = input.BTN_SIDE, .pressed = true });
    try t.expect(trig.anyHeld());
    trig.apply(.{ .button = input.BTN_SIDE, .pressed = false });
    try t.expect(!trig.anyHeld());
}

test "held until all buttons released" {
    const t = std.testing;
    var codes = [_]u16{ input.BTN_SIDE, input.BTN_EXTRA };
    var trig = Triggers{ .codes = &codes };

    trig.apply(.{ .button = input.BTN_SIDE, .pressed = true });
    trig.apply(.{ .button = input.BTN_EXTRA, .pressed = true });
    trig.apply(.{ .button = input.BTN_SIDE, .pressed = false });
    try t.expect(trig.anyHeld()); // EXTRA still down
    trig.apply(.{ .button = input.BTN_EXTRA, .pressed = false });
    try t.expect(!trig.anyHeld());
}

test "unconfigured button is ignored" {
    const t = std.testing;
    var codes = [_]u16{input.BTN_SIDE};
    var trig = Triggers{ .codes = &codes };
    trig.apply(.{ .button = 0x110, .pressed = true }); // BTN_LEFT
    try t.expect(!trig.anyHeld());
}
