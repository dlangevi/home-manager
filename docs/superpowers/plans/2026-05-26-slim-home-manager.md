# Slim home-manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move GUI / gaming / machine-specific packages out of home-manager and into `/etc/nixos/configuration.nix` on the NixOS host. Leave home-manager carrying only portable user config and core CLI.

**Architecture:** Pure refactor. Edit `modules/packages.nix`, delete `modules/desktop.nix` and `scripts/`, fold one env var into `modules/zsh.nix`, drop import from `home.nix`. On the NixOS side, append packages + AoE2 integration (scripts wrapped via `writeShellScriptBin` reading from `./scripts/`, desktop entry via `environment.etc`).

**Tech Stack:** Nix, home-manager (standalone, channels), NixOS.

**Verification model:** This is config code with no test framework. Verification = `home-manager switch` and `nixos-rebuild switch` succeed, plus a runtime smoke check that the AoE2 URL handler still fires.

---

## File Structure

**home-manager repo (`/home/dlangevi/.config/home-manager`):**
- Modify: `modules/packages.nix` — slim package list, drop `allowUnfree`
- Modify: `modules/zsh.nix` — add `home.sessionVariables.EDITOR = "nvim"`
- Modify: `home.nix` — drop `desktop.nix` import
- Modify: `README.md` — update Structure section
- Delete: `modules/desktop.nix`
- Delete: `scripts/aoe2url`, `scripts/captureage`, `scripts/` directory

**NixOS config (`/etc/nixos/`):**
- Modify: `configuration.nix` — add packages, add AoE2 wiring
- Create: `/etc/nixos/scripts/aoe2url` (copied from home-manager repo)
- Create: `/etc/nixos/scripts/captureage` (copied from home-manager repo)

---

### Task 1: Copy AoE2 scripts to /etc/nixos before deletion

We need the script contents preserved at the NixOS location before we delete them from this repo.

**Files:**
- Create: `/etc/nixos/scripts/aoe2url`
- Create: `/etc/nixos/scripts/captureage`

- [ ] **Step 1: Create scripts directory under /etc/nixos**

Run: `sudo mkdir -p /etc/nixos/scripts`

- [ ] **Step 2: Copy scripts**

Run:
```bash
sudo cp /home/dlangevi/.config/home-manager/scripts/aoe2url /etc/nixos/scripts/aoe2url
sudo cp /home/dlangevi/.config/home-manager/scripts/captureage /etc/nixos/scripts/captureage
sudo chmod +x /etc/nixos/scripts/aoe2url /etc/nixos/scripts/captureage
```

- [ ] **Step 3: Verify contents match**

Run:
```bash
diff /home/dlangevi/.config/home-manager/scripts/aoe2url /etc/nixos/scripts/aoe2url
diff /home/dlangevi/.config/home-manager/scripts/captureage /etc/nixos/scripts/captureage
```
Expected: no output (files identical).

---

### Task 2: Update /etc/nixos/configuration.nix — add packages and AoE2 integration

**Files:**
- Modify: `/etc/nixos/configuration.nix`

- [ ] **Step 1: Add `prismlauncher`, `vintagestory`, `spotify`, `keepassxc` to `environment.systemPackages`**

In `environment.systemPackages = with pkgs; [ ... ]` (line ~174-221 of the existing file), append:

```nix
    prismlauncher
    vintagestory
    spotify
    keepassxc
```

Also remove the existing `keepass` line in that list (user prefers keepassxc).

- [ ] **Step 2: Add AoE2 script wrappers via `let` binding at top of attrset**

At the top of the outer attribute set (right after the module signature `{ config, pkgs, lib, ... }:`), restructure to use `let ... in`:

```nix
{ config, pkgs, lib, ... }:

let
  aoe2url = pkgs.writeShellScriptBin "aoe2url"
    (builtins.readFile ./scripts/aoe2url);
  captureage = pkgs.writeShellScriptBin "captureage"
    (builtins.readFile ./scripts/captureage);
in
{
  imports =
    [ ./hardware-configuration.nix ];

  # ... rest of existing config unchanged ...
}
```

- [ ] **Step 3: Add the wrapper packages to `environment.systemPackages`**

In the same `environment.systemPackages` list, append:

```nix
    aoe2url
    captureage
```

- [ ] **Step 4: Add the AoE2 desktop entry via `environment.etc`**

Add anywhere in the top-level attrset (e.g. just before `system.stateVersion`):

```nix
  environment.etc."xdg/applications/aoe2url.desktop".text = ''
    [Desktop Entry]
    Name=AOE2 URL Handler
    Exec=aoe2url %u
    Terminal=false
    Type=Application
    MimeType=x-scheme-handler/aoe2de;
  '';
```

- [ ] **Step 5: Validate the file parses**

Run: `sudo nix-instantiate --parse /etc/nixos/configuration.nix > /dev/null`
Expected: exit 0, no output.

- [ ] **Step 6: Rebuild NixOS**

Run: `sudo nixos-rebuild switch`
Expected: build succeeds, generation activated. If it fails, read the error and fix before proceeding.

- [ ] **Step 7: Smoke-test the new tools exist**

Run:
```bash
which prismlauncher vintagestory spotify keepassxc aoe2url captureage
```
Expected: all resolve under `/run/current-system/sw/bin/` (or similar nix store path via the system profile).

- [ ] **Step 8: Smoke-test the AoE2 mime handler**

Run:
```bash
xdg-mime query default x-scheme-handler/aoe2de
```
Expected: `aoe2url.desktop`.

