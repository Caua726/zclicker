//! Windows input backend: a WH_MOUSE_LL low-level mouse hook running on its own
//! thread. The hook translates Win32 mouse buttons into the evdev code space the
//! rest of the app uses (see codes.zig), pushes matching trigger events onto a
//! small ring buffer, and (optionally) swallows the trigger button by returning 1.
//! The core loop drains the buffer via nextEvent.

const std = @import("std");
const z = @import("zclicker");
const backend = z.backend;
const codes = z.codes;
const w = @import("win32.zig");

const Io = std.Io;

const QCAP = 64;
var g_self: ?*WinInput = null;

pub const WinInput = struct {
    io: Io,
    codes: []const u16,
    suppress: bool,
    buf: [QCAP]backend.TriggerEvent = undefined,
    head: usize = 0,
    tail: usize = 0,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    thread: ?std.Thread = null,

    pub fn init(io: Io, codes_: []const u16, suppress: bool) WinInput {
        return .{ .io = io, .codes = codes_, .suppress = suppress };
    }

    /// Call after the WinInput has a stable address (it registers a global pointer
    /// so the C callback can reach it).
    pub fn start(self: *WinInput) !void {
        g_self = self;
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    pub fn deinit(self: *WinInput) void {
        _ = self; // process exit tears down the hook/thread
    }

    pub fn interface(self: *WinInput) backend.InputBackend {
        return .{ .ptr = self, .caps = .{ .can_suppress = true }, .nextEventFn = nextEventImpl };
    }

    fn push(self: *WinInput, e: backend.TriggerEvent) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const n = (self.tail + 1) % QCAP;
        if (n == self.head) return; // full, drop
        self.buf[self.tail] = e;
        self.tail = n;
        self.cond.signal(self.io);
    }

    fn nextEventImpl(ptr: *anyopaque, timeout_ms: i32) anyerror!?backend.TriggerEvent {
        const self: *WinInput = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.head == self.tail) {
            if (timeout_ms < 0) {
                self.cond.wait(self.io, &self.mutex) catch {};
            } else {
                const timeout: Io.Timeout = .{ .duration = .{
                    .raw = Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
                    .clock = .awake,
                } };
                self.cond.waitTimeout(self.io, &self.mutex, timeout) catch return null;
            }
        }
        if (self.head == self.tail) return null;
        const e = self.buf[self.head];
        self.head = (self.head + 1) % QCAP;
        return e;
    }

    fn threadMain(self: *WinInput) void {
        _ = self;
        _ = w.SetWindowsHookExW(w.WH_MOUSE_LL, hookProc, null, 0);
        var msg: w.MSG = undefined;
        while (w.GetMessageW(&msg, null, 0, 0) > 0) {}
    }
};

fn isTrigger(list: []const u16, code: u16) bool {
    for (list) |c| if (c == code) return true;
    return false;
}

fn hookProc(nCode: c_int, wParam: w.WPARAM, lParam: w.LPARAM) callconv(.winapi) w.LRESULT {
    if (nCode >= 0) {
        if (g_self) |self| {
            const info: *w.MSLLHOOKSTRUCT = @ptrFromInt(@as(usize, @bitCast(lParam)));
            var code: u16 = 0;
            var pressed = false;
            var hit = true;
            switch (wParam) {
                w.WM_LBUTTONDOWN => {
                    code = codes.BTN_LEFT;
                    pressed = true;
                },
                w.WM_LBUTTONUP => {
                    code = codes.BTN_LEFT;
                    pressed = false;
                },
                w.WM_RBUTTONDOWN => {
                    code = codes.BTN_RIGHT;
                    pressed = true;
                },
                w.WM_RBUTTONUP => {
                    code = codes.BTN_RIGHT;
                    pressed = false;
                },
                w.WM_MBUTTONDOWN => {
                    code = codes.BTN_MIDDLE;
                    pressed = true;
                },
                w.WM_MBUTTONUP => {
                    code = codes.BTN_MIDDLE;
                    pressed = false;
                },
                w.WM_XBUTTONDOWN, w.WM_XBUTTONUP => {
                    const xb: u16 = @truncate(info.mouseData >> 16);
                    code = if (xb == w.XBUTTON1) codes.BTN_SIDE else codes.BTN_EXTRA;
                    pressed = (wParam == w.WM_XBUTTONDOWN);
                },
                else => hit = false,
            }
            if (hit and isTrigger(self.codes, code)) {
                self.push(.{ .button = code, .pressed = pressed });
                if (self.suppress) return 1; // swallow the trigger button
            }
        }
    }
    return w.CallNextHookEx(null, nCode, wParam, lParam);
}
