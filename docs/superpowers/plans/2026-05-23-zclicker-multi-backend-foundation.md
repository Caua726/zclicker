# zclicker Multi-Backend Foundation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn zclicker's two hard-wired backends (evdev input, ydotool output) into a pluggable, auto-selecting backend system, add a native uinput output backend, and add navigation suppression (evdev grab + re-injection) — plus signal cleanup and device hotplug.

**Architecture:** Two runtime interfaces (`InputBackend`, `OutputBackend`) each carrying a `Capabilities` value. A pure `select` module reads the environment (OS, session type, available mechanisms) and resolves an input+output pair with a fallback chain, overridable by `--input`/`--output`. Linux ioctl/struct/clock plumbing is extracted into one `platform/linux.zig`. Suppression is an evdev-input capability: when enabled it grabs the device and re-injects every non-trigger event through a private uinput passthrough device. The single-threaded poll loop in `core.zig` is unchanged.

**Tech Stack:** Zig `0.17.0-dev.305+bdfbf432d` (new `Io` interface std), Linux evdev/uinput via raw ioctls, `ydotool` (fallback output).

---

## Scope

**In this plan:** abstraction + capabilities, `select` (auto-detect + override + fallback), native **uinput** output, **suppression** (evdev grab + re-inject), signal cleanup, hotplug reopen, refactor of existing evdev/ydotool into the new shape.

**Follow-up plans (each plugs into the same interfaces, no core changes):**
- `wlr-virtual-pointer` output (wlroots/Hyprland, needs Wayland protocol bindings)
- X11 backend (XInput2 input + XTest output, needs xcb/xlib)
- libei + RemoteDesktop/InputCapture portals (GNOME/KDE, sandbox)
- `hidraw` input (exotic buttons)
- Windows (`WH_MOUSE_LL` input + `SendInput` output) + cross-compile
- compositor-IPC input (Hyprland `bind`)

## File Structure (after this plan)

```
src/
  main.zig              entry: parse args -> select backends -> run loop + install cleanup
  cli.zig               args incl. --input/--output/--suppress/--list-backends
  core.zig              Triggers + run loop (unchanged)
  backend.zig           InputBackend + OutputBackend interfaces + Capabilities + BackendId
  select.zig            Env detection + selection/fallback (pure, testable)
  platform/
    linux.zig           _IOC helpers, InputEvent, monoMillis, open/close, EV_*/BTN_* consts
  input/
    evdev.zig           evdev input backend (was input/linux_evdev.zig); optional grab+re-inject
  output/
    uinput.zig          NEW native uinput output backend
    ydotool.zig         existing output backend (now a fallback)
  root.zig              library surface (re-exports + test refs)
```

Deleted: `src/input/input.zig`, `src/output/output.zig` (folded into `backend.zig`), `src/input/linux_evdev.zig` (renamed to `src/input/evdev.zig`).

---

### Task 1: Extract shared Linux platform helpers

Pull the `_IOC` helpers, `InputEvent`, monotonic clock, and open/close out of the evdev file into one module both evdev and uinput will use. Anchor it with tests against known kernel ioctl constants.

**Files:**
- Create: `src/platform/linux.zig`
- Test: tests live inside `src/platform/linux.zig`

- [ ] **Step 1: Write the failing test**

Create `src/platform/linux.zig` with only the helpers + tests:

```zig
const std = @import("std");

pub const EV_SYN: u16 = 0x00;
pub const EV_KEY: u16 = 0x01;
pub const EV_REL: u16 = 0x02;
pub const SYN_REPORT: u16 = 0x00;

pub const BTN_LEFT: u16 = 0x110;
pub const BTN_SIDE: u16 = 0x113;
pub const BTN_EXTRA: u16 = 0x114;

pub const KEY_MAX: usize = 0x2ff;

/// evdev `struct input_event` on 64-bit Linux (sizeof == 24).
pub const InputEvent = extern struct {
    sec: isize,
    usec: isize,
    type: u16,
    code: u16,
    value: i32,
};

// _IOC direction bits
pub const IOC_NONE: u32 = 0;
pub const IOC_WRITE: u32 = 1;
pub const IOC_READ: u32 = 2;

pub fn ioc(dir: u32, typ: u32, nr: u32, size: u32) u32 {
    return (dir << 30) | (size << 16) | (typ << 8) | nr;
}
pub fn io(typ: u32, nr: u32) u32 {
    return ioc(IOC_NONE, typ, nr, 0);
}
pub fn iow(typ: u32, nr: u32, size: u32) u32 {
    return ioc(IOC_WRITE, typ, nr, size);
}
pub fn ior(typ: u32, nr: u32, size: u32) u32 {
    return ioc(IOC_READ, typ, nr, size);
}

test "ioc encodes known uinput ioctl numbers" {
    const t = std.testing;
    // UI_DEV_CREATE  == _IO('U', 1)              == 0x5501
    try t.expectEqual(@as(u32, 0x5501), io('U', 1));
    // UI_DEV_DESTROY == _IO('U', 2)              == 0x5502
    try t.expectEqual(@as(u32, 0x5502), io('U', 2));
    // UI_SET_EVBIT   == _IOW('U', 100, int)      == 0x40045564
    try t.expectEqual(@as(u32, 0x40045564), iow('U', 100, 4));
}
```

