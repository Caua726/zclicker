# SP2 — Flexible Triggers + Multi-Device — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Trigger on any mouse button **or** keyboard key: `--buttons` accepts named aliases and raw evdev codes, and the engine reads *every* input device that holds a configured trigger code.

**Architecture:** `evdev.zig` changes from a single fd to a fixed array of `Device` structs. It opens every `/dev/input/eventX` whose `EV_KEY` caps include any configured code, polls all their fds together, and drains whichever are ready. Suppression (`EVIOCGRAB` + uinput passthrough) is applied **only to mouse devices** (caps include `BTN_LEFT`); keyboard-trigger devices are read but never grabbed. Hotplug drops a dead device and rescans when the set empties.

**Tech Stack:** Zig `0.17.0-dev.305` (raw `std.os.linux` syscalls; `std.posix.open/close/write` absent — use `lx.*`), evdev/uinput.

---

### Task 1: Richer `--buttons` parser (aliases + raw codes)

**Files:**
- Modify: `src/cli.zig`

- [ ] **Step 1: Write the failing tests** — append to `src/cli.zig`:

```zig
test "buttons: aliases and raw codes" {
    const t = std.testing;
    {
        const args = [_][:0]const u8{ "zclicker", "-b", "left,right" };
        const cfg = try parse(&args);
        try t.expectEqual(@as(usize, 2), cfg.button_count);
        try t.expectEqual(lx.BTN_LEFT, cfg.buttons[0]);
        try t.expectEqual(lx.BTN_RIGHT, cfg.buttons[1]);
    }
    {
        const args = [_][:0]const u8{ "zclicker", "-b", "183" }; // KEY_F13
        const cfg = try parse(&args);
        try t.expectEqual(@as(usize, 1), cfg.button_count);
        try t.expectEqual(@as(u16, 183), cfg.buttons[0]);
    }
    {
        const args = [_][:0]const u8{ "zclicker", "-b", "4,extra,middle" };
        const cfg = try parse(&args);
        try t.expectEqual(@as(usize, 3), cfg.button_count);
        try t.expectEqual(lx.BTN_SIDE, cfg.buttons[0]);
        try t.expectEqual(lx.BTN_EXTRA, cfg.buttons[1]);
        try t.expectEqual(lx.BTN_MIDDLE, cfg.buttons[2]);
    }
}

test "buttons: invalid token errors" {
    const t = std.testing;
    const args = [_][:0]const u8{ "zclicker", "-b", "wat" };
    try t.expectError(Error.InvalidButton, parse(&args));
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ~/Documentos/Projetos-Pessoais/zclicker && zig build test`
Expected: FAIL — `lx` not imported in cli.zig; `left`/`183` not accepted.

- [ ] **Step 3: Implement** — in `src/cli.zig`:

Add the import near the top (next to `const backend = @import("backend.zig");`):
```zig
const lx = @import("platform/linux.zig");
```
Replace the existing `buttonCode` with:
```zig
/// Map a trigger token to an evdev code. Accepts named aliases (mouse buttons) or a
/// raw decimal evdev code (covers keyboard keys, e.g. 183 = KEY_F13).
fn buttonCode(name: []const u8) ?u16 {
    if (eq(name, "left")) return lx.BTN_LEFT;
    if (eq(name, "right")) return lx.BTN_RIGHT;
    if (eq(name, "middle")) return lx.BTN_MIDDLE;
    if (eq(name, "4") or eq(name, "side")) return lx.BTN_SIDE;
    if (eq(name, "5") or eq(name, "extra")) return lx.BTN_EXTRA;
    if (eq(name, "forward")) return lx.BTN_FORWARD;
    if (eq(name, "back")) return lx.BTN_BACK;
    if (eq(name, "task")) return lx.BTN_TASK;
    return std.fmt.parseInt(u16, name, 10) catch null;
}
```
(The existing `parseButtons` already calls `buttonCode` per comma-separated token and returns `Error.InvalidButton` on `null`; leave it as-is.)

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/cli.zig
git commit -m "feat(cli): --buttons accepts aliases and raw evdev codes"
```
(No Co-Authored-By trailer.)

---

### Task 2: Rewrite `evdev.zig` for multi-device

**Files:**
- Modify (full replace): `src/input/evdev.zig`

This is a structural rewrite. There is no unit test for hardware I/O; the gate is `zig build test` staying green (cli/core/select/backend/platform tests) and a clean `zig build`. Correctness of the device logic is by inspection + the manual smoke test in Task 3.

- [ ] **Step 1: Replace `src/input/evdev.zig` entirely with:**

```zig
const std = @import("std");
const backend = @import("../backend.zig");
const lx = @import("../platform/linux.zig");

