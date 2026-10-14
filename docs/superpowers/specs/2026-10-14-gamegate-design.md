# gamegate — Screen Zen-style friction on game launches (suspense)

**Status: designed, not implemented.** Parked on 2026-10-14 for a later pass.

## Context

The goal is to raise the barrier to playing video games on `suspense` so the
default action becomes something else — not to make gaming impossible. Screen
Zen's model, ported to the desktop: a delay-and-state-your-reason prompt before
a game starts, a daily time budget, and a blackout window before evening.

Decisions already made:

- **Target**: games first (Steam + the non-Steam titles in `modules/gaming.nix`).
  Browser distraction is a secondary, non-Nix step (see Out of scope).
- **Friction**: 30s delay + typed reason, 90 min/day, blackout before 18:00,
  same every day.
- **Budget exhaustion**: warn, then terminate after a grace period.
- **Bypass**: honest speed bump. A documented, tedious, logged escape hatch
  (`gamegate grant`) rather than anything that pretends to be secure.

Two risks worth naming up front, both accepted as specified:

1. SIGTERM on a Steam game is effectively a kill — most Proton titles do not
   handle it, so an in-progress match or unsaved run is lost. The plan gives a
   5-minute warned grace window and SIGTERM-then-SIGKILL rather than an abrupt
   cut, but the risk does not go away.
2. Gating *launch* alone is dodgeable by leaving Steam open all day. The budget
   watcher is what closes that hole, which is why both halves are in scope.

## Facts this design rests on (verified)

- `steam.desktop` comes from the **system** profile
  (`/run/current-system/sw/share/applications/`), and `steam` resolves only to
  `/run/current-system/sw/bin/steam`. Nothing in the home profile provides
  either, so a home-level shim and a home-level `steam.desktop` shadow them
  cleanly with no collision.
- The non-Steam games ship their own desktop entries **into the home profile**
  (`osu!.desktop`, `vintagestory.desktop`, `dev.eden_emu.eden.desktop`,
  `io.mgba.mGBA.desktop`, `com.github.Alcaro.Flips.desktop`, prismlauncher).
  Declaring `xdg.desktopEntries` with those same filenames would *collide*, not
  override — so these get wrapped at the package level instead.
- Steam launches every game through `reaper SteamLaunch AppId=<id> -- …`, so a
  `/proc` scan for that substring identifies a running Steam game and its appid
  without any Steam API.
- Rust crates in this repo are built by `mkRustPkg` in `flake.nix` (see
  `dlsysPkg` at `flake.nix:105`, `snapctlPkg` at `flake.nix:113`), threaded into
  modules as a module argument (`modules/snapclient.nix:10` takes `snapctl`).
- `pkgs.zenity` is already used by `modules/streaming.nix:10`; `libnotify` is not
  yet in any module.

## Step 0 — before implementing

Re-check contention (`git worktree list`, dirty tree, other live sessions). At
the time of writing a `feat/jpcc-preview` worktree existed, which would call for
`EnterWorktree`; that may no longer hold. Land by merging to local `main` on
green; do not push.

## The crate — `crates/gamegate`

One binary, added to the existing cargo workspace (`Cargo.toml` at repo root
already lists `crates/*`). Four subcommands.

### `gamegate run --config <toml> -- <cmd> [args…]`

The synchronous gate. In order:

1. Load config and today's state.
2. **Blackout check** — if now falls in a blocked window, show a zenity dialog
   naming when it lifts, with "Not now" and "Override". Override requires typing
   a fixed sentence verbatim; the override is appended to today's log.
3. **Budget check** — same dialog shape if `used_seconds >= budget_seconds`.
4. **Intention prompt** — `zenity --entry` asking why, rejecting anything under
   ~15 characters; then a non-cancellable `zenity --progress` 30s countdown.
5. Append a launch record (timestamp, label, reason) to state, then `exec` the
   real command so the gate leaves no process behind.

### `gamegate watch --config <toml>`

A systemd **user** service (`WantedBy = graphical-session.target`), following the
unit style already in `modules/documents.nix`. Every 10s:

