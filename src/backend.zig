const std = @import("std");
const lx = @import("codes.zig");

pub const BTN_SIDE = lx.BTN_SIDE;
pub const BTN_EXTRA = lx.BTN_EXTRA;

pub const TriggerEvent = struct {
    button: u16,
    pressed: bool,
};

pub const BackendId = enum {
    evdev,
    uinput, // native uinput output backend (default)
    ydotool,
    wlr, // wlroots zwlr_virtual_pointer_v1 (Wayland native, no daemon)
    x11, // X11 XTest extension
    pub fn parse(s: []const u8) ?BackendId {
        inline for (@typeInfo(BackendId).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @field(BackendId, f.name);
        }
        return null;
    }
};

pub const Capabilities = struct {
    /// Input can swallow the trigger buttons so they don't reach apps.
    can_suppress: bool = false,
};

pub const InputBackend = struct {
    ptr: *anyopaque,
    caps: Capabilities,
    nextEventFn: *const fn (ptr: *anyopaque, timeout_ms: i32) anyerror!?TriggerEvent,
    pub fn nextEvent(self: InputBackend, timeout_ms: i32) anyerror!?TriggerEvent {
        return self.nextEventFn(self.ptr, timeout_ms);
    }
};

pub const OutputBackend = struct {
    ptr: *anyopaque,
    clickFn: *const fn (ptr: *anyopaque) anyerror!void,
    pub fn click(self: OutputBackend) anyerror!void {
        return self.clickFn(self.ptr);
    }
};

pub const ClickButton = enum {
    left,
    right,
    middle,
    pub fn evdevCode(self: ClickButton) u16 {
        return switch (self) {
            .left => lx.BTN_LEFT,
            .right => lx.BTN_RIGHT,
            .middle => lx.BTN_MIDDLE,
        };
    }
    /// X11 XTest button number: left=1, middle=2, right=3.
    pub fn x11Button(self: ClickButton) c_uint {
        return switch (self) { .left => 1, .middle => 2, .right => 3 };
    }
    /// ydotool hex button code: low nibble = button, 0x40 down + 0x80 up.
    pub fn ydotoolHex(self: ClickButton) []const u8 {
        return switch (self) {
            .left => "0xC0",
            .right => "0xC1",
            .middle => "0xC2",
        };
    }
    pub fn parse(s: []const u8) ?ClickButton {
        inline for (@typeInfo(ClickButton).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @field(ClickButton, f.name);
        }
        return null;
    }
};

pub const Mode = enum {
    hold,
    toggle,
    pub fn parse(s: []const u8) ?Mode {
        inline for (@typeInfo(Mode).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @field(Mode, f.name);
        }
        return null;
    }
};

test "ClickButton maps to evdev codes and ydotool hex" {
    const t = std.testing;
    try t.expectEqual(lx.BTN_LEFT, ClickButton.left.evdevCode());
    try t.expectEqual(lx.BTN_RIGHT, ClickButton.right.evdevCode());
    try t.expectEqual(lx.BTN_MIDDLE, ClickButton.middle.evdevCode());
    try t.expectEqualStrings("0xC0", ClickButton.left.ydotoolHex());
    try t.expectEqualStrings("0xC1", ClickButton.right.ydotoolHex());
    try t.expectEqualStrings("0xC2", ClickButton.middle.ydotoolHex());
    try t.expectEqual(ClickButton.middle, ClickButton.parse("middle").?);
    try t.expect(ClickButton.parse("nope") == null);
}

test "Mode parse" {
    const t = std.testing;
    try t.expectEqual(Mode.hold, Mode.parse("hold").?);
    try t.expectEqual(Mode.toggle, Mode.parse("toggle").?);
    try t.expect(Mode.parse("x") == null);
}