const InputBackend = backend.InputBackend;
const TriggerEvent = backend.TriggerEvent;

const MAX_EVENT_NODES: usize = 64;
const MAX_DEVICES: usize = 16;

/// EVIOCGRAB: grab/release exclusive access. arg 1 grabs, 0 releases.
const EVIOCGRAB = lx.iow('E', 0x90, @sizeOf(c_int));
fn eviocgbit(ev: u32, len: u32) u32 {
    return lx.ior('E', 0x20 + ev, len);
}
fn eviocgname(len: u32) u32 {
    return lx.ior('E', 0x06, len);
}

/// One opened input device that holds at least one configured trigger code.
const Device = struct {
    fd: std.posix.fd_t,
    name_buf: [256]u8 = undefined,
    name_len: usize = 0,
    is_mouse: bool = false,
    grabbed: bool = false,
    passthrough_fd: std.posix.fd_t = -1,

    fn name(self: *const Device) []const u8 {
        if (self.name_len == 0) return "(desconhecido)";
        return self.name_buf[0..self.name_len];
    }

    fn close(self: *Device) void {
        if (self.grabbed and self.fd >= 0) {
            _ = std.os.linux.ioctl(self.fd, EVIOCGRAB, 0);
            self.grabbed = false;
        }
        if (self.passthrough_fd >= 0) {
            lx.destroyUinputDevice(self.passthrough_fd);
            lx.closeFd(self.passthrough_fd);
            self.passthrough_fd = -1;
        }
        if (self.fd >= 0) {
            lx.closeFd(self.fd);
            self.fd = -1;
        }
    }
};

