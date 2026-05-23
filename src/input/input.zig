const std = @import("std");

/// Linux evdev codes for the side ("back"/"forward") mouse buttons,
/// which most users call buttons 4 and 5.
pub const BTN_SIDE: u16 = 0x113;
pub const BTN_EXTRA: u16 = 0x114;

/// A press or release of one of the configured trigger buttons.
pub const TriggerEvent = struct {
    button: u16,
    pressed: bool,
};

/// Runtime interface every platform input backend implements.
///
/// `nextEvent` blocks for up to `timeout_ms` (negative = forever) and returns
/// the next trigger event, or null if the timeout elapsed first. The timeout is
/// what drives the autoclick cadence, so the backend must honor it precisely.
pub const InputBackend = struct {
    ptr: *anyopaque,
    nextEventFn: *const fn (ptr: *anyopaque, timeout_ms: i32) anyerror!?TriggerEvent,

    pub fn nextEvent(self: InputBackend, timeout_ms: i32) anyerror!?TriggerEvent {
        return self.nextEventFn(self.ptr, timeout_ms);
    }
};
