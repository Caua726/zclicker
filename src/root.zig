//! zclicker library surface. The CLI (`src/main.zig`) is a thin wrapper over
//! these pieces, and future platform backends plug in alongside the existing
//! ones without touching the core loop.

pub const cli = @import("cli.zig");
pub const core = @import("core.zig");
pub const input = @import("input/input.zig");
pub const output = @import("output/output.zig");

pub const LinuxEvdev = @import("input/linux_evdev.zig").LinuxEvdev;
pub const Ydotool = @import("output/ydotool.zig").Ydotool;

test {
    // Pull submodule tests into the `zig build test` run.
    _ = cli;
    _ = core;
}
