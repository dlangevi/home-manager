# Feature reorganization implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the flake around role-based features (`base`, `dev`, `dldev`, `desktop-apps`, `gaming`, `media`), migrate user-scoped packages out of NixOS into those features, register `console` and `dance` in `machines.nix`, and ship a project-local `CLAUDE.md` documenting the split rules.

**Architecture:** Introduce one aggregator file per feature under `modules/<feature>.nix`. Fold `home.nix` and `modules/packages.nix` into `modules/base.nix`. Delete `modules/aoe2.nix` and merge its content into `modules/gaming.nix`, which also gains the AoE2 URL scripts (moved from `/etc/nixos/scripts/`). Rewire `features.nix` to point at the new modules. Update `machines.nix` with the two new hosts. Add `CLAUDE.md` at the repo root.

**Tech Stack:** Nix flakes, home-manager 25.11 (standalone), bash for the moved scripts.

**Spec:** `docs/superpowers/specs/2026-07-03-feature-reorg-design.md`

## Global Constraints

- Target home-manager release: 25.11 (unchanged; matches `flake.nix`).
- `flake.nix` uses `builtins.getEnv` for USER and HOME, so every `nix eval`, `nix build`, `nix flake check`, and `home-manager switch` invocation must pass `--impure`.
- `machines.nix` entries stay sorted alphabetically by hostname.
- No changes to `flake.nix` inputs; the `dldev` feature keeps pointing at `dldev.homeModules.default` from the existing input.
- No changes to `bootstrap`, `scripts/machines-write.nix`, or `flake.lock` as part of this plan.
- All commits describe why, not what. Concise subject lines.
- Do not modify `/etc/nixos/configuration.nix` or `/etc/nixos/scripts/*` as part of this plan — that side of the migration is documented in the plan's "Post-plan NixOS-side changes" section and is left to the user with sudo.
- The keepassxc / syncthing / neovim / zsh / tmux / git module files are re-imported from `modules/base.nix` — their content stays byte-identical.
- Package names (nixpkgs attribute paths) are used verbatim from `/etc/nixos/configuration.nix`. Do not rename or substitute.

## File Structure

Created:
- `CLAUDE.md` — project-local guidance (rules-only, four sections per spec).
- `modules/base.nix` — folds `home.nix` + `modules/packages.nix` content, imports the six existing leaf modules.
- `modules/dev.nix` — Rust/C/Python/Node toolchain packages.
- `modules/desktop-apps.nix` — GUI workstation apps.
- `modules/gaming.nix` — game runtimes + AoE2 URL handler + wrapped scripts.
- `modules/media.nix` — mpv only.
- `modules/gaming/scripts/aoe2url` — copied byte-for-byte from `/etc/nixos/scripts/aoe2url`.
- `modules/gaming/scripts/captureage` — copied byte-for-byte from `/etc/nixos/scripts/captureage`.

Modified:
- `features.nix` — replaces the catalog with the six new features.
- `machines.nix` — adds `console` and `dance` entries; `suspense`'s feature list changes.

Deleted:
- `home.nix` — content moves to `modules/base.nix`.
- `modules/packages.nix` — content splits across `modules/base.nix` (base CLI + unfree allow) and never lives anywhere else.
- `modules/aoe2.nix` — content moves to `modules/gaming.nix`.

Unchanged: `flake.nix`, `flake.lock`, `bootstrap`, `scripts/machines-write.nix`, `README.md`, `.gitignore`, and every leaf module (`zsh.nix`, `tmux.nix`, `git.nix`, `neovim.nix`, `keepassxc.nix`, `syncthing.nix`).

Rationale for task ordering: `modules/base.nix` must exist and be importable before `home.nix` and `modules/packages.nix` can be deleted (Task 1 is atomic). New feature modules (Task 2) are standalone and can be added before `features.nix` references them. The catalog swap and machines update (Task 3) is the moment when the refactor becomes "live" — activation is verified there. `CLAUDE.md` (Task 4) is documentation and lands last. Tasks 1–3 must land in order; Task 4 could theoretically ship in parallel but is grouped serially for simplicity.

---

### Task 1: Introduce `modules/base.nix` and delete `home.nix` + `modules/packages.nix`

**Files:**
- Create: `modules/base.nix`
- Delete: `home.nix`
- Delete: `modules/packages.nix`
- Modify: `features.nix` (only the `base` entry — `base = [ ./modules/base.nix ];`, replacing `base = [ ./home.nix ];`)