/// Linux input backend. Reads button/key events from every `/dev/input/eventX` that
/// holds a configured trigger code, so triggers can be mouse buttons or keyboard keys.
/// Suppression (`EVIOCGRAB` + uinput passthrough) is applied only to mouse devices.
pub const LinuxEvdev = struct {
    devices: [MAX_DEVICES]Device = undefined,
    device_count: usize = 0,
    pending: [64]TriggerEvent = undefined,
    pending_len: usize = 0,
    pending_idx: usize = 0,
    codes: []const u16,
    suppress: bool,

    pub fn init(device: ?[]const u8, codes: []const u16, suppress: bool) !LinuxEvdev {
        var self = LinuxEvdev{ .codes = codes, .suppress = suppress };
        errdefer self.deinit();
        if (device) |path| {
            var zbuf: [256]u8 = undefined;
            const pz = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{path}, 0) catch return error.OpenFailed;
            const fd = try lx.openRdonlyNonblock(pz);
            try self.addDevice(fd);
        } else {
            self.scanDevices();
        }
        if (self.device_count == 0) return error.NoDeviceFound;
        return self;
    }

    pub fn deinit(self: *LinuxEvdev) void {
        var i: usize = 0;
        while (i < self.device_count) : (i += 1) self.devices[i].close();
        self.device_count = 0;
    }

    pub fn interface(self: *LinuxEvdev) InputBackend {
        return .{ .ptr = self, .caps = .{ .can_suppress = true }, .nextEventFn = nextEventImpl };
    }

    /// Name of the first device (for the banner).
    pub fn deviceName(self: *const LinuxEvdev) []const u8 {
        if (self.device_count == 0) return "(nenhum)";
        return self.devices[0].name();
    }

    pub fn deviceCount(self: *const LinuxEvdev) usize {
        return self.device_count;
    }

    /// Open every event node whose key caps include any configured code.
    fn scanDevices(self: *LinuxEvdev) void {
        var n: usize = 0;
        while (n < MAX_EVENT_NODES and self.device_count < MAX_DEVICES) : (n += 1) {
            var pathbuf: [32]u8 = undefined;
            const path = std.fmt.bufPrintSentinel(&pathbuf, "/dev/input/event{d}", .{n}, 0) catch continue;
            const fd = lx.openRdonlyNonblock(path) catch continue;
            if (deviceHasAnyCode(fd, self.codes)) {
                self.addDevice(fd) catch lx.closeFd(fd);
            } else {
                lx.closeFd(fd);
            }
        }
    }

    /// Take ownership of an open fd: record name, detect mouse-ness, and (when
    /// suppressing a mouse) grab it and create a passthrough.
    fn addDevice(self: *LinuxEvdev, fd: std.posix.fd_t) !void {
        if (self.device_count >= MAX_DEVICES) {
            lx.closeFd(fd);
            return;
        }
        var dev = Device{ .fd = fd };
        dev.name_len = nameInto(fd, &dev.name_buf);
        dev.is_mouse = deviceIsMouse(fd);
        if (self.suppress and dev.is_mouse) {
            if (@as(isize, @bitCast(std.os.linux.ioctl(fd, EVIOCGRAB, 1))) < 0) return error.GrabFailed;
            dev.grabbed = true;
            errdefer {
                _ = std.os.linux.ioctl(fd, EVIOCGRAB, 0);
                dev.grabbed = false;
            }
            dev.passthrough_fd = try lx.createUinputDevice(
                "zclicker-passthrough",
                &.{ lx.BTN_LEFT, lx.BTN_RIGHT, lx.BTN_MIDDLE, lx.BTN_SIDE, lx.BTN_EXTRA, lx.BTN_FORWARD, lx.BTN_BACK, lx.BTN_TASK },
                &.{ lx.REL_X, lx.REL_Y, lx.REL_WHEEL, lx.REL_HWHEEL, lx.REL_WHEEL_HI_RES, lx.REL_HWHEEL_HI_RES },
            );
        }
        self.devices[self.device_count] = dev;
        self.device_count += 1;
    }

    fn nextEventImpl(ptr: *anyopaque, timeout_ms: i32) anyerror!?TriggerEvent {
        const self: *LinuxEvdev = @ptrCast(@alignCast(ptr));
        return self.nextEvent(timeout_ms);
    }

    fn nextEvent(self: *LinuxEvdev, timeout_ms: i32) !?TriggerEvent {
        if (self.popPending()) |ev| return ev;

        const deadline: ?i64 = if (timeout_ms < 0) null else lx.monoMillis() + timeout_ms;
        while (true) {
            if (self.device_count == 0) self.rescan();

            var remaining: i32 = -1;
            if (deadline) |d| {
                const now = lx.monoMillis();
                if (now >= d) return null;
                remaining = @intCast(d - now);
            }

            var fds: [MAX_DEVICES]std.posix.pollfd = undefined;
            var i: usize = 0;
            while (i < self.device_count) : (i += 1) {
                fds[i] = .{ .fd = self.devices[i].fd, .events = std.posix.POLL.IN, .revents = 0 };
            }
            const n = try std.posix.poll(fds[0..self.device_count], remaining);
            if (n == 0) return null; // timed out

            // Fresh batch for this poll round (pending is empty here — see popPending guard above).
            self.pending_len = 0;
            self.pending_idx = 0;

            const err_mask: i16 = std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL;
            var lost = false;
            i = 0;
            while (i < self.device_count) : (i += 1) {
                const re: i16 = fds[i].revents;
                if ((re & err_mask) != 0) {
                    self.devices[i].close();
                    lost = true;
                    continue;
                }
                if ((re & @as(i16, std.posix.POLL.IN)) != 0) {
                    self.fillFrom(&self.devices[i]) catch {
                        self.devices[i].close();
                        lost = true;
                    };
                }
            }
            if (lost) self.compactDevices();
            if (self.popPending()) |ev| return ev;
            // Only non-trigger events arrived; loop and keep waiting.
        }
    }

    fn popPending(self: *LinuxEvdev) ?TriggerEvent {
        if (self.pending_idx >= self.pending_len) return null;
        const ev = self.pending[self.pending_idx];
        self.pending_idx += 1;
        return ev;
    }

    /// Read one batch from a device, queueing configured trigger presses/releases and
    /// re-injecting everything else through the device's passthrough when suppressing.
    fn fillFrom(self: *LinuxEvdev, dev: *Device) !void {
        var buf: [64]lx.InputEvent = undefined;
        const bytes = std.posix.read(dev.fd, std.mem.sliceAsBytes(buf[0..])) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
        const count = bytes / @sizeOf(lx.InputEvent);
        for (buf[0..count]) |ev| {
            const is_trigger = ev.type == lx.EV_KEY and codeInList(self.codes, ev.code) and (ev.value == 0 or ev.value == 1);
            if (is_trigger) {
                if (self.pending_len >= self.pending.len) continue;
                self.pending[self.pending_len] = .{ .button = ev.code, .pressed = ev.value == 1 };
                self.pending_len += 1;
            } else if (dev.passthrough_fd >= 0 and ev.type != lx.EV_MSC) {
                // Re-inject non-trigger events so the grabbed mouse keeps working.
                // EV_MSC (MSC_SCAN) dropped to avoid leaking a scancode for a suppressed button.
                lx.writeEvent(dev.passthrough_fd, ev.type, ev.code, ev.value) catch {};
            }
        }
    }

    /// Drop devices whose fd was closed (fd < 0), preserving order.
    fn compactDevices(self: *LinuxEvdev) void {
        var w: usize = 0;
        var r: usize = 0;
        while (r < self.device_count) : (r += 1) {
            if (self.devices[r].fd >= 0) {
                if (w != r) self.devices[w] = self.devices[r];
                w += 1;
            }
        }
        self.device_count = w;
    }

    /// All devices gone (unplugged). Block-retry the scan until at least one returns.
    fn rescan(self: *LinuxEvdev) void {
        std.debug.print("[zclicker] dispositivos de gatilho sumiram; aguardando...\n", .{});
        while (self.device_count == 0) {
            self.scanDevices();
            if (self.device_count > 0) {
                std.debug.print("[zclicker] reconectado ({d} dispositivo(s))\n", .{self.device_count});
                return;
            }
            var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 500 * std.time.ns_per_ms };
            _ = std.os.linux.nanosleep(&ts, null);
        }
    }

    /// Print every device that holds any of the requested trigger codes.
    pub fn listDevices(codes: []const u16) !void {
        var found = false;
        var n: usize = 0;
        while (n < MAX_EVENT_NODES) : (n += 1) {
            var pathbuf: [32]u8 = undefined;
            const path = std.fmt.bufPrintSentinel(&pathbuf, "/dev/input/event{d}", .{n}, 0) catch continue;
            const fd = lx.openRdonlyNonblock(path) catch continue;
            defer lx.closeFd(fd);
            if (!deviceHasAnyCode(fd, codes)) continue;
            var namebuf: [256]u8 = undefined;
            const nm = nameInto(fd, &namebuf);
            const name: []const u8 = if (nm == 0) "(desconhecido)" else namebuf[0..nm];
            const kind: []const u8 = if (deviceIsMouse(fd)) "mouse" else "outro";
            std.debug.print("{s}\t{s}\t[{s}]\n", .{ path, name, kind });
            found = true;
        }
        if (!found) std.debug.print("nenhum dispositivo com os códigos pedidos.\n", .{});
    }
};

