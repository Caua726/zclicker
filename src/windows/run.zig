const std = @import("std");
const z = @import("zclicker"); // neutral: cli, core, backend
const WinInput = @import("input.zig").WinInput;
const WinOutput = @import("output.zig").WinOutput;

/// Windows engine (Stage 2): WH_MOUSE_LL input + SendInput output wired into
/// the shared core.run loop. Mouse-button triggers only for v1.
pub fn run(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    const cfg = z.cli.parse(args) catch |err| {
        std.debug.print("erro: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    if (cfg.help) {
        std.debug.print("zclicker (Windows) — gatilhos de mouse (4/5/left/right/middle), --click, --mode, -i, --suppress\n", .{});
        return;
    }
    if (cfg.list_backends) {
        std.debug.print("input:  winhook\noutput: sendinput\n", .{});
        return;
    }

    var input = WinInput.init(init.io, cfg.buttonCodes(), cfg.suppress);
    var output = WinOutput.init(cfg.click);
    try input.start();
    var triggers = z.core.Triggers{ .codes = cfg.buttonCodes() };
    std.debug.print("zclicker (windows): {d}ms | {s} | clica={s} | segure/alterne o gatilho | Ctrl+C\n", .{
        cfg.interval_ms, @tagName(cfg.mode), @tagName(cfg.click),
    });
    try z.core.run(input.interface(), output.interface(), &triggers, cfg.mode, cfg.interval_ms, cfg.verbose);
}