**Interfaces:**
- Consumes: existing leaf modules `./zsh.nix ./tmux.nix ./git.nix ./neovim.nix ./keepassxc.nix ./syncthing.nix` in `modules/`.
- Produces: `modules/base.nix`, a home-manager module that owns user identity (`home.username`, `home.homeDirectory`, `home.stateVersion`, `programs.home-manager.enable`), imports the six leaf modules, installs the baseline CLI package set, and keeps the current `nixpkgs.config.allowUnfreePredicate` for `claude-code`.

This is an atomic refactor. `home.nix` and `modules/packages.nix` cannot be deleted before `modules/base.nix` exists and `features.nix` references it, otherwise `nix flake check` fails.

- [ ] **Step 1: Create `modules/base.nix`**

Create `modules/base.nix` with exact content:

```nix
{ config, pkgs, lib, username, homeDirectory, ... }:

{
  imports = [
    ./zsh.nix
    ./tmux.nix
    ./git.nix
    ./neovim.nix
    ./keepassxc.nix
    ./syncthing.nix
  ];

  home.username = username;
  home.homeDirectory = homeDirectory;
  home.stateVersion = "25.11";

  programs.home-manager.enable = true;

  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [ "claude-code" ];

  home.packages = with pkgs; [
    ripgrep
    fd
    bat
    fzf
    zoxide
    gh
    htop
    btop
    wget
    unzip
    xclip
    cntr
    claude-code
  ];
}
```

Notes for the implementer:
- The argument list `{ config, pkgs, lib, username, homeDirectory, ... }` matches how the old `home.nix` and `modules/packages.nix` accept their arguments (`username`/`homeDirectory` come via `extraSpecialArgs` in `flake.nix`).
- The leaf module list mirrors `home.nix`'s current `imports` block plus `keepassxc.nix` and `syncthing.nix`.
- The CLI package list is `packages.nix`'s current list plus `btop`, `wget`, `unzip`, `xclip`, `cntr` (migrated from NixOS). It intentionally EXCLUDES `cargo` and `rustc` — those move to `dev.nix` in Task 2.

- [ ] **Step 2: Update `features.nix` to point `base` at the new module**

Replace `features.nix` content with:

```nix
{ dldev, ... }:
{
  base  = [ ./modules/base.nix ];
  dldev = [ dldev.homeModules.default ];
  aoe2  = [ ./modules/aoe2.nix ];
}
```

Only the `base` entry changes in this task. `dldev` and `aoe2` stay because
`machines.nix` still references them (they are cleaned up in Task 3).

- [ ] **Step 3: Delete `home.nix` and `modules/packages.nix`**

Run:
```bash
git rm home.nix modules/packages.nix
```

- [ ] **Step 4: Verify the flake still evaluates**

Run: `nix flake check --impure`

Expected: exits 0. If the evaluation fails, do NOT commit — fix the module before proceeding.

- [ ] **Step 5: Verify the activation package builds**

Run: `nix build --impure ".#homeConfigurations.\"$(hostname)\".activationPackage" --no-link --print-out-paths`

Expected: prints a `/nix/store/...` path. The activation package's content should be equivalent to the pre-refactor generation (the CLI set added `btop wget unzip xclip cntr`, but no home-manager preferences change).

- [ ] **Step 6: Commit**

```bash
git add modules/base.nix features.nix
git commit -m "refactor: fold home.nix + packages.nix into modules/base.nix"
```

Note: the `git rm` from Step 3 is already staged and included in this commit.

---

### Task 2: Add the four new feature modules

**Files:**
- Create: `modules/dev.nix`
- Create: `modules/desktop-apps.nix`
- Create: `modules/gaming.nix`
- Create: `modules/media.nix`
- Create: `modules/gaming/scripts/aoe2url` (executable bit not required at repo layer; `writeShellScriptBin` builds it into a package)
- Create: `modules/gaming/scripts/captureage`
- Delete: `modules/aoe2.nix` (content merges into `gaming.nix`)

**Interfaces:**
- Consumes: `modules/base.nix` from Task 1 must exist; leaf modules are unaffected.
- Produces: four new feature modules that can be listed in a `features.nix` catalog entry. Each is a stand-alone home-manager module taking `{ pkgs, ... }` (or `{ pkgs, config, lib, ... }` for `gaming.nix`).

No `features.nix` or `machines.nix` change here — that ships in Task 3 as a single atomic switchover.

