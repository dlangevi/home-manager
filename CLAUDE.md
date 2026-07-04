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
5. **Is it an unfree package?** The flake sets `nixpkgs.config.allowUnfree = true` globally in `flake.nix`; unfree packages install without additional configuration. Make sure the license aligns with your intent — there's no scope-limit gate.