fn deviceHasAnyCode(fd: std.posix.fd_t, codes: []const u16) bool {
    var keybits: [lx.KEY_MAX / 8 + 1]u8 = @splat(0);
    const rc = std.os.linux.ioctl(fd, eviocgbit(lx.EV_KEY, keybits.len), @intFromPtr(&keybits));
    if (@as(isize, @bitCast(rc)) < 0) return false;
    for (codes) |c| {
        if (@as(usize, c) / 8 < keybits.len and lx.testBit(&keybits, c)) return true;
    }
    return false;
}

fn deviceIsMouse(fd: std.posix.fd_t) bool {
    var keybits: [lx.KEY_MAX / 8 + 1]u8 = @splat(0);
    const rc = std.os.linux.ioctl(fd, eviocgbit(lx.EV_KEY, keybits.len), @intFromPtr(&keybits));
    if (@as(isize, @bitCast(rc)) < 0) return false;
    return lx.testBit(&keybits, lx.BTN_LEFT); // BTN_LEFT marks a pointer device
}

fn codeInList(codes: []const u16, code: u16) bool {
    for (codes) |c| if (c == code) return true;
    return false;
}

/// Query a device's name via EVIOCGNAME. Returns length written to `buf`.
fn nameInto(fd: std.posix.fd_t, buf: []u8) usize {
    const rc = std.os.linux.ioctl(fd, eviocgname(@intCast(buf.len)), @intFromPtr(buf.ptr));
    const n = @as(isize, @bitCast(rc));
    if (n <= 0) return 0;
    var len: usize = @intCast(n);
    if (len > 0 and buf[len - 1] == 0) len -= 1;
    return len;
}
```

- [ ] **Step 2: Build + test**

Run: `zig build && zig build test`
Expected: PASS. Fix any compiler drift against `/usr/lib/zig/std` (e.g. `pollfd.revents` int width — the `i16` casts mirror the existing code). Note `main.zig` still compiles because the public API (`init(device,codes,suppress)`, `deinit`, `interface`, `deviceName`, `listDevices`) is unchanged.

- [ ] **Step 3: Commit**

```bash
git add src/input/evdev.zig
git commit -m "feat(input): multi-device evdev (mouse + keyboard triggers)"
```

---

### Task 3: Banner + help + smoke

**Files:**
- Modify: `src/main.zig`

- [ ] **Step 1: Show device count in the banner.** In `src/main.zig`, where the startup banner is printed, append the device count. Replace the `evdev.deviceName()` argument usage so the banner reads e.g. `... {s} (+{d} disp.) ...`:
```zig
    std.debug.print(
        "zclicker: {s} ({d} disp.) | {d}ms | {s} | clica={s} | in={s} out={s}{s} | Ctrl+C\n",
        .{ evdev.deviceName(), evdev.deviceCount(), cfg.interval_ms, @tagName(cfg.mode), @tagName(cfg.click),
           @tagName(choice.input), @tagName(choice.output), if (cfg.suppress) " | suppress" else "" },
    );