- [ ] **Step 1: Create `modules/dev.nix`**

Create `modules/dev.nix` with exact content:

```nix
{ pkgs, ... }:

{
  home.packages = with pkgs; [
    cargo
    rustc
    rust-analyzer
    clippy
    rustfmt
    pkg-config
    gcc
    gcc14
    cmake
    gnumake
    python3
    nodejs
    yarn
  ];
}
```

- [ ] **Step 2: Create `modules/desktop-apps.nix`**

Create `modules/desktop-apps.nix` with exact content:

```nix
{ pkgs, ... }:

{
  home.packages = with pkgs; [
    spotify
    discord
    signal-desktop
    teams-for-linux
    zoom-us
    obs-studio
    gimp
    kdePackages.kdenlive
    smplayer
    mpv
    alacritty
    calibre
    filezilla
    anki-bin
    kdePackages.spectacle
    kdePackages.kdeconnect-kde
  ];
}
```

- [ ] **Step 3: Copy the AoE2 helper scripts into the repo**

Create the directory:

```bash
mkdir -p modules/gaming/scripts
```

Copy the two scripts from `/etc/nixos/scripts/`:

```bash
cp /etc/nixos/scripts/aoe2url modules/gaming/scripts/aoe2url
cp /etc/nixos/scripts/captureage modules/gaming/scripts/captureage
```

Verify byte-for-byte equality:

```bash
diff -q /etc/nixos/scripts/aoe2url modules/gaming/scripts/aoe2url
diff -q /etc/nixos/scripts/captureage modules/gaming/scripts/captureage
```

Expected: no output for both commands (files identical).

- [ ] **Step 4: Create `modules/gaming.nix`**

Create `modules/gaming.nix` with exact content:

```nix
{ pkgs, ... }:

let
  aoe2url = pkgs.writeShellScriptBin "aoe2url"
    (builtins.readFile ./gaming/scripts/aoe2url);
  captureage = pkgs.writeShellScriptBin "captureage"
    (builtins.readFile ./gaming/scripts/captureage);
in
{
  home.packages = with pkgs; [
    prismlauncher
    wine
    protontricks
    vintagestory
    osu-lazer-bin
  ] ++ [ aoe2url captureage ];

  xdg.desktopEntries.AoE2UrlHelper = {
    name = "AoE2 URL Opener";
    comment = "Play this game on Steam (Open URL)";
    exec = "aoe2url %u";
    icon = "steam_icon_813780";
    terminal = false;
    type = "Application";
    mimeType = [ "x-scheme-handler/aoe2de" ];
    categories = [ "Game" ];
  };
}
```

Note: `exec` changed from the old `/run/current-system/sw/bin/aoe2url %u` (in the pre-refactor `modules/aoe2.nix`) to just `aoe2url %u`. The script is now on the home-manager PATH, and using the absolute NixOS system path would break on non-NixOS installs.

- [ ] **Step 5: Create `modules/media.nix`**

Create `modules/media.nix` with exact content:

```nix
{ pkgs, ... }:

{
  home.packages = with pkgs; [
    mpv
  ];
}
```

- [ ] **Step 6: Delete `modules/aoe2.nix`**

Run:

```bash
git rm modules/aoe2.nix
```

- [ ] **Step 7: Verify the flake still evaluates**

Run: `nix flake check --impure`

Expected: exits 0. The new feature modules aren't referenced by `features.nix` yet, but the file being deleted (`modules/aoe2.nix`) was still listed in `features.nix` from Task 1. That reference is dangling now.

**IMPORTANT:** because the `aoe2` entry in `features.nix` still points at `./modules/aoe2.nix`, this Step 7 check will FAIL with a "path does not exist" error IF `machines.nix` has any host that includes `aoe2` in its feature list. On this branch, `suspense` currently has `[ "base" "dldev" "aoe2" ]` (from the pre-existing machines.nix — verify with `cat machines.nix`).

To satisfy the check without dragging Task 3's scope in, remove ONLY the `aoe2` reference from BOTH `features.nix` and `machines.nix`'s `suspense` entry as part of this task. That is, edit `features.nix`:

```nix
{ dldev, ... }:
{
  base  = [ ./modules/base.nix ];
  dldev = [ dldev.homeModules.default ];
}
```

And edit `machines.nix`:

```nix
{
  "suspense" = [ "base" "dldev" ];
}
```

Then re-run: `nix flake check --impure` — expected to exit 0.

