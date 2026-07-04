# Feature reorganization and NixOS→home-manager migration

## Purpose

Reshape the home-manager repo around **role-based features** so that three
machines (`suspense`, `dance`, `console`) can compose distinct sets of tools
from a shared catalog. Migrate user-scoped packages out of NixOS
`environment.systemPackages` into home-manager features so they follow the
same declarative deployment path. Document the split rules in a project-local
`CLAUDE.md` for future package additions.

## Non-goals

- **Moving `/etc/nixos/configuration.nix` into this flake.** Each machine
  keeps its own NixOS system config; only the packages that belong in
  home-manager move.
- **Configuring itgmania (dance) or media playback (console) at the NixOS
  level.** Those are separate NixOS system-config tasks.
- **Rewriting existing module files** (`zsh.nix`, `tmux.nix`, `git.nix`,
  `neovim.nix`, `keepassxc.nix`, `syncthing.nix`). Their content stays; only
  the import path changes.
- **Firefox migration.** Firefox stays in NixOS as
  `programs.firefox.enable = true;` — the module handles MIME registration
  and system integration.
- **Ollama migration.** Ollama stays in NixOS to preserve its CUDA
  acceleration override.
- **New feature axes** beyond role-based. `dev`/`gaming`/`media`/etc. are
  the vocabulary going forward.

## Architecture

Six features in a role-based catalog, one aggregator module per feature,
one file per machine's composition.

```
CLAUDE.md              (new — project-local guidance)
flake.nix              (unchanged)
features.nix           (rewired: new feature list, points at new modules)
machines.nix           (adds console + dance entries)

modules/
  base.nix             (new — aggregator; imports the leaf modules and
                        owns user identity + baseline CLI packages)
  dev.nix              (new — Rust + C + Python + Node toolchain)
  desktop-apps.nix     (new — GUI apps for a workstation)
  gaming.nix           (new — game runtimes + AoE2 URL handler)
  media.nix            (new — mpv-focused streaming box needs)
  gaming/
    scripts/
      aoe2url          (moved from /etc/nixos/scripts/)
      captureage       (moved from /etc/nixos/scripts/)

  # unchanged content, but now imported from modules/base.nix
  # instead of home.nix:
  zsh.nix
  tmux.nix
  git.nix
  neovim.nix
  keepassxc.nix
  syncthing.nix

home.nix               (DELETED — content moves into modules/base.nix)
modules/aoe2.nix       (DELETED — content merges into modules/gaming.nix)
modules/packages.nix   (DELETED — split into feature modules)
```

## Component: `features.nix`

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

Feature naming rule: kebab-case, role-oriented, one word if possible.

## Component: `machines.nix`

Full post-migration content:

```nix
{
  "console"  = [ "base" "media" ];
  "dance"    = [ "base" ];
  "suspense" = [ "base" "dev" "dldev" "desktop-apps" "gaming" ];
}
```

Sorted alphabetically by hostname. `bootstrap init` already enforces this
ordering, so hand-edits should follow suit.

Note: `dance` intentionally gets only `base` — the itgmania install itself
is a NixOS-level concern for that machine, not a home-manager feature.

## Component: `modules/base.nix`

Aggregator. Every machine loads exactly this feature.

Responsibilities (folded together from the deleted `home.nix` and
`modules/packages.nix`):

1. **User identity** — `home.username`, `home.homeDirectory`,
   `home.stateVersion = "25.11"`, `programs.home-manager.enable = true`.
   The `username`/`homeDirectory` values continue to come from
   `extraSpecialArgs` (populated by `builtins.getEnv` in `flake.nix`).
2. **Leaf module imports** — imports the six existing leaf modules:
   `./zsh.nix`, `./tmux.nix`, `./git.nix`, `./neovim.nix`,
   `./keepassxc.nix`, `./syncthing.nix`.
3. **Baseline CLI packages** — `home.packages` gets:
   `ripgrep`, `fd`, `bat`, `fzf`, `zoxide`, `gh`, `htop`, `btop`, `wget`,
   `unzip`, `xclip`, `cntr`, `claude-code`.
4. **Unfree allowance** — retains the current predicate:
   `nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "claude-code" ];`

`home.nix` is deleted after this file exists.

## Component: `modules/dev.nix`

```
cargo rustc rust-analyzer clippy rustfmt pkg-config
gcc gcc14 cmake gnumake
python3
nodejs yarn
```

