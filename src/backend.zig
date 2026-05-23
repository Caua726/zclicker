const std = @import("std");
const lx = @import("platform/linux.zig");

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
