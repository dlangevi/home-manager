# Slim home-manager, push GUI/gaming to NixOS

## Problem

`modules/packages.nix` has accumulated GUI apps, gaming, and media tools.
On the NixOS box (`suspense`) most of these are *also* installed via
`environment.systemPackages` — duplicate builds, slow `home-manager switch`
on fresh machines. home-manager is supposed to be portable (WSL, NixOS,
macOS); machine-specific stuff doesn't belong there.

## Goal

home-manager carries only portable user config: shell, editor bootstrap,
core CLI tools. Everything machine-specific (GUI apps, gaming, AoE2
integration) lives in `/etc/nixos/configuration.nix`.

## Scope of changes

### `modules/packages.nix`

Final package list:

```nix
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
```

Remove: `keepassxc`, `prismlauncher`, `vintagestory`, `spotify`, `discord`,
`signal-desktop`, `calibre`, `anki-bin`, `obs-studio`, `gimp`, `zoom-us`,
`teams-for-linux`, `smplayer`, `kdePackages.kdenlive`, `osu-lazer-bin`,
`filezilla`, `mpv`, `alacritty`.

Drop `nixpkgs.config.allowUnfree = true;` — none of the remaining packages
need it. (NixOS config already sets it.)

### `modules/desktop.nix`

Delete the file entirely. Move:

- `EDITOR = "nvim"` session variable → `modules/zsh.nix` (it's a shell
  concern, and zsh.nix already exists).
- AoE2 URL handler (`xdg.desktopEntries.aoe2url`, `xdg.mimeApps`, the two
  scripts under `scripts/`) → NixOS config.

### `home.nix`

Remove the `./modules/desktop.nix` import.

### `/etc/nixos/configuration.nix`

**Add to `environment.systemPackages`:**

- `prismlauncher`
- `vintagestory`
- `spotify`
- `keepassxc` (and drop `keepass` — pick one; user prefers keepassxc)

**Optionally drop** `btop` *or* leave `htop` to home-manager — non-blocking;
both can coexist. Leave alone.

**Add AoE2 integration.** Approach: wrap the scripts as
`pkgs.writeShellScriptBin` derivations directly in `configuration.nix`
(short scripts, fine to inline), then ship a `.desktop` file via
`environment.etc` and register the mime handler. Concretely:

```nix
let
  aoe2url = pkgs.writeShellScriptBin "aoe2url" ''
    <contents of scripts/aoe2url>
  '';
  captureage = pkgs.writeShellScriptBin "captureage" ''
    <contents of scripts/captureage>
  '';
in {
  environment.systemPackages = [ ... aoe2url captureage ];

  environment.etc."xdg/applications/aoe2url.desktop".text = ''
    [Desktop Entry]
    Name=AOE2 URL Handler
    Exec=aoe2url %u
    Terminal=false
    Type=Application
    MimeType=x-scheme-handler/aoe2de;
  '';
}
```

Mime registration: prefer `xdg.mime.defaultApplications` (NixOS option) if
available, otherwise the `.desktop` file's `MimeType` line is sufficient
for the desktop environment to pick it up.

### `scripts/` directory in home-manager repo

After the AoE2 scripts move into `configuration.nix`, the `scripts/`
directory is empty. Delete it.

### `README.md`

Update the "Structure" section to drop `desktop.nix` and `scripts/`.

## Out of scope

- No flake migration. Repo stays channels-based.
- No per-machine profiles inside home-manager. The "machine-specific
  layer" is NixOS, not home-manager profiles.
- No cleanup of unrelated NixOS-config cruft (`vim`, `wget`, etc. stay
  as-is).

## Verification

1. On NixOS host: `sudo nixos-rebuild switch` succeeds with new
   `configuration.nix`. AoE2 URL handler still triggers from browser
   (open an `aoe2de://` link).
2. On NixOS host: `home-manager switch` succeeds with slim config.
   `which discord` resolves to `/run/current-system/sw/bin/discord`
   (system, not home-manager profile).
3. On WSL host (if available): `home-manager switch` succeeds and is
   noticeably faster than before.