(If this returns something else or empty, the desktop file isn't being picked up. Re-check `/etc/xdg/applications/aoe2url.desktop` exists and that the mime line is correct. As a fallback, also set `xdg.mime.defaultApplications."x-scheme-handler/aoe2de" = "aoe2url.desktop";` at the NixOS level.)

---

### Task 3: Slim modules/packages.nix in home-manager

**Files:**
- Modify: `/home/dlangevi/.config/home-manager/modules/packages.nix`

- [ ] **Step 1: Replace file contents**

Final contents:

```nix
{ pkgs, ... }:

{
  home.packages = with pkgs; [
    ripgrep
    fd
    bat
    fzf
    zoxide
    gh
    htop
    claude-code
  ];
}
```

(Removes: all GUI apps, gaming, media tools, and the `nixpkgs.config.allowUnfree = true;` line — none of the remaining packages need unfree.)

---

### Task 4: Move EDITOR session var into zsh.nix

**Files:**
- Modify: `/home/dlangevi/.config/home-manager/modules/zsh.nix`

- [ ] **Step 1: Read current zsh.nix**

Run: `cat /home/dlangevi/.config/home-manager/modules/zsh.nix`

- [ ] **Step 2: Add `home.sessionVariables.EDITOR = "nvim";` to the attrset**

Inside the top-level attribute set of the file, add:

```nix
  home.sessionVariables.EDITOR = "nvim";
```

(Place it near the top of the attrset, above the `programs.zsh` block. If `home.sessionVariables` already exists, add `EDITOR = "nvim";` to that attrset instead of duplicating.)

---

### Task 5: Remove desktop.nix import and delete file + scripts dir

**Files:**
- Modify: `/home/dlangevi/.config/home-manager/home.nix`
- Delete: `/home/dlangevi/.config/home-manager/modules/desktop.nix`
- Delete: `/home/dlangevi/.config/home-manager/scripts/` (directory and contents)

- [ ] **Step 1: Remove the `./modules/desktop.nix` line from `home.nix`**

After edit, `home.nix` imports should read:

```nix
  imports = [
    ./modules/packages.nix
    ./modules/zsh.nix
    ./modules/tmux.nix
    ./modules/git.nix
    ./modules/neovim.nix
  ];
```

- [ ] **Step 2: Delete the desktop module and scripts directory**

Run:
```bash
rm /home/dlangevi/.config/home-manager/modules/desktop.nix
rm -r /home/dlangevi/.config/home-manager/scripts
```

---

### Task 6: Update README to match new structure

**Files:**
- Modify: `/home/dlangevi/.config/home-manager/README.md`

- [ ] **Step 1: Update the Structure section**

Replace lines 7-19 (the ``` code block describing layout) with:

```
home.nix              # Entry point — imports all modules
modules/
  packages.nix        # Portable CLI tools (ripgrep, fd, bat, fzf, zoxide, gh, htop, claude-code)
  zsh.nix             # Zsh + oh-my-zsh + fzf + EDITOR env var
  tmux.nix            # Tmux (nix-native, no TPM)
  git.nix             # Git + GitHub CLI
  neovim.nix          # Neovim + auto-clone config from github.com/dlangevi/nvim
```

Also delete the step in step-6 of WSL setup that mentions "Symlink custom scripts into `~/.local/bin/`" — that's no longer accurate.

---

### Task 7: Apply home-manager and verify

**Files:** none

- [ ] **Step 1: Run home-manager switch**

Run: `home-manager switch`
Expected: build succeeds, new generation activated. If it fails, read the error and fix before proceeding.

- [ ] **Step 2: Verify home-manager profile no longer contains GUI apps**

Run:
```bash
ls ~/.nix-profile/bin/ | grep -E '^(discord|signal-desktop|gimp|spotify|prismlauncher|vintagestory|alacritty|mpv)$' || echo "clean"
```
Expected: `clean` (none of those are in the home-manager profile anymore).

- [ ] **Step 3: Verify those apps still work — sourced from the system profile**

Run:
```bash
which discord signal-desktop spotify prismlauncher vintagestory keepassxc
```
Expected: all resolve under `/run/current-system/sw/bin/`.

- [ ] **Step 4: Verify core CLI still works (still home-manager)**

Run:
```bash
which rg fd bat fzf zoxide gh htop claude
```
Expected: all resolve under `~/.nix-profile/bin/` (or `/etc/profiles/per-user/dlangevi/bin/`).

- [ ] **Step 5: Verify EDITOR is set**

Run: `echo "$EDITOR"` in a fresh shell.
Expected: `nvim`.

- [ ] **Step 6: Smoke-test AoE2 URL handler end-to-end**

Either click an `aoe2de://` link in a browser, or run:
```bash
xdg-open 'aoe2de://test'
```
Expected: `aoe2url` is invoked (you'll see Steam/Proton activity; for a dummy URL it may error inside Proton — that's fine, we just want to confirm the handler dispatches).

---

### Task 8: Commit home-manager changes

**Files:** none (commit only)

- [ ] **Step 1: Review the diff**

Run:
```bash
cd /home/dlangevi/.config/home-manager
git status
git diff
```

- [ ] **Step 2: Stage and commit**

Run:
```bash
git add modules/packages.nix modules/zsh.nix home.nix README.md
git add -u modules/desktop.nix scripts/
git commit -m "$(cat <<'EOF'
Slim home-manager: move GUI/gaming packages to NixOS system config

Drop duplicates already in /etc/nixos and machine-specific apps from
home-manager. Keeps only portable CLI (ripgrep, fd, bat, fzf, zoxide,
gh, htop, claude-code). AoE2 integration and gaming packages live in
/etc/nixos/configuration.nix now.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3: Confirm clean tree**

Run: `git status`
Expected: working tree clean.

---

## Notes on the NixOS-side commit

`/etc/nixos/configuration.nix` may or may not be under version control. If it is (e.g. you keep `/etc/nixos` in a git repo), commit those changes separately there. If not, that's the user's call — out of scope for this plan.