- [ ] **Step 2: Run test to verify it fails (module not yet wired into test run)**

Run: `zig build test` after adding `_ = @import("platform/linux.zig");` to `src/root.zig`'s `test {}` block (do that now).
Expected: compiles and the three `expectEqual` pass. If any constant is wrong, the test fails with the mismatched hex — fix `ioc`.

- [ ] **Step 3: Add the clock + open/close helpers (no test; verified by use later)**

Append to `src/platform/linux.zig`:

```zig
/// Monotonic milliseconds, independent of the Io interface.
pub fn monoMillis() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), std.time.ns_per_ms);
}

pub const OpenError = error{ AccessDenied, FileNotFound, OpenFailed };

/// Open a path read-only/non-blocking via the raw Linux `open` syscall
/// (std.posix.open does not exist in this std; a raw fd is what poll/read/ioctl want).
pub fn openRdonlyNonblock(path: [:0]const u8) OpenError!std.posix.fd_t {
    const rc = std.os.linux.open(path.ptr, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0);
    return decodeOpen(rc);
}

/// Open a path read-write via the raw Linux `open` syscall (for /dev/uinput).
pub fn openRdwr(path: [:0]const u8) OpenError!std.posix.fd_t {
    const rc = std.os.linux.open(path.ptr, .{ .ACCMODE = .RDWR }, 0);
    return decodeOpen(rc);
}

fn decodeOpen(rc: usize) OpenError!std.posix.fd_t {
    const signed = @as(isize, @bitCast(rc));
    if (signed >= 0) return @intCast(signed);
    const e: std.os.linux.E = @enumFromInt(@as(u16, @intCast(-signed)));
    return switch (e) {
        .ACCES, .PERM => error.AccessDenied,
        .NOENT, .NXIO, .NODEV => error.FileNotFound,
        else => error.OpenFailed,
    };
}

pub fn closeFd(fd: std.posix.fd_t) void {
    _ = std.os.linux.close(fd);
}

pub fn testBit(bits: []const u8, n: usize) bool {
    return (bits[n / 8] & (@as(u8, 1) << @intCast(n % 8))) != 0;
}
```

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/platform/linux.zig src/root.zig
git commit -m "refactor: extract shared Linux platform helpers with ioctl tests"
```

---

### Task 2: Unify interfaces and add Capabilities

Collapse `input/input.zig` + `output/output.zig` into one `backend.zig` that also declares a `Capabilities` struct and a `BackendId` enum. Update existing evdev/ydotool imports.

**Files:**
- Create: `src/backend.zig`
- Modify: `src/input/linux_evdev.zig` (imports), `src/output/ydotool.zig` (imports), `src/core.zig` (imports), `src/root.zig`
- Delete: `src/input/input.zig`, `src/output/output.zig`

- [ ] **Step 1: Write `src/backend.zig`**

```zig
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
    uinput,
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
```

- [ ] **Step 2: Repoint existing modules**

In `src/core.zig`: replace `const input = @import("input/input.zig");` and `const output = @import("output/output.zig");` with `const backend = @import("backend.zig");`, and replace `input.TriggerEvent`→`backend.TriggerEvent`, `input.InputBackend`→`backend.InputBackend`, `output.OutputBackend`→`backend.OutputBackend`, `input.BTN_SIDE`/`input.BTN_EXTRA` (in tests)→`backend.BTN_SIDE`/`backend.BTN_EXTRA`.

In `src/input/linux_evdev.zig`: replace `const iface = @import("input.zig");` with `const backend = @import("../backend.zig");` and `const lx = @import("../platform/linux.zig");`; replace `iface.InputBackend`→`backend.InputBackend`, `iface.TriggerEvent`→`backend.TriggerEvent`. Add `.caps = .{ .can_suppress = false }` to the `InputBackend{...}` it returns in `backend()` (rename that method to `interface()` to avoid colliding with the imported `backend` name).

In `src/output/ydotool.zig`: replace `@import("output.zig")` with `@import("../backend.zig")`; rename its `backend()` method to `interface()`.

In `src/cli.zig`: replace `@import("input/input.zig")` with `@import("backend.zig")`, `input.BTN_SIDE`→`backend.BTN_SIDE`, etc.

In `src/root.zig`: replace the `input`/`output` re-exports with `pub const backend = @import("backend.zig");` and update `LinuxEvdev`/`Ydotool` paths if renamed (kept for now).

- [ ] **Step 3: Delete the old interface files**

```bash
git rm src/input/input.zig src/output/output.zig
```

- [ ] **Step 4: Build + test**

Run: `zig build && zig build test`
Expected: PASS. Fix any leftover `iface.`/`input.`/`output.` references the compiler points at.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: unify backend interfaces into backend.zig with Capabilities"
```

