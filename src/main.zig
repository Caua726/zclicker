const std = @import("std");
const z = @import("zclicker");
const select = z.select;

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
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);

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
        std.debug.print("input:  evdev\noutput: uinput, ydotool\n", .{});
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
    const out_iface: z.backend.OutputBackend = switch (choice.output) {
        .uinput => blk: {
            uinput = z.Uinput.init() catch |err| {
                std.debug.print("uinput indisponível ({s}); tente --output ydotool ou dê acesso a /dev/uinput.\n", .{@errorName(err)});
                std.process.exit(1);
            };
            g_uinput = &uinput;
            break :blk uinput.interface();
        },
        .ydotool => blk: {
            ydotool = z.Ydotool.init(io);
            break :blk ydotool.interface();
        },
        .evdev => unreachable, // evdev is never an output
    };
    defer if (choice.output == .uinput) uinput.deinit();

    var triggers = z.core.Triggers{ .codes = cfg.buttonCodes() };
    std.debug.print("zclicker: {s} | {d}ms | in={s} out={s}{s} | Ctrl+C\n", .{
        evdev.deviceName(), cfg.interval_ms, @tagName(choice.input), @tagName(choice.output),
        if (cfg.suppress) " | suppress" else "",
    });
    installSignals();
    try z.core.run(evdev.interface(), out_iface, &triggers, cfg.interval_ms, cfg.verbose);
}

fn probeEnv() z.select.Env {
    var env = z.select.Env{};
    // /dev/uinput writable?
    if (z.platform.openRdwr("/dev/uinput")) |fd| {
        z.platform.closeFd(fd);
        env.has_uinput = true;
    } else |_| {}
    env.has_ydotoold = ydotoolSocketExists();
    // session is cosmetic for now (resolve ignores it); leave as .unknown.
    return env;
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
        \\zclicker - autoclicker (segure botão 4/5 do mouse pra clicar com o esquerdo)
        \\
        \\uso: zclicker [opções]
        \\  -i, --interval <ms>    intervalo entre cliques (padrão 50)
        \\  -b, --buttons <lista>  botões-gatilho, ex: 4,5 (padrão 4,5)
        \\  -d, --device <path>    /dev/input/eventX (padrão: autodetecta)
        \\  -l, --list             lista dispositivos com botões laterais
        \\  -v, --verbose          loga cada gatilho e clique
        \\      --suppress         suprime voltar/avançar nos botões 4/5 (via EVIOCGRAB)
        \\      --input <backend>  entrada: evdev
        \\      --output <backend> saída: uinput (padrão) ou ydotool
        \\      --list-backends    lista backends disponíveis
        \\  -h, --help             esta ajuda
        \\
    , .{});
}
