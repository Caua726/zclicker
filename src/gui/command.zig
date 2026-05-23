const std = @import("std");

pub const Mode = enum { hold, toggle };
pub const Click = enum { left, right, middle };
pub const Output = enum { auto, uinput, ydotool };

pub const Config = struct {
    interval_ms: u32 = 50,
    mode: Mode = .hold,
    click: Click = .left,
    /// Trigger codes already resolved to evdev numbers (e.g. 275, 276).
    codes: []const u16 = &.{},
    output: Output = .auto,
    device: []const u8 = "", // empty = auto
    suppress: bool = false,
};

/// Build argv (argv[0] = bin_path). Caller owns the returned slice and each string;
/// use an arena to free them all at once.
pub fn buildArgv(arena: std.mem.Allocator, bin_path: []const u8, cfg: Config) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    try list.append(arena, bin_path);
    try list.append(arena, "-i");
    try list.append(arena, try std.fmt.allocPrint(arena, "{d}", .{cfg.interval_ms}));
    try list.append(arena, "--mode");
    try list.append(arena, @tagName(cfg.mode));
    try list.append(arena, "--click");
    try list.append(arena, @tagName(cfg.click));
    if (cfg.codes.len > 0) {
        var buf: std.ArrayList(u8) = .empty;
        for (cfg.codes, 0..) |code, idx| {
            if (idx != 0) try buf.append(arena, ',');
            try buf.print(arena, "{d}", .{code});
        }
        try list.append(arena, "-b");
        try list.append(arena, buf.items);
    }
    if (cfg.output != .auto) {
        try list.append(arena, "--output");
        try list.append(arena, @tagName(cfg.output));
    }
    if (cfg.device.len > 0) {
        try list.append(arena, "-d");
        try list.append(arena, cfg.device);
    }
    if (cfg.suppress) try list.append(arena, "--suppress");
    return list.items;
}

test "defaults" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const argv = try buildArgv(arena.allocator(), "zclicker", .{});
    try t.expectEqualStrings("zclicker", argv[0]);
    try t.expectEqualStrings("-i", argv[1]);
    try t.expectEqualStrings("50", argv[2]);
    try t.expectEqualStrings("--mode", argv[3]);
    try t.expectEqualStrings("hold", argv[4]);
    try t.expectEqualStrings("--click", argv[5]);
    try t.expectEqualStrings("left", argv[6]);
    try t.expectEqual(@as(usize, 7), argv.len); // no -b/--output/-d/--suppress by default
}

test "full options" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const codes = [_]u16{ 275, 276 };
    const argv = try buildArgv(arena.allocator(), "/bin/zclicker", .{
        .interval_ms = 30, .mode = .toggle, .click = .right,
        .codes = &codes, .output = .ydotool, .device = "/dev/input/event6", .suppress = true,
    });
    // find the -b value
    var saw_buttons = false;
    for (argv, 0..) |a, idx| {
        if (std.mem.eql(u8, a, "-b")) { try t.expectEqualStrings("275,276", argv[idx + 1]); saw_buttons = true; }
    }
    try t.expect(saw_buttons);
    try t.expectEqualStrings("toggle", argv[4]);
    try t.expectEqualStrings("right", argv[6]);
    // suppress present
    var saw_suppress = false;
    for (argv) |a| if (std.mem.eql(u8, a, "--suppress")) { saw_suppress = true; };
    try t.expect(saw_suppress);
}

test "auto output omits flag" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const argv = try buildArgv(arena.allocator(), "z", .{ .output = .auto });
    for (argv) |a| try t.expect(!std.mem.eql(u8, a, "--output"));
}