All installed via `home.packages`. No `programs.*` module wiring — these
are tools invoked from the shell, not configured.

## Component: `modules/desktop-apps.nix`

```
spotify discord signal-desktop teams-for-linux zoom-us
obs-studio gimp kdePackages.kdenlive smplayer mpv
alacritty
calibre filezilla anki-bin
kdePackages.spectacle kdePackages.kdeconnect-kde
```

Note `mpv` intentionally lives here AND in `media` (via feature
composition, both machines that want it get it via their own feature).
Duplicate packages across features are deduplicated by Nix at the
`concatMap` step in `flake.nix`.

## Component: `modules/gaming.nix`

Contents:

1. `home.packages`: `prismlauncher wine protontricks vintagestory osu-lazer-bin`.
2. Two script-wrapping derivations:
   ```nix
   let
     aoe2url    = pkgs.writeShellScriptBin "aoe2url"
                    (builtins.readFile ./gaming/scripts/aoe2url);
     captureage = pkgs.writeShellScriptBin "captureage"
                    (builtins.readFile ./gaming/scripts/captureage);
   in
   {
     home.packages = [ ... aoe2url captureage ];
     ...
   }
   ```
3. Desktop entry (moved from `modules/aoe2.nix`):
   ```nix
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
   ```
   Note: `exec` changed from the previous
   `/run/current-system/sw/bin/aoe2url %u` to just `aoe2url %u` — home-manager
   installs the script into the user's PATH, so absolute path is unnecessary
   and would break portability.

The script files (`aoe2url`, `captureage`) are copied byte-for-byte from
`/etc/nixos/scripts/`.

`modules/aoe2.nix` is deleted after this file exists.

## Component: `modules/media.nix`

```
mpv
```

Deliberately minimal. Firefox is expected to come from NixOS via
`programs.firefox.enable` on any machine where a browser is wanted; this
module doesn't reinstall it. If the `console` machine grows more needs
(YouTube-DL, streamlink, etc.), add here.

## NixOS-side changes (out-of-repo, `/etc/nixos/configuration.nix`)

This edit lives outside the home-manager repo and requires `sudo`. It is
documented here so the implementation plan produces a matching before/after.

**Remove from `environment.systemPackages`:**

```
keepassxc prismlauncher vintagestory spotify discord unzip
kdePackages.spectacle yarn git signal-desktop tmux calibre cmake wine
protontricks anki-bin btop gnumake neovim wget ripgrep cntr filezilla
obs-studio gimp xclip smplayer kdePackages.kdenlive osu-lazer-bin
kdePackages.kdeconnect-kde zoom-us python3 gcc mpv teams-for-linux
alacritty gcc14 aoe2url captureage noto-fonts-cjk-sans
```

**Keep in `environment.systemPackages`:**

- `vim` — recovery editor when home-manager is broken.
- `gparted` — needs root.
- `kdePackages.partitionmanager` — needs root.
- `libgcc` — used by nix-ld runtime.
- `steam-run` — needed as a runtime shim for `programs.steam`.
- `steam` — verify whether `programs.steam.enable = true;` already
  installs it; if it does, remove this entry too.
- `ollama` (with CUDA override) — kept in NixOS to preserve GPU
  acceleration.

**Delete from `configuration.nix`:**

- The `let aoe2url = ...; captureage = ...; in` block that wraps
  `/etc/nixos/scripts/` bash files.
- `environment.etc."xdg/applications/aoe2url.desktop"` block. The
  home-manager `xdg.desktopEntries.AoE2UrlHelper` is the sole source of
  truth for that entry.

**Delete from `/etc/nixos/scripts/`:** `aoe2url`, `captureage`. Their
contents have been copied into `home-manager/modules/gaming/scripts/`.

**Firefox:** unchanged. `programs.firefox.enable = true;` remains.
**Ollama:** unchanged. Stays with its CUDA override.
**Fonts:** unchanged. `fonts.packages` remains in NixOS.

## Component: `CLAUDE.md` (project-local)

Concise, rules-only. Four sections:

### 1. NixOS vs home-manager decision

- **NixOS** if any of: needs root, affects all users, is a systemd system
  unit, touches hardware/kernel/graphics, needs 32-bit or setuid libs, is a
  system-wide service (sshd, cups, pipewire, networking daemons).