```
(Adapt to the exact current banner format string; the key change is adding `evdev.deviceCount()`.)

- [ ] **Step 2: Update `-b` and `--list` help text** in `printUsage` to mention codes/keys:
```zig
        \\  -b, --buttons <lista>  gatilhos: nomes (left,right,middle,4,5,forward,back) ou códigos evdev, ex: 4,5 ou left,183
```

- [ ] **Step 3: Build, test, smoke-check `--list`/`--help`**

Run: `zig build && zig build test`
Expected: PASS.
Run: `./zig-out/bin/zclicker --list` → now prints each device with a `[mouse]`/`[outro]` tag.
Run: `./zig-out/bin/zclicker -b 4,5 --help` (help is safe). Do NOT run with no args.

- [ ] **Step 4: Commit**

```bash
git add src/main.zig
git commit -m "feat: banner shows device count; --buttons help mentions codes/keys"
```

---

## Self-Review

**Spec coverage (SP2 section of the design):**
- `--buttons` aliases + raw codes → Task 1 ✓.
- Engine opens/polls every device with any trigger code → Task 2 `scanDevices`/`deviceHasAnyCode`/multi-fd poll ✓.
- Suppression mouse-only → Task 2 `addDevice` grabs only when `dev.is_mouse`; `fillFrom` re-injects only when `dev.passthrough_fd >= 0` ✓.
- Hotplug + cleanup over the set → Task 2 `compactDevices`/`rescan`/`Device.close`; `deinit` closes all ✓. Signal handler already calls `evdev.deinit()` (unchanged) → covers the set.
- Keyboard triggers not suppressible → keyboard devices have no passthrough, so `fillFrom` never re-injects/grabs them ✓ (documented).

**Placeholder scan:** none; full file content + complete code in every step. Task 3 Step 1 says "adapt to the exact current banner format" — the engineer has the file; the concrete new format string is provided.

**Type consistency:** public API of `LinuxEvdev` unchanged (`init`/`deinit`/`interface`/`deviceName`/`listDevices`), so `main.zig` and the signal handler keep compiling; the only additions are `deviceCount()` (used in Task 3) and internal `Device`. `cli.zig` gains `const lx` import used by `buttonCode` (Task 1) and the new tests. `error.NoDeviceFound`/`GrabFailed`/`OpenFailed` still surface to main's existing error switch.