- [ ] **Step 8: Verify the activation package still builds and has NOT lost the AoE2 URL handler wiring**

Wait — Step 7's edit means `suspense` no longer receives the `aoe2` feature and thus loses the AoE2 URL handler until Task 3 restores it via `gaming`. This is a *temporary* regression between Task 2 and Task 3, and it is required for atomic reviewability (Task 2's diff must stand alone).

Run: `nix build --impure ".#homeConfigurations.\"$(hostname)\".activationPackage" --no-link --print-out-paths`

Expected: prints a `/nix/store/...` path. It will NOT contain the AoE2 desktop entry. This is expected. If it does not build, fix and do NOT commit.

- [ ] **Step 9: Commit**

```bash
git add modules/dev.nix modules/desktop-apps.nix modules/gaming.nix modules/media.nix modules/gaming/scripts/aoe2url modules/gaming/scripts/captureage features.nix machines.nix
git commit -m "feat: add dev / desktop-apps / gaming / media feature modules"
```

The `git rm` from Step 6 is already staged.

---

### Task 3: Wire the new feature catalog into machines.nix

**Files:**
- Modify: `features.nix` (full rewrite: six entries)
- Modify: `machines.nix` (full rewrite: three hosts)

**Interfaces:**
- Consumes: all six feature modules from Tasks 1 and 2.
- Produces: a live per-hostname home-manager configuration for `console`, `dance`, and `suspense`, where each machine composes only the modules its feature list names.

- [ ] **Step 1: Rewrite `features.nix`**

Replace `features.nix` content with:

```nix
{ dldev, ... }:
{
  base         = [ ./modules/base.nix ];
  dev          = [ ./modules/dev.nix ];
  dldev        = [ dldev.homeModules.default ];
  desktop-apps = [ ./modules/desktop-apps.nix ];
  gaming       = [ ./modules/gaming.nix ];
  media        = [ ./modules/media.nix ];
}
```

- [ ] **Step 2: Rewrite `machines.nix`**

Replace `machines.nix` content with:

```nix
{
  "console"  = [ "base" "media" ];
  "dance"    = [ "base" ];
  "suspense" = [ "base" "dev" "dldev" "desktop-apps" "gaming" ];
}
```

Entries are alphabetically sorted by hostname (matches what `bootstrap init` would produce).

- [ ] **Step 3: Verify the flake evaluates for every registered host**

Run: `nix flake check --impure`

Expected: exits 0. This evaluates every `homeConfigurations.<hostname>`, so any typo in a feature name (e.g., `desktopapps` instead of `desktop-apps`) fails here with a "missing attribute" error naming the bad key.

- [ ] **Step 4: Build the activation package for every registered host**

Run:
```bash
nix build --impure ".#homeConfigurations.\"console\".activationPackage" --no-link --print-out-paths
nix build --impure ".#homeConfigurations.\"dance\".activationPackage" --no-link --print-out-paths
nix build --impure ".#homeConfigurations.\"suspense\".activationPackage" --no-link --print-out-paths
```

Expected: all three print a `/nix/store/...` path. If any fails (missing feature module, evaluation error, package not in nixpkgs), diagnose and fix before continuing. Do NOT commit a broken flake.

- [ ] **Step 5: Verify `suspense`'s activation package contains the migrated packages**

Run:
```bash
nix build --impure ".#homeConfigurations.\"suspense\".activationPackage" -o /tmp/hm-suspense
ls /tmp/hm-suspense/home-path/bin/ | grep -E '^(discord|spotify|mpv|aoe2url|captureage|rustc|cargo|prismlauncher|obs|gimp|smplayer|alacritty|signal-desktop|filezilla|calibre|anki|wine|protontricks|vintagestory|osu-lazer|kdeconnect-cli)' | sort
rm /tmp/hm-suspense
```

Expected: at minimum these names appear:
```
aoe2url
alacritty
cargo
captureage
discord
mpv
protontricks
rustc
spotify
wine
```

(The full list is longer; the grep above is a spot-check.) If any of the ten expected names is missing, the corresponding feature module is misconfigured.

- [ ] **Step 6: Verify the AoE2 desktop entry is in the activation package**

Run:
```bash
nix build --impure ".#homeConfigurations.\"suspense\".activationPackage" -o /tmp/hm-suspense
find /tmp/hm-suspense -name 'aoe2*.desktop' -o -name 'AoE2*.desktop'
rm /tmp/hm-suspense
```

