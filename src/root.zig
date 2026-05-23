//! zclicker library surface. The CLI (`src/main.zig`) is a thin wrapper over
//! these pieces, and future platform backends plug in alongside the existing
//! ones without touching the core loop.

const builtin = @import("builtin");
const is_linux = builtin.os.tag == .linux;

// Platform-neutral modules — always available.
pub const cli = @import("cli.zig");
pub const core = @import("core.zig");
pub const backend = @import("backend.zig");
pub const select = @import("select.zig");
pub const codes = @import("codes.zig");

// Linux-only modules. The `if (is_linux) @import(...) else struct{}/void`
// pattern means the untaken comptime branch is never analyzed, so these
// Linux-only files don't have to compile on non-Linux targets.
pub const platform = if (is_linux) @import("platform/linux.zig") else struct {};
pub const LinuxEvdev = if (is_linux) @import("input/evdev.zig").LinuxEvdev else void;
pub const Ydotool = if (is_linux) @import("output/ydotool.zig").Ydotool else void;
pub const Uinput = if (is_linux) @import("output/uinput.zig").Uinput else void;
pub const Wlr = if (is_linux) @import("output/wlr.zig").Wlr else void;
pub const X11 = if (is_linux) @import("output/x11.zig").X11 else void;

test {
    // Pull neutral submodule tests into the `zig build test` run (always Linux here).
    _ = cli;
    _ = core;
    _ = backend;
    _ = select;
    _ = codes;
    if (is_linux) _ = platform; // keep the Linux ioctl-constant test running
}
