# zclicker — Configurable engine + GTK GUI — Design

**Date:** 2026-05-23
**Status:** approved (design), pending implementation plans
**Sequence:** Sub-project 1 → 2 → 3 → 4 (engine first, GUI last). Each sub-project is its own implementation plan.

## Overview

Extend the `zclicker` engine to be fully configurable (which button it clicks, hold
vs toggle mode, arbitrary trigger keys/buttons across mouse *and* keyboard), make
backend selection OS/session-aware, then add a native GTK4 config window on top.
The GUI wraps the CLI via `spawn` (decided earlier), so it only exposes flags the
engine provides — hence engine first.

## Goals

- Configurable: click button (left/right/middle), interval, trigger codes, hold/toggle
  mode, output backend (auto/uinput/ydotool), suppression.
- Triggers can be any mouse button **or** keyboard key (multi-device input).
- Backend auto-selected from OS + session, with manual override.
- A discoverable GTK4 window exposing all of it, including capture-to-bind.

## Non-goals (v1)

Suppression of **keyboard** triggers (mouse-button triggers only — see SP2),
profiles/presets, tray icon, global hotkey, autostart, theming.

---

## Sub-project 1 — Engine: click button + mode

**CLI (`cli.zig`):**
- `--click <left|right|middle>` (default `left`).
- `--mode <hold|toggle>` (default `hold`).

**Backend (`backend.zig` + outputs):**
- Add `pub const ClickButton = enum { left, right, middle };` with `evdevCode()`
  → `BTN_LEFT/RIGHT/MIDDLE`, and (for ydotool) `ydotoolCode()` → `0xC0/0xC1/0xC2`.
- The click button is fixed per run, so configure it at backend construction:
  `Uinput.init(button)` emits that BTN; `Ydotool.init(io, button)` clicks that hex.
  `OutputBackend.click(self)` stays parameterless.

**Core (`core.zig`):**
- Add `pub const Mode = enum { hold, toggle };`. `run(...)` takes `mode`.
- Replace the `anyHeld`-only logic with a `clicking()` decision per mode:
  - **hold:** clicking = any configured trigger currently held (current behavior).
  - **toggle:** keep `active: bool`. On a trigger event with `pressed == true`, flip
    `active` (ignore releases). clicking = `active`.
- Loop: on each `TriggerEvent`, update state (held set or toggle), recompute clicking,
  set poll timeout = interval when clicking else infinite.

**Tests:** core `hold` vs `toggle` transitions (press toggles, release ignored in
toggle; held tracked in hold); cli parse of `--click`/`--mode` incl. invalid values.

**Files:** `cli.zig`, `backend.zig`, `core.zig`, `output/uinput.zig`,
`output/ydotool.zig`, `main.zig` (pass click+mode through).

---

## Sub-project 2 — Engine: flexible triggers + multi-device (biggest)

**CLI (`cli.zig`):** `--buttons` token = a named alias **or** a raw decimal evdev
code. Aliases: `left=0x110, right=0x111, middle=0x112, 4/side=0x113, 5/extra=0x114,
forward=0x115, back=0x116, task=0x117`. Any other token parsed as a decimal u16 code
(covers keyboard keys, e.g. `183` = KEY_F13). Result: a `[]const u16` of codes (as
today, just richer parsing).

**Input (`input/evdev.zig` → generalize to multi-device):**
- Today: one device (found by BTN_SIDE/EXTRA). New: open **every** `/dev/input/eventX`
  whose `EV_KEY` capability bitmap contains **any** configured trigger code. Poll all
  their fds together; read from whichever is ready; emit `TriggerEvent{code,pressed}`
  from any of them.
- Internal shape: `devices: []Device`, each `Device{ fd, name, is_mouse, passthrough_fd }`.
  `nextEvent(timeout)` builds a pollfd array over all device fds (plus the deadline
  logic), drains the ready one(s).
- **Suppression scope (v1):** only **mouse** devices are grabbed + re-injected (the
  existing passthrough). A device is "mouse" if its caps include `REL_X`/`BTN_LEFT`.
  Keyboard-trigger devices are read but NOT grabbed (documented limitation). If
  `--suppress` is set and a configured code lives only on a non-mouse device, that
  code simply isn't suppressed; mouse-button triggers still are.
- Hotplug + signal cleanup generalize to the device set (reopen the lost device;
  ungrab/destroy all on exit).

