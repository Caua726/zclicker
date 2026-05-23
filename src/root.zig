//! zclicker library surface. The CLI (`src/main.zig`) is a thin wrapper over
//! these pieces, and future platform backends plug in alongside the existing
//! ones without touching the core loop.

pub const cli = @import("cli.zig");
pub const core = @import("core.zig");
pub const backend = @import("backend.zig");
pub const select = @import("select.zig");

pub const LinuxEvdev = @import("input/evdev.zig").LinuxEvdev;
pub const Ydotool = @import("output/ydotool.zig").Ydotool;
pub const Uinput = @import("output/uinput.zig").Uinput;

test {
    // Pull submodule tests into the `zig build test` run.
    _ = cli;
    _ = core;
    _ = @import("platform/linux.zig");
    _ = @import("select.zig");
}
