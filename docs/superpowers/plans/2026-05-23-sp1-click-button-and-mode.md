# SP1 — Click Button + Mode — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the click button (left/right/middle) and the activation mode (hold vs toggle) configurable from the CLI.

**Architecture:** Two new shared enums in `backend.zig` (`ClickButton`, `Mode`). The click button is fixed per run and configured at output-backend construction (`Uinput.init(button)`, `Ydotool.init(io, button)`), so `OutputBackend.click()` stays parameterless. `core.run` gains a `mode` param: `hold` keeps the existing held-set logic; `toggle` flips an `active` bool on each trigger press. The evdev backend already emits `TriggerEvent`s only for configured codes, so toggle treats every received press as a toggle.

**Tech Stack:** Zig `0.17.0-dev.305` (raw `std.os.linux` syscalls; `std.posix.open/close/write` absent), evdev/uinput, ydotool.

---

### Task 1: `ClickButton` + `Mode` enums in backend.zig

**Files:**
- Modify: `src/backend.zig`
- Modify: `src/root.zig` (add `_ = @import("backend.zig");` to the test block so these tests run)

- [ ] **Step 1: Write the failing tests** — append to `src/backend.zig`:

```zig
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ~/Documentos/Projetos-Pessoais/zclicker && zig build test`
Expected: FAIL — `ClickButton`/`Mode` undefined (and `backend.zig` tests must be wired into root.zig — do Step 3 first if the tests don't even get collected).

- [ ] **Step 3: Implement the enums** — add to `src/backend.zig` (after the existing `BackendId`/`Capabilities`; `lx` is already imported as `@import("platform/linux.zig")`):

```zig
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
```

In `src/root.zig`, add to the `test { ... }` block: `_ = @import("backend.zig");`

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/backend.zig src/root.zig
git commit -m "feat(backend): ClickButton and Mode enums"
```
(No Co-Authored-By trailer.)

---

### Task 2: `--click` / `--mode` CLI flags

**Files:**
- Modify: `src/cli.zig`

- [ ] **Step 1: Write the failing tests** — append to `src/cli.zig`:

```zig
test "click and mode flags parse" {
    const t = std.testing;
    const args = [_][:0]const u8{ "zclicker", "--click", "right", "--mode", "toggle" };
    const cfg = try parse(&args);
    try t.expectEqual(backend.ClickButton.right, cfg.click);
    try t.expectEqual(backend.Mode.toggle, cfg.mode);
}

test "click/mode defaults" {
    const t = std.testing;
    const args = [_][:0]const u8{"zclicker"};
    const cfg = try parse(&args);
    try t.expectEqual(backend.ClickButton.left, cfg.click);
    try t.expectEqual(backend.Mode.hold, cfg.mode);
}

test "invalid click errors" {
    const t = std.testing;
    const args = [_][:0]const u8{ "zclicker", "--click", "sideways" };
    try t.expectError(Error.InvalidClick, parse(&args));
}

test "invalid mode errors" {
    const t = std.testing;
    const args = [_][:0]const u8{ "zclicker", "--mode", "spam" };
    try t.expectError(Error.InvalidMode, parse(&args));
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test`
Expected: FAIL — no `cfg.click`/`cfg.mode`, no `Error.InvalidClick`/`InvalidMode`.

- [ ] **Step 3: Implement**

In `src/cli.zig` `Config`, add fields:
```zig
    click: backend.ClickButton = .left,
    mode: backend.Mode = .hold,
```
Add to `Error`: `InvalidClick`, `InvalidMode` (extend the existing `error{...}` set).
In `parse`, add branches before the final `else => return Error.UnknownArgument`:
```zig
        } else if (eq(a, "--click")) {
            i += 1;
            if (i >= args.len) return Error.MissingValue;
            cfg.click = backend.ClickButton.parse(args[i]) orelse return Error.InvalidClick;
        } else if (eq(a, "--mode")) {
            i += 1;
            if (i >= args.len) return Error.MissingValue;
            cfg.mode = backend.Mode.parse(args[i]) orelse return Error.InvalidMode;
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/cli.zig
git commit -m "feat(cli): --click and --mode flags"
```

---

### Task 3: `Mode` in `core.run` + `Toggle` state

**Files:**
- Modify: `src/core.zig`

- [ ] **Step 1: Write the failing test** — append to `src/core.zig`:

```zig
test "Toggle flips active on each press" {
    const t = std.testing;
    var tg = Toggle{};
    try t.expect(!tg.active);
    tg.press();
    try t.expect(tg.active);
    tg.press();
    try t.expect(!tg.active);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test`
Expected: FAIL — `Toggle` undefined.

- [ ] **Step 3: Implement** — in `src/core.zig`:

Add the struct:
```zig
/// Toggle-mode activation: each trigger press flips it.
pub const Toggle = struct {
    active: bool = false,
    pub fn press(self: *Toggle) void {
        self.active = !self.active;
    }
};
```

Change `run` to take `mode` and branch on it. Replace the existing `run` with:
```zig
pub fn run(
    in_backend: backend.InputBackend,
    out_backend: backend.OutputBackend,
    triggers: *Triggers,
    mode: backend.Mode,
    interval_ms: i32,
    verbose: bool,
) !void {
    var toggle = Toggle{};
    while (true) {
        const clicking = switch (mode) {
            .hold => triggers.anyHeld(),
            .toggle => toggle.active,
        };
        const timeout: i32 = if (clicking) interval_ms else -1;
        if (try in_backend.nextEvent(timeout)) |ev| {
            // The input backend only emits events for configured trigger codes,
            // so in toggle mode every press is a toggle.
            switch (mode) {
                .hold => triggers.apply(ev),
                .toggle => if (ev.pressed) toggle.press(),
            }
            if (verbose) {
                std.debug.print("[trigger] 0x{x} {s}\n", .{
                    ev.button,
                    if (ev.pressed) "down" else "up",
                });
            }
        } else {
            try out_backend.click();
            if (verbose) std.debug.print("[click]\n", .{});
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test`
Expected: PASS (note: `main.zig` won't compile yet because `run` has a new param — that's fixed in Task 5; `zig build test` compiles the test root which is `core.zig` via root.zig, not necessarily `main.zig`. If `zig build` (the exe) is part of `zig build test`, the build will fail until Task 5 — in that case do Task 5 immediately after and run the suite once at the end. Proceed to Task 4/5.)

- [ ] **Step 5: Commit**

```bash
git add src/core.zig
git commit -m "feat(core): toggle mode in run()"
```

---

### Task 4: Output backends emit the chosen button

**Files:**
- Modify: `src/output/uinput.zig`
- Modify: `src/output/ydotool.zig`

- [ ] **Step 1: Update `uinput.zig`** — store the button at init and emit it:

```zig
pub const Uinput = struct {
    fd: std.posix.fd_t,
    button: u16,

    pub fn init(button: backend.ClickButton) !Uinput {
        return .{
            .fd = try lx.createUinputDevice("zclicker-virtual-mouse", &.{button.evdevCode()}, &.{lx.REL_X}),
            .button = button.evdevCode(),
        };
    }

    // deinit, interface unchanged

    fn clickImpl(ptr: *anyopaque) anyerror!void {
        const self: *Uinput = @ptrCast(@alignCast(ptr));
        try lx.writeEvent(self.fd, lx.EV_KEY, self.button, 1);
        try lx.writeEvent(self.fd, lx.EV_SYN, lx.SYN_REPORT, 0);
        try lx.writeEvent(self.fd, lx.EV_KEY, self.button, 0);
        try lx.writeEvent(self.fd, lx.EV_SYN, lx.SYN_REPORT, 0);
    }
};
```
(`backend` is imported in this file already as `@import("../backend.zig")`. Keep `deinit`/`interface` exactly as they are.)

- [ ] **Step 2: Update `ydotool.zig`** — store the hex and use it:

```zig
pub const Ydotool = struct {
    io: std.Io,
    hex: []const u8,

    pub fn init(io: std.Io, button: backend.ClickButton) Ydotool {
        return .{ .io = io, .hex = button.ydotoolHex() };
    }

    // interface unchanged

    fn clickImpl(ptr: *anyopaque) anyerror!void {
        const self: *Ydotool = @ptrCast(@alignCast(ptr));
        var child = try std.process.spawn(self.io, .{
            .argv = &[_][]const u8{ "ydotool", "click", self.hex },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        _ = try child.wait(self.io);
    }
};
```
(`ydotool.zig` currently imports `OutputBackend` from `../backend.zig`; add `const backend = @import("../backend.zig");` if it only imported the type — use `backend.ClickButton` and the existing `OutputBackend` consistently.)

- [ ] **Step 3: Build** (full compile happens with Task 5; this task leaves `main.zig` calling the old `init()` signatures, so do Task 5 next, then build).

- [ ] **Step 4: Commit**

```bash
git add src/output/uinput.zig src/output/ydotool.zig
git commit -m "feat(output): click the configured button (left/right/middle)"
```

---

### Task 5: Wire click + mode through `main.zig`

**Files:**
- Modify: `src/main.zig`

- [ ] **Step 1: Update the calls.**
- The `.uinput` switch arm: `uinput = z.Uinput.init(cfg.click) catch |err| { ... };`
- The `.ydotool` switch arm: `ydotool = z.Ydotool.init(io, cfg.click);`
- The run call: `try z.core.run(evdev.interface(), out_iface, &triggers, cfg.mode, cfg.interval_ms, cfg.verbose);`
- Update the banner to include mode + click, e.g.:
```zig
    std.debug.print(
        "zclicker: {s} | {d}ms | {s} | clica={s} | in={s} out={s}{s} | Ctrl+C\n",
        .{ evdev.deviceName(), cfg.interval_ms, @tagName(cfg.mode), @tagName(cfg.click),
           @tagName(choice.input), @tagName(choice.output), if (cfg.suppress) " | suppress" else "" },
    );
```

- [ ] **Step 2: Update `printUsage`** — add the two flags after `--verbose`:
```zig
        \\      --click <btn>      botão clicado: left (padrão), right, middle
        \\      --mode <modo>      hold (padrão, segurar) ou toggle (alternar)
```

- [ ] **Step 3: Build + test the whole suite**

Run: `zig build && zig build test`
Expected: PASS. Then `./zig-out/bin/zclicker --help` shows `--click`/`--mode`.

- [ ] **Step 4: Commit**

```bash
git add src/main.zig
git commit -m "feat: wire --click and --mode through main"
```

---

## Self-Review

**Spec coverage (SP1 section):** `--click left|right|middle` (Task 1 enum + Task 2 flag + Task 4 emit + Task 5 wire) ✓; `--mode hold|toggle` (Task 1 + Task 2 + Task 3 core + Task 5 wire) ✓; click button fixed at backend construction ✓; toggle = press flips active ✓; `OutputBackend.click()` stays parameterless ✓.

**Placeholder scan:** no TBD/TODO; every code step has complete code. The only soft spot is the deliberate note that `main.zig` is inconsistent between Task 3/4 and Task 5 — flagged explicitly with the fix in Task 5, and the final build/test in Task 5 Step 3 is the gate.

**Type consistency:** `ClickButton`/`Mode` defined in `backend.zig` (Task 1) and referenced as `backend.ClickButton`/`backend.Mode` in cli (Task 2), core (Task 3), outputs (Task 4), main (Task 5). `Uinput.init(button)` and `Ydotool.init(io, button)` signatures match their call sites in Task 5. `core.run(..., mode, interval_ms, verbose)` param order matches Task 5's call. `Toggle.press()`/`.active` consistent between Task 3 definition and use.