**Tests:** cli `--buttons` parsing (aliases, raw codes, mixed, invalid); device-set
selection logic if extractable as a pure helper (which codes map to which caps).
Multi-device runtime behavior is manual-verified.

**Files:** `cli.zig`, `input/evdev.zig` (substantial), `main.zig` (signal globals over
the set), `platform/linux.zig` (helpers as needed).

---

## Sub-project 3 — Engine: OS/session-aware selection

**`select.zig` + `main.zig`:** Fold `builtin.os.tag` (comptime) and `Session`
(wayland/x11/unknown, already probed from `$XDG_SESSION_TYPE`) into `resolve`. Linux
keeps uinput→ydotool preference; the resolved `Choice` records the detected
OS/session so the banner and the GUI can show `auto (detectado: wayland → uinput)`.
This is the seam future backends (wlr-virtual-pointer, X11 XTest, Windows SendInput)
slot into.

**Tests:** `resolve` with different `Env` (os/session/availability) returns expected
backend; override still wins.

**Files:** `select.zig`, `main.zig`.

---

## Sub-project 4 — GUI (GTK4, wraps the CLI)

Second build target `zclicker-gui` (root `src/gui/main.zig`), same `0.17-dev`
toolchain, links system `gtk4` via `@cImport`. Wraps the CLI by spawning it.

**Window (native GTK widgets):**
```
┌──────────────── zclicker ────────────────┐
│ Modo:        ( ) Segurar   ( ) Alternar   │
│ Clicar com:  [ esquerdo ▾ ]               │
│ Intervalo:   [  50 ▴▾] ms                 │
│ Gatilhos:    [ Botão 4 ✕ ] [ Botão 5 ✕ ]  │
│              [ + Capturar ]               │
│ Saída:       [ auto ▾ ]  (detectado: …)   │
│ Dispositivo: [____________] (vazio = auto)│
│ [x] Suprimir voltar/avançar (só mouse)    │
│ Status: parado                            │
│              [  Iniciar  ]                │
└────────────────────────────────────────────┘
```

**Components:**
- `gui/c.zig` — single `@cImport(<gtk/gtk.h>)`.
- `gui/command.zig` — PURE `buildArgv(alloc, Config, bin_path) [][]const u8`
  mapping the form to CLI flags (`-i`, `-b`, `--click`, `--mode`, `--output`, `-d`,
  `--suppress`). Unit-tested.
- `gui/capture.zig` — PURE-ish evdev capture: open input devices, block for the next
  key/button press, return its evdev code (for "Capturar"). Needs `input` group.
- `gui/main.zig` — GTK glue: build window, wire widgets, GSubprocess spawn/stop,
  status, capture dialog.

**Spawn/stop:** `g_subprocess_newv` with `STDERR_PIPE`; Stop = `g_subprocess_send_signal`
SIGTERM (reuses engine cleanup); `g_subprocess_wait_async` resets status; child stderr
surfaced on fast nonzero exit (covers `/dev/uinput` permission errors).

**Binary resolution:** `$ZCLICKER_BIN` → sibling of the GUI exe (`/proc/self/exe`) →
`zclicker` on PATH.

**Build:** `-Dgui` option includes `zclicker-gui` in install; a `gui` step builds+runs
it. `linkSystemLibrary("gtk4")` + `linkLibC()`. Default `zig build`/`test` stay
CLI-only so non-GTK builds are unaffected.

**Tests:** `command.buildArgv` unit tests; GTK UI + capture manual-verified
(documented smoke test).

---

## Cross-cutting

**Error handling:** invalid CLI values → clear error + nonzero exit (engine); GUI
surfaces child errors in the status label; no-trigger-selected disables Start.

**Testing strategy:** all pure logic (cli parsing, core mode state machine, select
resolve, command argv builder) gets real unit tests in `zig build test`; hardware I/O
(multi-device read, grab/re-inject, GTK window, evdev capture) is manual-verified with
documented smoke tests.

**Risks:**
- SP2 multi-device is the largest change to `evdev.zig`; keep `Device` small and the
  poll loop focused. Reopen/cleanup must cover the whole set.
- Keyboard-trigger suppression is intentionally out of scope (would need a keyboard
  passthrough); documented.
- GTK `@cImport` verbosity; keep logic in `command.zig`/`capture.zig`.
- Zig `0.17-dev` churn; each plan ends in `zig build`/`test` to catch drift early.
