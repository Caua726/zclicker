const std = @import("std");
const builtin = @import("builtin");
const z = @import("zclicker");
const select = z.select;
const build_options = @import("build_options");
const gui = if (build_options.gui) @import("gui/app.zig") else struct {};

var g_evdev: ?*z.LinuxEvdev = null;
var g_uinput: ?*z.Uinput = null;

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    if (g_evdev) |e| e.deinit();
    if (g_uinput) |u| u.deinit();
    std.process.exit(0);
}

fn installSignals() void {
    var act = std.posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

pub fn main(init: std.process.Init) !void {
    // The comptime-known `builtin.os.tag` ensures only the matching branch is
    // compiled, so the Linux-only `linuxMain` body is never analyzed on Windows
    // (and the Windows stub is never analyzed on Linux).
    if (builtin.os.tag == .windows) {
        return @import("windows/run.zig").run(init);
    } else {
        return linuxMain(init);
    }
}

fn linuxMain(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);

    if (build_options.gui) {
        if (args.len <= 1) { // bare `zclicker` → open the GUI
            try gui.launch();
            return;
        }
    }

    const cfg = z.cli.parse(args) catch |err| {
        std.debug.print("erro: {s}\n\n", .{@errorName(err)});
        printUsage();
        std.process.exit(2);
    };

    if (cfg.help) {
        printUsage();
        return;
    }
    if (cfg.list) {
        try z.LinuxEvdev.listDevices(cfg.buttonCodes());
        return;
    }
    if (cfg.list_backends) {
        std.debug.print("input:  evdev\noutput: uinput, ydotool, wlr, x11\n", .{});
        return;
    }
    if (cfg.print_env) {
        const e = probeEnv();
        // mirror main's auto preference: wlr on Wayland, x11 on X11, else uinput, else ydotool.
        const auto_out: z.backend.BackendId = if (e.session == .wayland)
            .wlr
        else if (e.session == .x11)
            .x11
        else if (e.has_uinput)
            .uinput
        else if (e.has_ydotoold)
            .ydotool
        else
            .uinput;
        std.debug.print("os: {s}\nsession: {s}\nuinput: {s}\nydotoold: {s}\nauto-output: {s}\n", .{
            @tagName(e.os),                    @tagName(e.session),
            if (e.has_uinput) "yes" else "no", if (e.has_ydotoold) "yes" else "no",
            @tagName(auto_out),
        });
        return;
    }

    var evdev = z.LinuxEvdev.init(cfg.device, cfg.buttonCodes(), cfg.suppress) catch |err| {
        switch (err) {
            error.NoDeviceFound => std.debug.print(
                "nenhum mouse com botões laterais encontrado. tente --list ou --device.\n",
                .{},
            ),
            error.AccessDenied => std.debug.print(
                "sem permissão pra ler /dev/input — confirme que você está no grupo 'input'.\n",
                .{},
            ),
            else => std.debug.print("erro abrindo dispositivo: {s}\n", .{@errorName(err)}),
        }
        std.process.exit(1);
    };
    defer evdev.deinit();
    g_evdev = &evdev;

    const env = probeEnv();
    const choice = select.resolve(env, .{
        .input = cfg.input,
        .output = cfg.output,
        .suppress = cfg.suppress,
    }) catch |err| {
        std.debug.print("seleção de backend falhou: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    var ydotool: z.Ydotool = undefined;
    var uinput: z.Uinput = undefined;
    var wlr: z.Wlr = undefined;
    var x11: z.X11 = undefined;

    // Candidate output backends in priority order. Explicit --output = just that one
    // (it must work). Auto = prefer wlr on Wayland (native, no daemon/uinput), x11
    // on X11 sessions, then uinput, then ydotool — falling back at runtime if a
    // backend can't initialize.
    var cands: [4]z.backend.BackendId = undefined;
    var nc: usize = 0;
    if (cfg.output) |forced| {
        cands[0] = forced;
        nc = 1;
    } else {
        if (env.session == .wayland) { cands[nc] = .wlr; nc += 1; }
        if (env.session == .x11) { cands[nc] = .x11; nc += 1; }
        if (env.has_uinput) { cands[nc] = .uinput; nc += 1; }
        if (env.has_ydotoold) { cands[nc] = .ydotool; nc += 1; }
        if (nc == 0) { cands[nc] = .uinput; nc += 1; }
    }

    var out_iface: z.backend.OutputBackend = undefined;
    var chosen: z.backend.BackendId = .uinput;
    var ok = false;
    for (cands[0..nc]) |cand| {
        switch (cand) {
            .wlr => {
                wlr = z.Wlr.init(cfg.click) catch continue;
                out_iface = wlr.interface();
                chosen = .wlr;
                ok = true;
            },
            .uinput => {
                uinput = z.Uinput.init(cfg.click) catch continue;
                g_uinput = &uinput;
                out_iface = uinput.interface();
                chosen = .uinput;
                ok = true;
            },
            .ydotool => {
                ydotool = z.Ydotool.init(io, cfg.click);
                out_iface = ydotool.interface();
                chosen = .ydotool;
                ok = true;
            },
            .x11 => {
                x11 = z.X11.init(cfg.click) catch continue;
                out_iface = x11.interface();
                chosen = .x11;
                ok = true;
            },
            .evdev => continue, // evdev is never an output
        }
        if (ok) break;
    }
    if (!ok) {
        std.debug.print("nenhum backend de saída disponível (tentei:", .{});
        for (cands[0..nc]) |c| std.debug.print(" {s}", .{@tagName(c)});
        std.debug.print(") — cheque /dev/uinput, o ydotoold, ou o suporte do compositor.\n", .{});
        std.process.exit(1);
    }
    defer switch (chosen) {
        .uinput => uinput.deinit(),
        .wlr => wlr.deinit(),
        .x11 => x11.deinit(),
        else => {},
    };

    var triggers = z.core.Triggers{ .codes = cfg.buttonCodes() };
    std.debug.print(
        "zclicker: {s} ({d} disp.) | {s}/{s} | {d}ms | {s} | clica={s} | in={s} out={s}{s} | Ctrl+C\n",
        .{ evdev.deviceName(), evdev.deviceCount(), @tagName(env.os), @tagName(env.session), cfg.interval_ms, @tagName(cfg.mode), @tagName(cfg.click), @tagName(choice.input), @tagName(chosen), if (cfg.suppress) " | suppress" else "" },
    );
    installSignals();
    try z.core.run(evdev.interface(), out_iface, &triggers, cfg.mode, cfg.interval_ms, cfg.verbose);
}

fn probeEnv() z.select.Env {
    var env = z.select.Env{};
    // /dev/uinput writable?
    if (z.platform.openRdwr("/dev/uinput")) |fd| {
        z.platform.closeFd(fd);
        env.has_uinput = true;
    } else |_| {}
    env.has_ydotoold = ydotoolSocketExists();
    env.session = detectSession();
    return env;
}

/// Best-effort session detection from runtime sockets (this std has no getenv).
fn detectSession() z.select.Session {
    const uid = std.os.linux.getuid();
    var buf: [128]u8 = undefined;
    inline for (.{ "wayland-0", "wayland-1" }) |name| {
        const p = std.fmt.bufPrintSentinel(&buf, "/run/user/{d}/{s}", .{ uid, name }, 0) catch return .unknown;
        if (@as(isize, @bitCast(std.os.linux.access(p.ptr, 0))) == 0) return .wayland;
    }
    if (@as(isize, @bitCast(std.os.linux.access("/tmp/.X11-unix/X0", 0))) == 0) return .x11;
    return .unknown;
}

fn ydotoolSocketExists() bool {
    var buf: [128]u8 = undefined;
    const uid = std.os.linux.getuid();
    const path = std.fmt.bufPrintSentinel(&buf, "/run/user/{d}/.ydotool_socket", .{uid}, 0) catch return false;
    // access(F_OK=0) returns 0 if the path exists. (open() on a socket inode would
    // wrongly fail with ENXIO, so use access, not open.)
    return @as(isize, @bitCast(std.os.linux.access(path.ptr, 0))) == 0;
}

fn printUsage() void {
    std.debug.print(
        \\zclicker - autoclicker (segure/alterna nos botões-gatilho pra clicar)
        \\
        \\uso: zclicker [opções]
        \\  -i, --interval <ms>    intervalo entre cliques (padrão 50)
        \\  -b, --buttons <lista>  gatilhos: nomes (left,right,middle,4,5,forward,back) ou códigos evdev, ex: 4,5 ou left,183
        \\  -d, --device <path>    /dev/input/eventX (padrão: autodetecta)
        \\  -l, --list             lista dispositivos com botões laterais
        \\  -v, --verbose          loga cada gatilho e clique
        \\      --suppress         suprime voltar/avançar nos botões 4/5 (via EVIOCGRAB)
        \\      --input <backend>  entrada: evdev
        \\      --output <backend> saída: uinput (padrão) ou ydotool
        \\      --list-backends    lista backends disponíveis
        \\      --print-env        mostra SO/sessão detectados e o backend automático
        \\      --click <btn>      botão clicado: left (padrão), right, middle
        \\      --mode <modo>      hold (padrão, segurar) ou toggle (alternar)
        \\  -h, --help             esta ajuda
        \\
    , .{});
}
