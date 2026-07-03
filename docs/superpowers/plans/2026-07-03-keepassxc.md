# KeePassXC + Syncthing Home-Manager Integration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add KeePassXC as a declaratively-managed password manager across every home-manager profile, with the `.kdbx` database synced between machines via a self-hosted Syncthing daemon that is also managed by home-manager.

**Architecture:** Two new, decoupled modules under `modules/`: `keepassxc.nix` installs the KeePassXC package (GUI + CLI), and `syncthing.nix` enables the Syncthing user daemon and declares a single sync folder at `~/Sync/keepassxc/`. Both modules are imported from `home.nix` so all three profiles (base, dev, personal) receive them.

**Tech Stack:** Nix flakes, home-manager 25.11, `pkgs.keepassxc`, home-manager `services.syncthing` module.

**Spec:** `docs/superpowers/specs/2026-07-03-keepassxc-design.md`

## Global Constraints

- Target home-manager release: 25.11 (from `flake.nix`, unchanged).
- Modules must be pure Nix — no `import <nixpkgs>`, `builtins.fetchurl`, or impure paths.
- `nix flake check` must exit 0 after every task.
- Do not manage `~/.config/keepassxc/keepassxc.ini`. KeePassXC preferences remain imperative state.
- Do not populate Syncthing `devices` or folder `devices` lists declaratively — those are configured via the web UI.
- `services.syncthing.overrideDevices = false` and `services.syncthing.overrideFolders = false`.
- Sync folder path convention: `~/Sync/keepassxc/`, folder id `keepassxc-db`.
- All modules must be importable from `home.nix` and take a `{ pkgs, ... }` (or `{ config, pkgs, ... }` if needed) argument matching the existing module style in `modules/`.
- Commit messages: concise, describe why not what (per `~/.claude/CLAUDE.md`).

## File Structure

Files created:

- `modules/keepassxc.nix` — installs the `keepassxc` package. Single responsibility: make the KeePassXC GUI and `keepassxc-cli` available on the user's PATH.
- `modules/syncthing.nix` — enables the Syncthing user service and declares the `keepassxc-db` folder. Single responsibility: provide a synced folder for the password database (and, in principle, other future synced content).

Files modified:

- `home.nix` — add the two new imports alongside the existing five.

Files unchanged:

- `flake.nix`, `flake.lock`, `modules/packages.nix`, `modules/zsh.nix`, `modules/tmux.nix`, `modules/git.nix`, `modules/neovim.nix`, `modules/aoe2.nix`.

---

### Task 1: Add `modules/keepassxc.nix`

**Files:**
- Create: `modules/keepassxc.nix`

**Interfaces:**
- Consumes: none.
- Produces: a home-manager module that, when imported, adds `pkgs.keepassxc` to `home.packages`.

- [ ] **Step 1: Create the module file**

Create `modules/keepassxc.nix` with the following exact content:

```nix
{ pkgs, ... }:

{
  home.packages = with pkgs; [
    keepassxc
  ];
}
```

- [ ] **Step 2: Verify the module parses**

Run: `nix flake check`
Expected: exits 0 with no errors. (The module is not imported yet, so this only confirms flake-level validity is preserved.)

- [ ] **Step 3: Commit**

```bash
git add modules/keepassxc.nix
git commit -m "feat(keepassxc): add module installing the GUI + CLI"
```

---

### Task 2: Add `modules/syncthing.nix`

**Files:**
- Create: `modules/syncthing.nix`

**Interfaces:**
- Consumes: none.
- Produces: a home-manager module that enables the Syncthing user daemon and declares a single folder `keepassxc-db` at `~/Sync/keepassxc/`.

- [ ] **Step 1: Create the module file**

Create `modules/syncthing.nix` with the following exact content:

```nix
{ config, ... }:

{
  services.syncthing = {
    enable = true;
    overrideDevices = false;
    overrideFolders = false;
    settings.folders."keepassxc-db" = {
      path = "${config.home.homeDirectory}/Sync/keepassxc";
      devices = [ ];
    };
  };
}
```

Notes for the implementer:
- `${config.home.homeDirectory}` evaluates to `/home/dlangevi` on this machine and stays portable across other machines.
- `devices = [ ]` is deliberate — peers are added via the web UI at `localhost:8384` after activation.
- No `settings.devices` block is declared; keeping the top-level devices list empty in Nix means the web UI is the sole source of truth for device IDs.

