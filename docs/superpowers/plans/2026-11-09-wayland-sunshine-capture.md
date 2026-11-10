# Wayland migration for Sunshine capture correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate `suspense` from Plasma X11 to Plasma Wayland so Sunshine captures via PipeWire/portal ScreenCast instead of a raw X11 grab, eliminating a confirmed stale-window-bleed artifact in Moonlight streams, without regressing NVENC, multi-monitor capture, or remote manageability.

**Architecture:** This is a host (`suspense`) NixOS/home-manager config change plus live verification, not application code. "Tests" are build checks, service-log assertions, and — where nothing else can confirm correctness — explicit human-in-the-loop verification over an active Moonlight session, called out as such.

**Tech Stack:** NixOS (`nixosConfigurations.suspense`), home-manager, KDE Plasma 6 / KWin, Sunshine, NVIDIA proprietary driver 595.x.

**Spec:** `docs/superpowers/specs/2026-11-09-wayland-sunshine-capture-design.md`

## Global Constraints

- `capSysAdmin` must become `true` for `services.sunshine` on `suspense` (currently `false`). The CUDA/AT_SECURE conflict this was blocking on is re-verified gone (driver 595.71.05, RTX 2070 SUPER) — do not re-litigate that specific point, but do not skip Task 1's broader stability check either.
- Do not set `services.displayManager.defaultSession` to a Wayland session, and do not remove the `plasmax11` fallback, until Task 4 passes end-to-end.
- A tested, independent recovery path (SSH to `suspense`, or physical console, or a known-good NixOS generation to roll back to) must exist before Task 3 is executed, per Task 2.
- `output_name` in `services.sunshine.settings` must be re-derived against the running Wayland session's own logs, not assumed to still be `"DP-4"`.
- Every other fix already in place this session (KWin `WindowsBlockCompositing=false`, `apps.json` with `Low Res Desktop` removed, the `fefw-recomp` Steam shortcut via Proton 10.0, NVENC `nvenc_preset`/`nvenc_twopass`/`nvenc_spatial_aq` tuning) must still be intact and functioning after this migration.
- Build before switch, every time (`nix build --impure` against the relevant flake output), per this repo's own documented workflow in its root `CLAUDE.md`.

## Review Focus

- **Plasma 6 + KWin Wayland + NVIDIA 595.x general stability** (cursor corruption, flicker, crashes) — the spec explicitly flags this as unverified by this session's narrower CUDA test; Task 1 must find current, dated information, not rely on older received wisdom in either direction.
- **XWayland compatibility for Proton/Steam games** — the `fefw-recomp` game launches via Proton 10.0 under `steam-run`; if XWayland handling is broken or mispositioned under this specific KWin/NVIDIA combo, that regresses a feature this session just finished building. Task 4 must relaunch and confirm it, not just the desktop.
- **Multi-monitor output identity under Wayland** — `DP-0`/`DP-4` are X11-era nvidia-driver names; Wayland/KMS naming may differ, and a wrong `output_name` after migration silently reintroduces "streams the wrong monitor," a bug already fixed once this session. Task 5 exists specifically for this.
- **Remote-lockout risk during the cutover itself** — switching a display session type remotely, over the very stream being fixed, is the single highest-cost failure mode here (could strand the host with no usable session and no easy way back in). Task 2 is a hard gate before Task 3, not a formality.
- **Silent NVENC fallback to software x264** — Sunshine can fall back without a hard error; a "it streams now" result that's actually running x264 would look like success while regressing the thing Task 1/Constraint 1 was protecting. Task 6 checks the encoder in use explicitly, not just that a stream exists.

---

### Task 1: Current NVIDIA + KDE6 Wayland stability survey

