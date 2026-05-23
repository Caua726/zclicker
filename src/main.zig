const std = @import("std");
const z = @import("zclicker");

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

    var evdev = z.LinuxEvdev.init(cfg.device, cfg.buttonCodes()) catch |err| {
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

    var ydotool = z.Ydotool.init(io);
    var triggers = z.core.Triggers{ .codes = cfg.buttonCodes() };

    std.debug.print(
        "zclicker: {s} | {d}ms | segure botão 4/5 pra clicar | Ctrl+C pra sair\n",
        .{ evdev.deviceName(), cfg.interval_ms },
    );

    try z.core.run(evdev.backend(), ydotool.backend(), &triggers, cfg.interval_ms, cfg.verbose);
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
        \\  -h, --help             esta ajuda
        \\
    , .{});
}