Expected: prints at least one path ending in `.desktop` under the `home-files` tree (typically `home-files/.local/share/applications/AoE2UrlHelper.desktop`).

- [ ] **Step 7: Activate on the current machine**

Run: `home-manager switch --impure --flake ".#$(hostname)"`

Expected: activation completes successfully. Some GUI packages take a while to build the first time; that's fine.

- [ ] **Step 8: Post-activation sanity checks**

Run each and record the output in the task report:

```bash
which aoe2url
which captureage
which discord
which mpv
which rustc
ls ~/.local/share/applications/ | grep -i aoe2
```

Expected: all `which` commands print `/nix/store/...` paths (specifically the home-manager profile symlinked in), and the desktop entry lists `AoE2UrlHelper.desktop`.

- [ ] **Step 9: Commit**

```bash
git add features.nix machines.nix
git commit -m "feat: register console + dance and compose per-machine feature sets"
```

---

### Task 4: Add `CLAUDE.md` at the repo root

**Files:**
- Create: `CLAUDE.md`

**Interfaces:**
- Consumes: the finalized feature catalog from Task 3.
- Produces: project-local guidance visible to future contributors and Claude Code sessions in this repo.

- [ ] **Step 1: Create `CLAUDE.md`**

Create `CLAUDE.md` at the repo root with exact content:

````markdown
# home-manager repo guidance

This flake composes per-machine home-manager configurations from a role-based
feature catalog. Machines are registered in `machines.nix`; features live in
`features.nix` and one module per feature under `modules/`.

## 1. NixOS vs home-manager

Put a program in **NixOS** (`/etc/nixos/configuration.nix`) if any of:
- It needs root or affects other users.
- It is a systemd **system** unit.
- It touches hardware, the kernel, or graphics (X, Wayland, GPU drivers,
  audio pipelines, printer).
- It needs setuid or 32-bit libraries (Steam, containers).
- It is a system-wide service (sshd, cups, pipewire, NetworkManager,
  firewall).

Put a program in **home-manager** (this repo) if:
- It is a CLI you personally invoke.
- It is a GUI app you personally launch.
- It is a dotfile or `~/.config/*` entry.
- It is a systemd **user** service.
- It should also work on non-NixOS installs (WSL, macOS).

Split cases (Docker daemon vs `docker` CLI, `programs.steam` vs `steam-run`)
follow the same rule: daemon or hardware bit → NixOS, user-facing surface →
home-manager. If splitting buys nothing, keep it wherever it already lives.

## 2. Feature catalog

- `base` — CLI essentials (zsh, tmux, nvim, git, ripgrep, fd, bat, fzf,
  zoxide, gh, htop, btop, wget, unzip, xclip, cntr, claude-code) plus
  keepassxc and syncthing. Also owns user identity. Every machine.
- `dev` — Rust / C / Python / Node toolchains (cargo, rustc,
  rust-analyzer, gcc, cmake, python3, nodejs, yarn, etc.). Machines that
  build software.
- `dldev` — the private `agent-session` binary from
  `path:~/auto/dldev`. Only on machines where that path exists.
- `desktop-apps` — GUI workstation apps: chat (discord, signal, teams,
  zoom), media (spotify, obs, gimp, kdenlive, mpv, smplayer), utilities
  (alacritty, calibre, filezilla, anki, spectacle, kdeconnect).
- `gaming` — game runtimes (wine, protontricks, prismlauncher,
  vintagestory, osu-lazer) plus the AoE2 URL handler and its shell scripts.
- `media` — minimal streaming-box set (mpv). Firefox comes from NixOS.

Steam itself stays in NixOS as `programs.steam.enable` — 32-bit libs,
gamescope, firewall integration.

## 3. Machine registry

- `machines.nix` maps hostname (string) to a list of feature name strings.
- Entries are sorted alphabetically by hostname; `./bootstrap init`
  enforces this.
- To register a new machine: run `./bootstrap init` on that host and answer
  yes/no for each non-`base` feature. Commit the resulting change.
- To change a machine's feature list: edit `machines.nix` by hand, then
  `./bootstrap upgrade`.

## 4. Adding a new package — checklist

1. **Where does it live?** Which existing feature is the natural home?
   If none is a good fit, propose a new feature (via spec) rather than
   dumping it in `base`.
2. **Will any machine want it that doesn't already select the feature?**
   If yes, either promote to `base` or split the feature.
3. **Does it need root, a system service, hardware access, or 32-bit
   libs?** If yes, it belongs in `/etc/nixos/configuration.nix` instead.