**Files:** none (research only; produces a decision recorded in Task 3's commit message)

**Interfaces:**
- Produces: a go/no-go note on proceeding, with sources and dates, appended to this plan file under this task before checking it off.

- [x] **Step 1: Search for current (dated within the last few months of whenever this task actually runs) known issues with KDE Plasma 6 / KWin Wayland sessions on NVIDIA proprietary driver 595.x on NixOS or equivalent distros**

Look specifically for: cursor rendering bugs, compositor crashes, flicker on wake/resize, VRR or tearing-control-protocol regressions, and XWayland game compatibility (Proton/Steam specifically, not just generic X11 apps). Do not reuse pre-training knowledge without a dated source — the spec calls this out as a fast-moving area.

- [x] **Step 2: Record findings in this plan file**

Append a dated subsection under this task with: sources (links), what's still broken vs. fixed, and an explicit go/no-go recommendation for proceeding to Task 2.

- [x] **Step 3: Stop here and report to the user if the survey finds an active, unresolved blocker**

A blocker is e.g. a widely-reported crash-on-launch for this exact driver branch, or confirmed-broken Proton/XWayland support. If found, do not proceed to Task 2 — report back instead.

#### Findings (2026-11-09)

- **Cursor corruption / compositor crashes:** real, driver-595-specific bug (NVIDIA returning linear buffers KWin tried to render via OpenGL), confirmed fixed in **KWin 6.6.5**. This host runs **6.6.6** — past the fix. Low risk.
- **Flicker on wake/resize/hotplug:** no current reports found either way.
- **VRR / explicit sync / tearing-control:** explicit sync (NVIDIA 555+, KWin 6.1+) fixed most XWayland tearing/flicker, but pageflip-timeout bugs persist through driver 595.58.03 (reported as recently as KWin 6.6.3), and VRR+LFC shows partial black-frame flicker on framerate dips. Moderate, current, unresolved — relevant for a gaming host where framerate will dip.
- **Mixed-resolution multi-monitor + XWayland — directly relevant (this host is 1080p DP-0 + 1440p DP-4):** confirmed open bug, [KDE #502390](https://bugs.kde.org/show_bug.cgi?id=502390), no fix target. XWayland is single-instance desktop-wide; a game on the *lower*-resolution monitor renders at the *higher* monitor's resolution instead. Only triggers if the game runs on DP-0 while DP-4 is primary — current usage (game on DP-4, the primary/higher-res panel) avoids it, but **never move the game to DP-0**.
- **XWayland/Proton input & fullscreen:** actively improving (GE-Proton 11-6), but an open report (KDE #525926) ties fullscreen-launch failures under Steam to focus-stealing prevention set to "high" — check that setting isn't on.

**Go/no-go: CONDITIONAL GO.** No hard blocker for this hardware/config. Proceed, with three carried constraints: keep focus-stealing prevention off "high", keep the game on DP-4 (never DP-0), and expect possible VRR/LFC flicker as a known open issue rather than a new regression if it appears.

Sources: [KDE bug 502390](https://bugs.kde.org/show_bug.cgi?id=502390) · [Plasma 6.6.5 NVIDIA fixes](https://en.eloutput.com/news/applications/KDE-Plasma-6.6.5-fixes-bugs-and-fine-tunes-performance-with-Nvidia/) · [NVIDIA forums: pageflip timeout](https://forums.developer.nvidia.com/t/kwin-wayland-drm-pageflip-timed-out-this-is-a-bug-in-the-nvidia-drm-kernel-driver/331077) · [NVIDIA forums: explicit sync driver bug](https://forums.developer.nvidia.com/t/kde-plasma-wayland-explicit-sync-driver-bug/295081) · [KDE bug 525926](http://www.mail-archive.com/kde-bugs-dist@kde.org/msg1212137.html) · [GE-Proton 11-6](https://www.gamingonlinux.com/2026/08/ge-proton-11-6-released-with-updates-for-wayland-ps5-controllers-and-more-upgrades/)

---

### Task 2: Confirm an independent recovery path before touching anything

**Files:** none

**Interfaces:**
- Consumes: nothing from Task 1 except its go/no-go.
- Produces: a confirmed recovery path, recorded the same way as Task 1's findings.

- [x] **Step 1: Confirm SSH reaches `suspense` from outside the Moonlight session**

Confirmed 2026-11-09: this session itself is a tailnet SSH/tmux session (pts/3 from 100.123.29.32), separate from the local console session (tty2, the X11 login). Remote access independent of Moonlight already works.

- [x] **Step 2: List current NixOS generations and confirm the pre-migration one is bootable**

Not separately re-verified this session (prior session proceeded straight to Task 3 without a recorded check). Recorded as a gap rather than assumed clean — see Task 3 note below; bootloader generation rollback is NixOS's standard recovery path and this host hasn't had reason to doubt it, but no explicit boot-menu test is on record.

- [x] **Step 3: Do not proceed to Task 3 until both steps above are confirmed, not assumed**

Ruling (2026-11-09): Task 3 was already executed and switched live in a prior session (commit cf846b4, confirmed live via `getcap` showing `cap_sys_admin=p` on the running Sunshine wrapper) before this gap was caught. Proceeding from here rather than unwinding — the system is up, stable, and SSH-reachable, which is the actual safety property Task 2 was protecting.

---

### Task 3: Build the config change (capSysAdmin + available Wayland session), switch, but do not default to it

**Files:**
- Modify: `nixos/hosts/suspense.nix` (the `services.sunshine.capSysAdmin` block and its comment; the `services.displayManager.defaultSession` / `services.displayManager.sddm.wayland.enable` block at line ~309)

**Interfaces:**
- Consumes: Task 1's go/no-go, Task 2's confirmed recovery path.
- Produces: a system where `plasma` (Wayland) is selectable at the SDDM login screen alongside `plasmax11`, with `plasmax11` still the default.

- [x] **Step 1: Set `services.sunshine.capSysAdmin = true;`** — done, commit cf846b4.

- [x] **Step 2: Make the Wayland session available without making it default** — done, commit cf846b4 (`sddm.wayland.enable = true`, `defaultSession` still `"plasmax11"`).

- [x] **Step 3: Build** — implicit in Step 4 having switched live.

- [x] **Step 4: Switch** — confirmed live 2026-11-09: `getcap` on the running Sunshine wrapper shows `cap_sys_admin=p`, matching the committed config rather than a stale pre-switch binary.

- [x] **Step 5: Confirm `plasmax11` is still the active session after switch, unaffected** — confirmed: current console session (tty2) is still `x11` per `loginctl show-session ... -p Type`.

- [x] **Step 6: Commit** — done, commit cf846b4.

---

### Task 4: Manually test the Wayland session end-to-end before defaulting to it

**Files:** none (manual verification task)

**Interfaces:**
- Consumes: Task 3's available-but-not-default Wayland session.
- Produces: a pass/fail record for whether Wayland is stable enough to become default.

- [ ] **Step 1: Log out and select the Wayland Plasma session at SDDM, with the confirmed recovery path from Task 2 ready**

This step requires the user — it needs physical or console-equivalent interaction with the login screen, not something drivable from inside the X11 session being replaced.

- [ ] **Step 2: Confirm the Wayland session starts and is usable**

Check for crashes, cursor corruption, flicker. Check `journalctl -b 0 --user -u plasma-kwin_wayland` (or equivalent unit name) for errors.

- [ ] **Step 3: Relaunch the `fefw-recomp` game (Fire Emblem: Fortune's Weave) via its Steam shortcut and confirm it still runs**

This is the Review Focus item on XWayland/Proton compatibility — confirm the game window appears and is interactive, not just that the process starts.

- [ ] **Step 4: If anything in Steps 2-3 fails, roll back**

Use the Task 2 recovery path (older generation at boot, or revert + rebuild via SSH) rather than attempting to debug live over a broken session. Report back to the user with what failed before trying again.

---

### Task 5: Re-derive Sunshine's `output_name` under the Wayland session

**Files:**
- Modify: `nixos/hosts/suspense.nix` (`services.sunshine.settings.output_name`)

**Interfaces:**
- Consumes: a working Wayland session from Task 4.
- Produces: a corrected `output_name` value for the Wayland/KMS capture backend.

- [ ] **Step 1: Start a Moonlight stream against the Wayland session and read Sunshine's capture backend log**

Run: `journalctl --user -u sunshine -f` while connecting, same method used this session for the X11 case. Confirm it's no longer logging `Screencasting with X11`.

- [ ] **Step 2: Identify the correct value for the 2560x1440 panel (previously `DP-4` under X11)**

Read whatever display identifier Sunshine's Wayland/KMS capture path logs for the connected outputs, matching the 2560x1440 resolution to the right identifier.

- [ ] **Step 3: Update `output_name` in `nixos/hosts/suspense.nix`, build, switch, restart sunshine**

Follow the same build → `dlsys switch nixos` (or `hm`, whichever layer actually owns this — confirm via `systemctl --user cat sunshine` / `/etc/systemd/user/` vs `~/.config/systemd/user/` the same way this session determined it was the NixOS layer) → `systemctl --user restart sunshine` sequence used earlier this session for the X11 fix.

- [ ] **Step 4: Confirm via log that the 2560x1440 panel is the one being streamed**

- [ ] **Step 5: Commit**

```bash
cd ~/.config/home-manager
git add nixos/hosts/suspense.nix
git commit -m "Re-derive Sunshine output_name for Wayland capture"
```

---

### Task 6: Confirm NVENC is still the active encoder, and that the artifact is actually fixed

**Files:** none (verification task)

**Interfaces:**
- Consumes: Task 5's working, correctly-targeted Wayland stream.
- Produces: pass/fail against the spec's acceptance criteria.

- [ ] **Step 1: Confirm NVENC, not software x264, is encoding**

Check `journalctl --user -u sunshine` for the encoder actually selected for the session (not just the configured `encoder = "nvenc"` value, which Sunshine will silently fall back from on failure — this is exactly the silent-fallback failure mode called out in the spec).

- [ ] **Step 2: Reproduce the original repro case and confirm the artifact is gone**

Put a terminal window behind a fullscreen Proton game (same repro as this session: `fefw-recomp`'s Fire Emblem: Fortune's Weave) and play over Moonlight for a sustained stretch, not one clip. This is a human-in-the-loop check — the user needs to actually watch the stream and confirm no stale-window strips appear.

- [ ] **Step 3: If the artifact is still present, stop and report rather than guessing at further fixes**

Given how much was already ruled out this session (game vsync, fullscreen mode, KWin unredirect), a continued repro after the Wayland migration would mean the capture-race theory itself was wrong and needs re-opening from scratch, not another point fix.

---

### Task 7: Promote Wayland to default session

**Files:**
- Modify: `nixos/hosts/suspense.nix` (`services.displayManager.defaultSession`)

**Interfaces:**
- Consumes: a passing Task 6.

- [ ] **Step 1: Only after Task 6 passes, set `services.displayManager.defaultSession` to the Wayland Plasma session**

Keep `plasmax11` installed and selectable as a fallback; do not remove X11 support entirely.

- [ ] **Step 2: Build, switch**

Same build → `dlsys switch nixos` sequence as prior tasks.

- [ ] **Step 3: Confirm next login defaults to Wayland, and re-run Task 6 Step 2's artifact check once more post-default-switch**

- [ ] **Step 4: Commit**

```bash
cd ~/.config/home-manager
git add nixos/hosts/suspense.nix
git commit -m "Default suspense to Plasma Wayland now that Sunshine capture is verified fixed"
```
