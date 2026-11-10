# Wayland migration for Sunshine capture correctness

## Problem

Moonlight-streamed gameplay (via Sunshine, host `suspense`) shows a reproducible visual
artifact: strips of a window that sits *behind* the active fullscreen game (observed
with a terminal) briefly bleed into the captured/streamed frame. Confirmed this session
to be independent of:

- the game's own VSync setting (verified on: tested both off and on; present mode
  confirmed via the game's own log to switch from `immediate` to `fifo` correctly)
- the game's fullscreen mode (exclusive fullscreen and borderless fullscreen both
  reproduce it)
- KWin's fullscreen-unredirect optimization (`WindowsBlockCompositing=false` set and a
  full `kwin_x11 --replace` performed; artifact persisted)

Root cause: Sunshine on this host captures via plain X11 (`XShmGetImage`-style root
window grab) — confirmed in `journalctl --user -u sunshine`, which logs
`Screencasting with X11` for every stream (the `xdg-desktop-portal` ScreenCast path was
attempted and failed with `response code: 2`, before falling back to X11). Raw X11
capture has no atomicity guarantee against compositor repaints or window restacking;
it can sample a root-window region that still holds previous content. High negotiated
bitrate (166 Mbps observed) combined with any real network packet loss prolongs how
long such a bad frame is visible (lost corrective inter-frames + decoder error
concealment holds the last good decode), but is not the origin of the bad pixels —
only why they're seen for longer than one frame.

Under Wayland, Sunshine instead captures via PipeWire/`xdg-desktop-portal` ScreenCast:
the compositor hands over a buffer only once it is fully composited, with no
read-while-writing race window. This is an architectural difference, not a tuning knob
— it is expected to eliminate this bug class rather than mitigate it.

## Goal

Migrate `suspense`'s desktop session from Plasma X11 to Plasma Wayland so Sunshine's
capture path changes from raw X11 grab to portal/PipeWire ScreenCast, while preserving:

- NVENC hardware encoding (no fallback to software x264)
- DP-4 (2560x1440) as the captured display
- working Proton/Steam game launches (established this session for the
  `fefw-recomp` native build; must keep working, likely via XWayland transparently)
- remote manageability of the host (primary access path is Moonlight/Sunshine itself)

## Constraints

1. **capSysAdmin must flip to `true`.** Sunshine's KMS/portal capture backend (the
   Wayland path) needs it; `nixos/hosts/suspense.nix` currently pins it `false`. The
   comment there previously claimed this breaks NVENC via a CUDA/`AT_SECURE` conflict —
   **re-tested this session (2026-11-09, driver 595.71.05, RTX 2070 SUPER) and that no
   longer reproduces**: a `cap_sys_admin+p` file-capability binary initializes CUDA
   successfully (`cuInit`/`cuDeviceGet` both return `CUDA_SUCCESS`). Treat this as
   cleared, not as something to re-prove.

2. **"NVIDIA on Wayland is flaky" is NOT independently re-verified.** This is a
   *separate*, broader claim from the same file (`nixos/hosts/suspense.nix:309`,
   `services.displayManager.defaultSession = "plasmax11"` /
   `services.displayManager.sddm.wayland.enable = false`) with no specific symptom or
   error text recorded — unlike the CUDA finding, it reads as received wisdom rather
   than a tested result on this hardware. Do not treat the CUDA clearance as clearing
   this too. The implementing agent must separately assess current (as of
   implementation time, not this spec's authoring date) Plasma 6 + KWin Wayland +
   proprietary NVIDIA 595.x stability — cursor rendering, flicker, multi-monitor
   (DP-0 1920x1080 + DP-4 2560x1440 — note Wayland may enumerate/name these
   differently than X11's `DP-0`..`DP-5`), VRR/tearing-control behavior, and XWayland
   compatibility for Proton/Steam games — by searching for current known issues, not
   by assuming either this spec's optimism or the old comment's caution is still
   accurate.

3. **Remote-access safety is the overriding constraint.** This host is primarily
   reached over Moonlight/Sunshine. A broken or non-rendering Wayland session could
   lock out normal remote access entirely (the very thing being used to reach it).
   Before any config is switched to default-Wayland:
   - Confirm an independent recovery path exists and is tested (SSH access to
     `suspense`, and/or physical console access, and/or NixOS boot-menu generation
     rollback) *before* making Wayland the default session.
   - Make Wayland an *available* session choice at the SDDM login screen first,
     select it manually for a test login, and confirm basic stability, before
     changing `defaultSession` away from `plasmax11`.
   - Every change must be revertible via a NixOS generation rollback without needing
     the broken session itself to apply the fix.

4. **Sunshine's per-display config will need re-deriving under Wayland.**
   `output_name = "DP-4"` (in `nixos/hosts/suspense.nix`, `services.sunshine.settings`)
   is X11 connector naming. Wayland/KMS capture may enumerate or name outputs
   differently; re-derive the same way this session did for X11 — start a stream and
   read Sunshine's own `Detected display` log lines under the new session type, do not
   assume the string carries over unchanged.

5. **Everything fixed on this host so far this session must still work afterward**:
   KWin `WindowsBlockCompositing=false` (now irrelevant under Wayland but should not be
   left as dead config without a comment explaining why), the `apps.json` cleanup
   (Low Res Desktop removed), the Steam non-Steam-game shortcut for
   `fefw-recomp`'s `fefw.exe` via Proton, and NVENC preset/twopass/spatial_aq tuning
   in `services.sunshine.settings`.

## Acceptance criteria

- Moonlight-streamed fullscreen gameplay (same repro case: a terminal window behind a
  fullscreen Proton game) no longer shows stale window content bleeding into the
  stream, across a sustained play session (not just one lucky clip).
- `journalctl --user -u sunshine` shows a PipeWire/portal capture path in use, not
  `Screencasting with X11`.
- Sunshine logs `encoder=nvenc` in active use (not a software x264 fallback) for the
  stream.
- The captured display is still the 2560x1440 panel, confirmed via Sunshine's own
  `Streaming display: ... with res 2560x1440` log line (or equivalent under the new
  capture backend).
- A documented, exercised rollback path exists and was actually used at least once
  during implementation (not just theorized).