4. **Is it already installed in NixOS?** Prefer the home-manager home
   if the package is user-scoped; remove the NixOS entry to avoid the
   duplicate.
````

- [ ] **Step 2: Verify nothing else is needed**

Run: `nix flake check --impure`

Expected: exits 0. `CLAUDE.md` is documentation and not referenced by any Nix expression, but this check confirms nothing else in the working tree drifted during Task 4.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add CLAUDE.md with NixOS/home-manager split rules"
```

---

## Post-plan NixOS-side changes (out of repo)

The following edits happen in `/etc/nixos/` and require `sudo nixos-rebuild switch`. They are **not part of this plan's tasks** — do them yourself after the plan lands, in a separate step.

- Edit `/etc/nixos/configuration.nix` and remove the following packages from `environment.systemPackages`:
  ```
  keepassxc prismlauncher vintagestory spotify discord unzip
  kdePackages.spectacle yarn git signal-desktop tmux calibre cmake wine
  protontricks anki-bin btop gnumake neovim wget ripgrep cntr filezilla
  obs-studio gimp xclip smplayer kdePackages.kdenlive osu-lazer-bin
  kdePackages.kdeconnect-kde zoom-us python3 gcc mpv teams-for-linux
  alacritty gcc14 aoe2url captureage noto-fonts-cjk-sans
  ```
- Delete from the same file: the `let aoe2url = ...; captureage = ...; in` block, and the `environment.etc."xdg/applications/aoe2url.desktop"` block.
- Delete `/etc/nixos/scripts/aoe2url` and `/etc/nixos/scripts/captureage`.
- Keep: `vim`, `gparted`, `kdePackages.partitionmanager`, `libgcc`, `steam-run`, `ollama` (with CUDA override), `steam` (verify whether `programs.steam.enable` already installs it; if so, remove).
- `programs.firefox.enable = true;` — unchanged.
- `fonts.packages` — unchanged.
- Run `sudo nixos-rebuild switch`.
- Verify no user-visible package disappeared: `which discord mpv aoe2url rustc` should all resolve, now pointing at home-manager's profile instead of `/run/current-system/sw/`.

## Self-Review Notes

- **Spec coverage:**
  - Architecture (spec §Architecture) → covered by the file-structure plan and Tasks 1–3.
  - `features.nix` shape (spec §Component: features.nix) → Task 3 Step 1.
  - `machines.nix` shape (spec §Component: machines.nix) → Task 3 Step 2.
  - `modules/base.nix` (spec §Component: modules/base.nix) → Task 1 Step 1.
  - `modules/dev.nix` (spec) → Task 2 Step 1.
  - `modules/desktop-apps.nix` (spec) → Task 2 Step 2.
  - `modules/gaming.nix` incl. moved scripts + desktop entry with new `exec = "aoe2url %u"` (spec §Component: modules/gaming.nix) → Task 2 Steps 3, 4.
  - `modules/media.nix` (spec) → Task 2 Step 5.
  - Deletion of `home.nix`, `modules/packages.nix`, `modules/aoe2.nix` → Task 1 Step 3, Task 2 Step 6.
  - NixOS-side changes → Post-plan section (explicitly out of task scope, as required by the plan constraints prohibiting `/etc/nixos/` edits).
  - `CLAUDE.md` (spec §Component: CLAUDE.md) → Task 4 Step 1.
  - Verification steps from spec → Task 3 Steps 3–8 and Task 4 Step 2.

- **Placeholder scan:** no TBD / TODO / "later" / "handle edge cases" language. Task 2 Steps 7–8 explicitly acknowledge a temporary between-task regression (`suspense` loses the AoE2 desktop entry between Task 2 and Task 3) but that is a stated design choice, not a placeholder.

- **Type consistency:** feature name strings (`base`, `dev`, `dldev`, `desktop-apps`, `gaming`, `media`) match between `features.nix` (Task 3 Step 1) and `machines.nix` (Task 3 Step 2). Module argument shapes:
  - `modules/base.nix` uses `{ config, pkgs, lib, username, homeDirectory, ... }` — matches how `home.nix` currently accepts these plus what `modules/packages.nix` needs.
  - `modules/dev.nix`, `modules/desktop-apps.nix`, `modules/media.nix` use `{ pkgs, ... }`.
  - `modules/gaming.nix` uses `{ pkgs, ... }` because the `let ... in` block only needs `pkgs.writeShellScriptBin`.