- Scan `/proc/*/cmdline`. A Steam game is any cmdline containing
  `SteamLaunch AppId=`, labelled by the extracted appid. Non-Steam games match a
  configurable list of cmdline substrings (`osu!`, `Vintagestory`, `eden`,
  `mGBA`, prismlauncher's java child — substring matching, not basename, because
  the java child's argv0 is useless).
- If anything matched, add the tick interval to `used_seconds` for that label.
- `notify-send` warnings at 10 min and 2 min remaining.
- At zero (or on entering a blackout window with a game running): notify
  "closing in 5 minutes", then after the grace window SIGTERM each matched
  process group, and SIGKILL anything still alive 60s later.

### `gamegate status [--json]`

Today's usage per label, remaining budget, next blackout boundary. Makes the
whole thing inspectable from the shell and is the first thing to check when
something misbehaves.

### `gamegate grant --minutes N --reason <text>`

The escape hatch. Adds to today's budget; reason is mandatory and logged.
Negative values allowed, which is also how the budget path gets tested.

### State and concurrency

`~/.local/state/gamegate/YYYY-MM-DD.json` — per-label seconds, launch count,
grants, and the launch/override log. Both `run` and `watch` write it, so take an
advisory `flock` on the file and write via temp-file + rename.

### Testability

Keep `/proc` reading, the clock, and the dialogs behind small traits so the
logic under test needs no display and no games. Unit tests cover: blackout
window evaluation (including a window that wraps midnight), budget arithmetic
with grants, state round-trip, and `SteamLaunch AppId=` extraction from fixture
cmdline strings.

## The Nix side

### `flake.nix`

Add a `gamegatePkg = mkRustPkg { pname = "gamegate"; … }` next to `snapctlPkg`,
expose it in `packages` (so `nix run .#gamegate -- status` works without a
switch) and thread it into the module args alongside `dlsys` and `snapctl`.

### `modules/gamegate.nix`

Config as a Nix attrset rendered through `(pkgs.formats.toml {}).generate` —
budget minutes, blackout windows, delay seconds, watched cmdline substrings, the
override sentence. The store path is baked into every wrapper's `--config`, so
there is no env var to forget.

Two wrapping strategies, because the two cases differ:

- **Steam** (system package): a `pkgs.writeShellScriptBin "steam"` in
  `home.packages` that execs `gamegate run -- /run/current-system/sw/bin/steam
  "$@"` (absolute path, so no shim recursion), plus an
  `xdg.desktopEntries.steam` mirroring the system entry's Name/Icon/Categories
  with the gated Exec.
- **Home-profile games**: a `gateApp` helper using `symlinkJoin` + `makeWrapper`
  to replace each `bin/<exe>` with a gated wrapper, **and** `substituteInPlace`
  on the joined `share/applications/*.desktop` so the Exec lines point at the
  wrapper rather than the original store path. Replace the raw packages in
  `modules/gaming.nix`'s `home.packages` with their gated versions.

Also in the module: `pkgs.zenity`, `pkgs.libnotify`, and the
`systemd.user.services.gamegate-watch` unit.

### `features.nix` / `machines.nix`

New `gamegate` feature mapping to `[ ./modules/gamegate.nix ]`; add it to
`suspense` only. `console` also has `programs.steam` enabled but is not a target
here.

## Out of scope (do not build)

- **Browser blocking.** The right tool for Floorp is the LeechBlock NG
  extension — schedules, time limits, a delay page, password-protected lockdown.
  Its settings live in the browser profile and are not declaratively
  manageable without introducing `programs.floorp` profile management, which
  would clobber the existing profile. Install and configure it by hand; this is
  a one-line recommendation, not a work item.
- Any attempt to make the gate tamper-resistant.

## Verification

```sh
# in the devShell
cargo test -p gamegate

# build before switching
NIXPKGS_ALLOW_UNFREE=1 nix build --impure \
  ".#homeConfigurations.\"$(hostname)\".activationPackage"
dlsys switch hm
```

Then, end to end on suspense:

1. `gamegate status --json` — prints a fresh day, 90 min remaining, next
   blackout boundary at 18:00.
2. `systemctl --user status gamegate-watch` — running.
3. Launch osu! from the Plasma menu before 18:00 → blackout dialog appears,
   nothing starts. Override with the sentence → it starts, and the override is
   in today's log.
4. Launch again after 18:00 → reason prompt, 30s countdown, then the game.
5. With osu! running, `gamegate status` after ~1 min shows accumulated seconds
   against its label; launch a Steam game and confirm it is labelled by appid.
6. `gamegate grant --minutes -88 --reason "testing termination"` with a game
   running → warning notifications fire, then the 5-minute grace, then the game
   exits. Use a throwaway title for this step, not something mid-save.
7. `gamegate grant --minutes 30 --reason "testing grant"` → status reflects it.

Commit on the worktree branch, merge to local `main`, do not push.