- [ ] **Step 2: Verify the module parses**

Run: `nix flake check`
Expected: exits 0 with no errors. (Still not imported.)

- [ ] **Step 3: Commit**

```bash
git add modules/syncthing.nix
git commit -m "feat(syncthing): add module with keepassxc-db sync folder"
```

---

### Task 3: Wire both modules into `home.nix`

**Files:**
- Modify: `home.nix`

**Interfaces:**
- Consumes: `modules/keepassxc.nix` and `modules/syncthing.nix` from Tasks 1 and 2.
- Produces: an updated `home.nix` that imports both new modules alongside the existing five.

- [ ] **Step 1: Add both imports**

Modify `home.nix` so the `imports` list reads exactly:

```nix
  imports = [
    ./modules/packages.nix
    ./modules/zsh.nix
    ./modules/tmux.nix
    ./modules/git.nix
    ./modules/neovim.nix
    ./modules/keepassxc.nix
    ./modules/syncthing.nix
  ];
```

Leave the rest of the file (username, homeDirectory, stateVersion, `programs.home-manager.enable`) unchanged.

- [ ] **Step 2: Validate the flake**

Run: `nix flake check`
Expected: exits 0 with no errors.

- [ ] **Step 3: Build the base profile without activating**

Run: `home-manager build --flake .#base`
Expected: builds successfully; a `result` symlink appears. Confirms every profile evaluates.

- [ ] **Step 4: Verify keepassxc and syncthing are in the built profile**

Run: `ls result/home-path/bin/ | grep -E '^(keepassxc|syncthing)'`
Expected output includes at minimum:
```
keepassxc
keepassxc-cli
syncthing
```

If any of those is missing, stop and diagnose before continuing.

- [ ] **Step 5: Activate the current profile**

Determine which profile is active on this machine (`personal` per the flake for this environment, but confirm before running) and activate it:

Run: `home-manager switch --flake .#personal`
Expected: activation succeeds; systemd user services are (re)loaded.

If the active profile on your machine is `dev` or `base`, substitute accordingly. Only activate the profile that is already in use here — do not switch profiles.

- [ ] **Step 6: Verify runtime state**

Run each and check expected output:

```bash
command -v keepassxc
```
Expected: prints a path under `/nix/store/.../bin/keepassxc`.

```bash
command -v keepassxc-cli
```
Expected: prints a path under `/nix/store/.../bin/keepassxc-cli`.

```bash
systemctl --user status syncthing
```
Expected: unit shows `active (running)`. If it shows `activating`, wait a few seconds and retry.

```bash
curl -sf http://localhost:8384 >/dev/null && echo OK
```
Expected: prints `OK`. Syncthing's web UI is responding.

- [ ] **Step 7: Commit**

```bash
git add home.nix
git commit -m "feat: enable KeePassXC and Syncthing on every profile"
```

---

## Post-plan manual steps (not part of the automated plan)

These are done by the user, outside of any task, once the plan is complete:

1. Open `http://localhost:8384` in a browser. If prompted, set an admin username/password for the Syncthing web UI.
2. On the *first* machine: open KeePassXC and create a new database at `~/Sync/keepassxc/passwords.kdbx` with a master password.
3. On *subsequent* machines: use the Syncthing web UI to pair with an existing peer (exchange device IDs), accept the `keepassxc-db` folder share, wait for the `.kdbx` file to sync, then open it in KeePassXC.

## Self-Review Notes

- **Spec coverage:** each spec section is covered — Architecture (Tasks 1–3), Component keepassxc.nix (Task 1), Component syncthing.nix (Task 2), Data flow / Bootstrap flow (post-plan manual steps), Placement in the flake (Task 3), Verification (Task 3 Steps 2–6). Risks and trade-offs are informational, not implementation work.
- **Placeholder scan:** no TBDs, TODOs, or "similar to earlier task" references. Every code block is complete and copy-pasteable.
- **Type consistency:** folder id `keepassxc-db` and path `~/Sync/keepassxc/` are used identically in Task 2 and in the verification steps. Module argument shapes (`{ pkgs, ... }` for `keepassxc.nix`, `{ config, ... }` for `syncthing.nix`) match how the modules use their arguments.