- **home-manager** otherwise: CLI you personally invoke, GUI app you
  personally launch, dotfiles, systemd user services, anything portable to
  WSL/macOS.
- **Ambiguous** things (Docker, Steam, browsers, printing): split — daemon
  in NixOS, user CLI/config in home-manager. Or accept the coupling and
  keep in NixOS if the split doesn't buy anything.

### 2. Feature catalog

- `base` — CLI essentials + shell/editor/tmux/git/keepassxc/syncthing +
  identity. Every machine.
- `dev` — Rust/C/Python/Node toolchains for building software.
- `dldev` — the private `agent-session` binary (`path:~/auto/dldev`
  flake input); only on machines where that path exists.
- `desktop-apps` — GUI apps for a workstation (chat, media, creative
  tools).
- `gaming` — game runtimes (wine, proton, prismlauncher) + AoE2 URL
  handler and its scripts.
- `media` — minimal set for a dedicated streaming machine (mpv).

### 3. Machine registry

- `machines.nix` maps hostname → list of feature names.
- Entries are sorted alphabetically; `./bootstrap init` enforces this.
- To register a new machine: `./bootstrap init`, answer yes/no for each
  non-`base` feature, commit, push.
- To change a machine's feature list: edit `machines.nix` by hand, then
  `./bootstrap upgrade`.

### 4. When adding a new package, ask

1. **Where does it live?** Which existing feature is the natural home for
   it? If none, is a new feature warranted or is this a one-off addition
   to `base`?
2. **Is any machine going to want it that doesn't already pick that
   feature?** If yes, either promote to `base` or split the feature.
3. **Does it need root, system services, or hardware access?** If yes,
   the package (or its enabling module) belongs in NixOS instead.
4. **Is it a duplicate of something already in NixOS?** Prefer the
   home-manager home if it's user-scoped; delete the NixOS entry.

## Verification

1. `nix flake check --impure` exits 0.
2. `nix build --impure ".#homeConfigurations.\"suspense\".activationPackage"`
   succeeds. Its content includes every previously-installed package plus
   every migrated package (spot-check `result/home-path/bin/` for
   `spotify`, `discord`, `mpv`, `aoe2url`, `captureage`).
3. `./bootstrap upgrade` succeeds on `suspense`.
4. After the NixOS-side edits are also applied and
   `sudo nixos-rebuild switch` is run, no previously-available package
   disappears from the user's environment. Spot-check paths:
   `which discord`, `which mpv`, `which aoe2url`, `which rustc`.
5. `dance` and `console` do not yet exist as physical machines to test
   against in this PR; their entries in `machines.nix` are declared for
   future `./bootstrap init` runs on those hosts and are covered by
   `nix flake check`'s evaluation of every hostname-keyed configuration.
6. Duplicate desktop entries: after activation, `ls
   ~/.local/share/applications/aoe2url.desktop` exists (home-manager) and
   `/etc/xdg/applications/aoe2url.desktop` does NOT exist (removed from
   NixOS).

## Risks and trade-offs

- **Two-step deployment for the migration.** The home-manager PR lands
  first (packages appear via home-manager). Then `/etc/nixos/` gets edited
  and `sudo nixos-rebuild switch` removes the duplicates. Between the two
  steps, packages exist in both places — harmless but slightly wasteful.
- **Removing packages from NixOS that programs.* modules internally
  reference.** For example `programs.steam` may internally reference
  `pkgs.steam` and installing `steam` explicitly is redundant. The plan
  errs on the side of keeping `steam` and `steam-run` in NixOS until
  proven redundant.
- **Feature growth.** The `desktop-apps` bucket already has ~16 packages.
  If it grows to 30+, split into `desktop-comms` / `desktop-creative` /
  etc. Not yet.
- **`dance` and `console` are untested on this branch.** They are
  registered so the machines file is complete, but the first
  `home-manager switch` on those hosts happens post-merge, via
  `./bootstrap init` on the physical machine. If that reveals a missing
  package on `console` (probably need `firefox` — but that's a NixOS
  concern) or `dance` (unlikely to need anything beyond `base`), we amend
  `media.nix` or `machines.nix` in a follow-up.
- **`git.nix` still declares `dlangevi@uwaterloo.ca` as the git user
  email.** This is intentionally unchanged (per prior discussion); noting
  it here so future readers know it wasn't overlooked during the reorg.