---

### Task 3: CLI flags for backend selection

Add `--input`, `--output`, `--suppress`, `--list-backends` to the parser.

**Files:**
- Modify: `src/cli.zig`

- [ ] **Step 1: Write the failing tests**

Add to `src/cli.zig` (and add the fields below to `Config` first or the tests won't compile):

```zig
test "input/output/suppress flags parse" {
    const t = std.testing;
    const backend = @import("backend.zig");
    const args = [_][:0]const u8{ "zclicker", "--input", "evdev", "--output", "uinput", "--suppress" };
    const cfg = try parse(&args);
    try t.expectEqual(backend.BackendId.evdev, cfg.input.?);
    try t.expectEqual(backend.BackendId.uinput, cfg.output.?);
    try t.expect(cfg.suppress);
}

test "unknown backend errors" {
    const t = std.testing;
    const args = [_][:0]const u8{ "zclicker", "--output", "nope" };
    try t.expectError(Error.UnknownBackend, parse(&args));
}

test "list-backends flag" {
    const t = std.testing;
    const args = [_][:0]const u8{ "zclicker", "--list-backends" };
    const cfg = try parse(&args);
    try t.expect(cfg.list_backends);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test`
Expected: FAIL (no `cfg.input`, `Error.UnknownBackend`, etc.).

- [ ] **Step 3: Implement**

In `src/cli.zig`, add to `Config`:

```zig
    input: ?@import("backend.zig").BackendId = null,
    output: ?@import("backend.zig").BackendId = null,
    suppress: bool = false,
    list_backends: bool = false,
```

Add to `Error`: `UnknownBackend`. In `parse`, add branches before the final `else`:

```zig
        } else if (eq(a, "--input")) {
            i += 1;
            if (i >= args.len) return Error.MissingValue;
            cfg.input = @import("backend.zig").BackendId.parse(args[i]) orelse return Error.UnknownBackend;
        } else if (eq(a, "--output")) {
            i += 1;
            if (i >= args.len) return Error.MissingValue;
            cfg.output = @import("backend.zig").BackendId.parse(args[i]) orelse return Error.UnknownBackend;
        } else if (eq(a, "--suppress")) {
            cfg.suppress = true;
        } else if (eq(a, "--list-backends")) {
            cfg.list_backends = true;
```

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/cli.zig
git commit -m "feat(cli): --input/--output/--suppress/--list-backends flags"
```

---

### Task 4: Environment detection + selection logic

Pure resolver: from an `Env` value, pick input+output `BackendId`s honoring overrides and a `--suppress` request, with fallback. No I/O — fully unit-tested.

**Files:**
- Create: `src/select.zig`
- Test: inside `src/select.zig`; add `_ = @import("select.zig");` to `root.zig` test block.

- [ ] **Step 1: Write the failing tests**

```zig
const std = @import("std");
const backend = @import("backend.zig");
const Id = backend.BackendId;

pub const Session = enum { wayland, x11, unknown };

/// Snapshot of the environment relevant to backend choice. Filled by `probe`
/// in main; constructed directly in tests.
pub const Env = struct {
    session: Session = .unknown,
    has_uinput: bool = false, // /dev/uinput writable
    has_ydotoold: bool = false, // ydotool socket present
};

pub const Choice = struct {
    input: Id,
    output: Id,
};

pub const SelectError = error{ NoOutputAvailable, SuppressUnavailable };

pub const Request = struct {
    input: ?Id = null,
    output: ?Id = null,
    suppress: bool = false,
};

/// Resolve a concrete input+output pair. Input is always evdev on Linux for now
/// (only backend that reads buttons). Output prefers uinput, falls back to ydotool.
pub fn resolve(env: Env, req: Request) SelectError!Choice {
    const input: Id = req.input orelse .evdev;
    // Suppression is an evdev capability; only evdev can honor it today.
    if (req.suppress and input != .evdev) return error.SuppressUnavailable;

    const output: Id = req.output orelse blk: {
        if (env.has_uinput) break :blk .uinput;
        if (env.has_ydotoold) break :blk .ydotool;
        break :blk .uinput; // optimistic default; open will surface the real error
    };
    if (output == .ydotool and !env.has_ydotoold and req.output != null) {
        // explicit ydotool but no daemon: still allow; click() will error clearly
    }
    return .{ .input = input, .output = output };
}

test "default prefers uinput when available" {
    const t = std.testing;
    const c = try resolve(.{ .has_uinput = true, .has_ydotoold = true }, .{});
    try t.expectEqual(Id.evdev, c.input);
    try t.expectEqual(Id.uinput, c.output);
}

test "falls back to ydotool without uinput" {
    const t = std.testing;
    const c = try resolve(.{ .has_uinput = false, .has_ydotoold = true }, .{});
    try t.expectEqual(Id.ydotool, c.output);
}

test "explicit output override wins" {
    const t = std.testing;
    const c = try resolve(.{ .has_uinput = true }, .{ .output = .ydotool });
    try t.expectEqual(Id.ydotool, c.output);
}

test "suppress with non-evdev input is rejected" {
    const t = std.testing;
    try t.expectError(error.SuppressUnavailable, resolve(.{}, .{ .input = .uinput, .suppress = true }));
}
```

- [ ] **Step 2: Run to verify it fails, then passes**

Run: `zig build test`
Expected: after adding the file + the `root.zig` test import, the four tests PASS.

- [ ] **Step 3: Commit**

```bash
git add src/select.zig src/root.zig
git commit -m "feat: pure backend selection/fallback resolver with tests"
```

---

### Task 5: Native uinput output backend

Create a virtual mouse via `/dev/uinput` and emit a left click without ydotool.

**Files:**
- Create: `src/output/uinput.zig`
- Modify: `src/root.zig` (export `Uinput`)

- [ ] **Step 1: Implement `src/output/uinput.zig`**

```zig
const std = @import("std");
const lx = @import("../platform/linux.zig");
const backend = @import("../backend.zig");

const UINPUT_MAX_NAME_SIZE = 80;

// uinput ioctls
fn UI_SET_EVBIT() u32 {
    return lx.iow('U', 100, @sizeOf(c_int));
}
fn UI_SET_KEYBIT() u32 {
    return lx.iow('U', 101, @sizeOf(c_int));
}
fn UI_SET_RELBIT() u32 {
    return lx.iow('U', 102, @sizeOf(c_int));
}
fn UI_DEV_SETUP() u32 {
    return lx.iow('U', 3, @sizeOf(UinputSetup));
}
fn UI_DEV_CREATE() u32 {
    return lx.io('U', 1);
}
fn UI_DEV_DESTROY() u32 {
    return lx.io('U', 2);
}

const InputId = extern struct {
    bustype: u16,
    vendor: u16,
    product: u16,
    version: u16,
};
const UinputSetup = extern struct {
    id: InputId,
    name: [UINPUT_MAX_NAME_SIZE]u8,
    ff_effects_max: u32,
};

const BUS_VIRTUAL: u16 = 0x06;

/// Output backend that creates a virtual mouse and clicks left via uinput.
/// No daemon, lower latency than ydotool. Needs /dev/uinput writable
/// (root or a udev rule granting your user/group rw).
pub const Uinput = struct {
    fd: std.posix.fd_t,

    pub fn init() !Uinput {
        const fd = try lx.openRdwr("/dev/uinput");
        errdefer lx.closeFd(fd);

        try ioctlInt(fd, UI_SET_EVBIT(), lx.EV_KEY);
        try ioctlInt(fd, UI_SET_KEYBIT(), lx.BTN_LEFT);
        // a relative axis keeps the device classified as a mouse
        try ioctlInt(fd, UI_SET_EVBIT(), lx.EV_REL);
        try ioctlInt(fd, UI_SET_RELBIT(), 0x00); // REL_X

        var setup = std.mem.zeroes(UinputSetup);
        setup.id = .{ .bustype = BUS_VIRTUAL, .vendor = 0x1234, .product = 0x5678, .version = 1 };
        const name = "zclicker-virtual-mouse";
        @memcpy(setup.name[0..name.len], name);
        try ioctlPtr(fd, UI_DEV_SETUP(), @intFromPtr(&setup));
        try ioctlNone(fd, UI_DEV_CREATE());

        // Give udev a moment to create the node before first write.
        std.Thread.sleep(50 * std.time.ns_per_ms);
        return .{ .fd = fd };
    }

    pub fn deinit(self: *Uinput) void {
        _ = std.os.linux.ioctl(self.fd, UI_DEV_DESTROY(), 0);
        lx.closeFd(self.fd);
    }

    pub fn interface(self: *Uinput) backend.OutputBackend {
        return .{ .ptr = self, .clickFn = clickImpl };
    }

    fn clickImpl(ptr: *anyopaque) anyerror!void {
        const self: *Uinput = @ptrCast(@alignCast(ptr));
        try self.emit(lx.EV_KEY, lx.BTN_LEFT, 1);
        try self.emit(lx.EV_SYN, lx.SYN_REPORT, 0);
        try self.emit(lx.EV_KEY, lx.BTN_LEFT, 0);
        try self.emit(lx.EV_SYN, lx.SYN_REPORT, 0);
    }

    fn emit(self: *Uinput, typ: u16, code: u16, value: i32) !void {
        const ev = lx.InputEvent{ .sec = 0, .usec = 0, .type = typ, .code = code, .value = value };
        const bytes = std.mem.asBytes(&ev);
        var written: usize = 0;
        while (written < bytes.len) {
            written += try std.posix.write(self.fd, bytes[written..]);
        }
    }
};

fn ioctlInt(fd: std.posix.fd_t, req: u32, arg: u32) !void {
    if (@as(isize, @bitCast(std.os.linux.ioctl(fd, req, arg))) < 0) return error.IoctlFailed;
}
fn ioctlPtr(fd: std.posix.fd_t, req: u32, arg: usize) !void {
    if (@as(isize, @bitCast(std.os.linux.ioctl(fd, req, arg))) < 0) return error.IoctlFailed;
}
fn ioctlNone(fd: std.posix.fd_t, req: u32) !void {
    if (@as(isize, @bitCast(std.os.linux.ioctl(fd, req, 0))) < 0) return error.IoctlFailed;
}
```

> Note: `std.posix.write` is confirmed present in this std (alongside `read`/`poll`). If the compiler reports it missing, substitute a raw `std.os.linux.write(fd, ptr, len)` wrapper mirroring `closeFd`.

- [ ] **Step 2: Export it**

In `src/root.zig` add: `pub const Uinput = @import("output/uinput.zig").Uinput;`

- [ ] **Step 3: Build**

Run: `zig build`
Expected: compiles. Fix any std API drift the compiler flags (esp. `std.Thread.sleep`, `std.posix.write`).

- [ ] **Step 4: Manual verification (needs /dev/uinput access)**

Temporary scratch in `main` is unnecessary — verify after Task 6 wiring. For now just confirm it compiles. If you want an early check:

```bash
# grant access for this session if needed:
#   sudo chmod a+rw /dev/uinput   (or add a udev rule, see README)
sudo zig build run -- --output uinput -v   # only works after Task 6
```

- [ ] **Step 5: Commit**

```bash
git add src/output/uinput.zig src/root.zig
git commit -m "feat(output): native uinput backend (no ydotool dependency)"
```

---

### Task 6: Wire the selector into main

Replace the hard-wired `Ydotool` with a selected output (and selected input), build an `Env` by probing, and route `--list-backends`.

**Files:**
- Modify: `src/main.zig`

- [ ] **Step 1: Implement environment probe + dispatch**

In `src/main.zig`, after parsing `cfg` and handling `--help`/`--list`, add:

```zig
const select = z.select;

fn probeEnv() select.Env {
    var env = select.Env{};
    const session = std.posix.getenv("XDG_SESSION_TYPE") orelse "";
    if (std.mem.eql(u8, session, "wayland")) env.session = .wayland
    else if (std.mem.eql(u8, session, "x11")) env.session = .x11;

    // /dev/uinput writable?
    if (z.platform.openRdwr("/dev/uinput")) |fd| {
        z.platform.closeFd(fd);
        env.has_uinput = true;
    } else |_| {}

    // ydotool socket present? ($YDOTOOL_SOCKET or default /run/user/<uid>/.ydotool_socket)
    env.has_ydotoold = ydotoolSocketExists();
    return env;
}
```

(Add `pub const platform = @import("platform/linux.zig");` and `pub const select = @import("select.zig");` to `root.zig`. `std.posix.getenv` is available in this std; if not, read from `init.minimal.environ`.)

Add a `ydotoolSocketExists()` helper using `std.posix.getenv("YDOTOOL_SOCKET")` or building `/run/user/{uid}/.ydotool_socket` and `std.fs`/`access` to check. If `std.fs.accessAbsolute` is unavailable, attempt a raw `open` and treat success as present.

Then resolve and dispatch:

```zig
    if (cfg.list_backends) {
        std.debug.print("input:  evdev\noutput: uinput, ydotool\n", .{});
        return;
    }

    const env = probeEnv();
    const choice = select.resolve(env, .{
        .input = cfg.input, .output = cfg.output, .suppress = cfg.suppress,
    }) catch |err| {
        std.debug.print("seleção de backend falhou: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    // input (only evdev today)
    var evdev = z.LinuxEvdev.init(cfg.device, cfg.buttonCodes(), cfg.suppress) catch |err| { /* existing switch */ };
    defer evdev.deinit();

    // output
    var ydotool: z.Ydotool = undefined;
    var uinput: z.Uinput = undefined;
    const out_iface: z.backend.OutputBackend = switch (choice.output) {
        .uinput => blk: {
            uinput = z.Uinput.init() catch |err| {
                std.debug.print("uinput indisponível ({s}); tente --output ydotool ou dê acesso a /dev/uinput.\n", .{@errorName(err)});
                std.process.exit(1);
            };
            break :blk uinput.interface();
        },
        .ydotool => blk: {
            ydotool = z.Ydotool.init(io);
            break :blk ydotool.interface();
        },
        .evdev => unreachable,
    };
    defer if (choice.output == .uinput) uinput.deinit();

    var triggers = z.core.Triggers{ .codes = cfg.buttonCodes() };
    std.debug.print("zclicker: {s} | {d}ms | in={s} out={s}{s} | Ctrl+C\n", .{
        evdev.deviceName(), cfg.interval_ms, @tagName(choice.input), @tagName(choice.output),
        if (cfg.suppress) " | suppress" else "",
    });
    try z.core.run(evdev.interface(), out_iface, &triggers, cfg.interval_ms, cfg.verbose);
```

(Update `LinuxEvdev.init` signature in Task 7 to accept the `suppress` bool; until then pass nothing and ignore. To keep this task compiling, temporarily call `z.LinuxEvdev.init(cfg.device, cfg.buttonCodes())` and add the `suppress` param in Task 7.)

- [ ] **Step 2: Build + smoke test**

Run: `zig build && ./zig-out/bin/zclicker --list-backends`
Expected: prints `input: evdev` / `output: uinput, ydotool`.

Run (with uinput access): `sudo zig build run -- -v` then hold button 4/5 over a scratch window.
Expected: left clicks fire via the virtual device; banner shows `out=uinput`.

- [ ] **Step 3: Commit**

```bash
git add src/main.zig src/root.zig
git commit -m "feat: select backends at runtime, default to native uinput output"
```

---

### Task 7: Suppression — evdev grab + uinput re-injection

When `--suppress`, the evdev backend grabs the device (`EVIOCGRAB`) and re-injects every non-trigger event through a private uinput passthrough device, swallowing buttons 4/5.

**Files:**
- Modify: `src/input/evdev.zig` (the renamed `linux_evdev.zig`)

- [ ] **Step 1: Add EVIOCGRAB + a passthrough uinput device**

In `evdev.zig`, add the grab ioctl and a small passthrough writer. Reuse the `Uinput`-style setup but declare a broad mouse capability set so re-injected movement/scroll/buttons pass through:

```zig
fn EVIOCGRAB() u32 {
    return lx.iow('E', 0x90, @sizeOf(c_int));
}
```

Add fields to `LinuxEvdev`: `suppress: bool`, `passthrough_fd: std.posix.fd_t` (=-1 when not suppressing). Extend `init` to accept `suppress: bool`:

```zig
pub fn init(device: ?[]const u8, codes: []const u16, suppress: bool) !LinuxEvdev {
    var self = LinuxEvdev{ .fd = -1, .suppress = suppress, .passthrough_fd = -1 };
    // ... existing open + name read ...
    if (suppress) {
        if (@as(isize, @bitCast(std.os.linux.ioctl(self.fd, EVIOCGRAB(), 1))) < 0) return error.GrabFailed;
        self.passthrough_fd = try openPassthrough();
    }
    return self;
}
```

`openPassthrough()` mirrors `Uinput.init` but declares: `EV_KEY` + all of `BTN_LEFT..BTN_TASK` (0x110..0x117), `EV_REL` + `REL_X(0)`,`REL_Y(1)`,`REL_WHEEL(8)`,`REL_HWHEEL(6)`,`REL_WHEEL_HI_RES(0x0b)`,`REL_HWHEEL_HI_RES(0x0c)`. (Factor the shared uinput-create code into `platform/linux.zig` as `createUinput(caps)` and call it from both `output/uinput.zig` and here — do this refactor as part of this step to stay DRY.)

- [ ] **Step 2: Re-inject in `fill`**

Change `fill` so that when `self.suppress`, every event read that is **not** a trigger button is written verbatim to `passthrough_fd`; trigger-button key events are consumed (queued as `TriggerEvent`, not forwarded). Keep forwarding `EV_SYN` so re-injected reports are flushed.

```zig
// inside the read loop, for each ev:
if (ev.type == lx.EV_KEY and isTrigger(ev.code, codes)) {
    // consume as a trigger (existing pending logic)
} else if (self.suppress and self.passthrough_fd >= 0) {
    writeEvent(self.passthrough_fd, ev) catch {};
}
```

(`codes` must be stored on the struct now — add `codes: []const u16` set in `init` — so `fill` can tell trigger buttons from re-injectable ones.)

- [ ] **Step 3: deinit ungrabs + destroys passthrough**

```zig
pub fn deinit(self: *LinuxEvdev) void {
    if (self.suppress and self.fd >= 0) _ = std.os.linux.ioctl(self.fd, EVIOCGRAB(), 0);
    if (self.passthrough_fd >= 0) { _ = std.os.linux.ioctl(self.passthrough_fd, UI_DEV_DESTROY(), 0); lx.closeFd(self.passthrough_fd); }
    if (self.fd >= 0) lx.closeFd(self.fd);
    self.fd = -1;
}
```

Set `.caps = .{ .can_suppress = true }` in `interface()`.

- [ ] **Step 4: Build + manual verification**

Run: `zig build`
Expected: compiles.

Run (with /dev/uinput + input access): `sudo zig build run -- --suppress -v`
Manual checks:
1. Hold button 4/5 → left clicks fire, and the focused app does **not** navigate back/forward.
2. Move the mouse / scroll / left-click normally while NOT holding 4/5 → everything still works (proves re-injection).
3. `Ctrl+C` → mouse fully returns to normal (grab released). Verify back/forward works again.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: navigation suppression via evdev grab + uinput re-injection"
```

---

### Task 8: Signal cleanup (critical with grab)

Ensure SIGINT/SIGTERM release the grab and destroy uinput devices, so the mouse never gets stuck if killed mid-hold.

**Files:**
- Modify: `src/main.zig`

- [ ] **Step 1: Install handlers that run deinit**

Store pointers to the live `evdev` (and `uinput`) in file-scope optionals, install `std.posix.sigaction` for `SIGINT`/`SIGTERM` whose handler calls their deinit then `std.process.exit(0)`:

```zig
var g_evdev: ?*z.LinuxEvdev = null;
var g_uinput: ?*z.Uinput = null;

fn onSignal(_: c_int) callconv(.c) void {
    if (g_evdev) |e| e.deinit();
    if (g_uinput) |u| u.deinit();
    std.process.exit(0);
}

fn installSignals() void {
    var act = std.posix.Sigaction{ .handler = .{ .handler = onSignal }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}
```

Wire `g_evdev = &evdev;` (and `g_uinput = &uinput;` when chosen) and call `installSignals()` before `core.run`. Verify `std.posix.sigaction`/`Sigaction`/`sigemptyset` exist in this std; if the API differs, use `std.os.linux.sigaction` directly. Note: doing real work in a signal handler is technically unsafe, but `EVIOCGRAB 0` + `UI_DEV_DESTROY` + `close` are single syscalls and acceptable here; the kernel also auto-releases the grab on process death as a backstop.

- [ ] **Step 2: Manual verification**

Run: `sudo zig build run -- --suppress` then, while holding button 4, `kill -TERM <pid>` from another terminal.
Expected: mouse immediately back to normal (no stuck grab, no zombie virtual device — check `zclicker --list` shows no leftover passthrough).

- [ ] **Step 3: Commit**

```bash
git add src/main.zig
git commit -m "feat: release grab and destroy virtual devices on SIGINT/SIGTERM"
```

---

### Task 9: Device hotplug reopen

If the mouse is unplugged (read/poll returns ENODEV), re-find and reopen instead of crashing.

**Files:**
- Modify: `src/input/evdev.zig`

- [ ] **Step 1: Detect device loss and reopen**

In `fill`/`nextEvent`, treat `error.NoDevice`/ENODEV (and read returning error other than WouldBlock) as a signal to: ungrab+close current fd (and passthrough), then loop calling `findDevice(codes)` every 500ms until it succeeds, re-applying grab+passthrough. Add a `reopen()` method encapsulating this. Print `"dispositivo reconectado: {s}"` on success when verbose.

```zig
fn reopen(self: *LinuxEvdev) !void {
    if (self.fd >= 0) { if (self.suppress) _ = std.os.linux.ioctl(self.fd, EVIOCGRAB(), 0); lx.closeFd(self.fd); self.fd = -1; }
    while (true) {
        self.fd = findDevice(self.codes) catch {
            std.Thread.sleep(500 * std.time.ns_per_ms);
            continue;
        };
        if (self.suppress) _ = std.os.linux.ioctl(self.fd, EVIOCGRAB(), 1);
        self.name_len = nameInto(self.fd, &self.name_buf);
        return;
    }
}
```

Call `try self.reopen()` from `nextEvent` when a read error indicates the device vanished.

- [ ] **Step 2: Manual verification**

Run: `zig build run -- -v`, then unplug and replug the mouse.
Expected: no crash; after replug, holding 4/5 clicks again; verbose prints reconnection.

- [ ] **Step 3: Commit**

```bash
git add src/input/evdev.zig
git commit -m "feat: reopen mouse on hotplug instead of crashing"
```

---

### Task 10: Docs + udev rule

Document the native uinput path, the `/dev/uinput` permission requirement, the new flags, and the suppression feature.

**Files:**
- Modify: `README.md`
- Create: `packaging/99-zclicker-uinput.rules`

- [ ] **Step 1: README updates**

Add a "Backends" section (input: evdev; output: uinput default / ydotool fallback), document `--input/--output/--suppress/--list-backends`, and a "Permissions" section: either run with sudo or install a udev rule so `/dev/uinput` is group-writable.

- [ ] **Step 2: udev rule**

`packaging/99-zclicker-uinput.rules`:

```
KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"
```

Document: `sudo cp packaging/99-zclicker-uinput.rules /etc/udev/rules.d/ && sudo udevadm control --reload && sudo modprobe uinput`. Then no sudo needed (user already in `input`).

- [ ] **Step 3: Mark roadmap item 1 (suppression) done; commit**

```bash
git add README.md packaging/99-zclicker-uinput.rules
git commit -m "docs: backends, permissions, udev rule; suppression shipped"
```

---

## Self-Review

**Spec coverage:** abstraction+capabilities (Task 2) ✓ · selection/fallback/overrides (Task 4, 6) ✓ · native uinput output (Task 5) ✓ · suppression (Task 7) ✓ · signal cleanup (Task 8) ✓ · hotplug (Task 9) ✓ · CLI surface (Task 3) ✓ · DRY platform helpers (Task 1, shared `createUinput` in Task 7) ✓. Follow-up backends (wlr-virtual-pointer, X11, libei, hidraw, Windows, compositor-IPC) intentionally deferred to their own plans.

**Type consistency:** `interface()` is the method name on every backend (evdev, uinput, ydotool) after Task 2 — the old `backend()` name is fully renamed to avoid colliding with `@import("backend.zig")`. `BackendId` values `evdev`/`uinput`/`ydotool` are used identically in cli.zig, select.zig, main.zig. `LinuxEvdev.init` gains its third param (`suppress`) in Task 7; Task 6 explicitly notes the temporary 2-arg call until then.

**Placeholder scan:** no TBD/TODO; every code step has concrete code. Volatile-std spots (`std.posix.write`, `std.Thread.sleep`, `std.posix.sigaction`, `std.posix.getenv`) carry an explicit "verify/substitute" note rather than being assumed.

**Risk note:** this std (`0.17.0-dev`) churns; each task ends in `zig build`/`zig build test`, so API drift surfaces immediately and is fixed against `/usr/lib/zig/std`.
