# home-manager

NixOS home-manager configuration for dlangevi. Manages shell (zsh), tmux, git, neovim (bootstrap), desktop entries, and custom scripts.

## Structure

```
flake.nix             # Flake entry point
modules/base.nix       # Base feature aggregator — imports leaf modules + baseline CLI packages
modules/
  base.nix            # Base feature — user identity + leaf modules + CLI tools
  dev.nix             # Rust/C/Python/Node toolchain
  desktop-apps.nix    # GUI apps for a workstation
  gaming.nix          # Wine/proton stack + AoE2 URL handler
  media.nix           # Streaming-box essentials (mpv)
  zsh.nix             # Zsh + oh-my-zsh + fzf + EDITOR env var
  tmux.nix            # Tmux (nix-native, no TPM)
  git.nix             # Git + GitHub CLI
  neovim.nix          # Neovim + auto-clone config from github.com/dlangevi/nvim
```

Features are selected during `dlsys init`; no need to manually choose profiles.

**Note for people who aren't me:** the `dldev` feature pulls in a private local flake input (`path:/home/dlangevi/auto/dldev`) and will fail to evaluate if that path doesn't exist. If you're cloning this repo as a reference or template, select only `base` (and optionally `gaming`, `desktop-apps`, `dev`, `media`) during `dlsys init`.

## Setup on WSL

### 1. Install WSL

From PowerShell (admin):

```powershell
wsl --install -d Ubuntu
```

Reboot, then open Ubuntu from the Start menu and create your user.

### 2. Install Nix

```bash
sh <(curl -L https://nixos.org/nix/install) --daemon
```

Close and reopen your terminal after installation.

Verify:

```bash
nix --version
```

### 3. Clone this repo

```bash
# Back up any default config home-manager already generated
mv ~/.config/home-manager ~/.config/home-manager.default 2>/dev/null || true

git clone git@github.com:dlangevi/home-manager.git ~/.config/home-manager
cd ~/.config/home-manager
```

### 4. Register this machine and apply

```bash
./dlsys init
```

(Explicitly `./dlsys` here — the `~/.local/bin/dlsys` symlink that puts it on
PATH is created by the first `home-manager switch`, which `init` runs.)

`init` will:

- Ask yes/no for each optional feature (`base` is always on).
- Write your machine's entry to `machines.nix`.
- Commit the registration.
- Run the first `home-manager switch`.

After it finishes, push the registration commit:

```bash
git push
```

### 5. Set zsh as default shell

```bash
command -v zsh | sudo tee -a /etc/shells
chsh -s "$(command -v zsh)"
```

### 6. Local secrets

Create `~/.zshenv.local` for machine-specific environment variables (not tracked by git):

```bash
export ASANA_TOKEN="your-token-here"
```

## Setup on NixOS

On NixOS, Nix is already installed. Start from step 3 of the WSL setup (Clone this repo).

If home-manager is already installed as a NixOS module, remove it from the system config first — this flake uses standalone mode.

## Applying changes

Everyday:

```bash
dlsys switch           # same as: dlsys switch auto
```

`auto` builds both layers, compares each against what is live
(`~/.local/state/home-manager/gcroots/current-home` and `/run/current-system`),
and switches only the ones whose store path actually moved. It prints what it
found, and exits without doing anything when both already match. Because the
comparison is on built output rather than on which files you edited, it is
exact in both directions: a `flake.lock` bump that only moves the system layer
switches only that layer, and an edit under `nixos/` that evaluates to the
system already running is correctly a no-op. Neither is something a
"did `nixos/` change?" check can get right.

The build is not extra work — the switch that follows reuses it from the store.
The practical win is that a home-manager-only change never prompts for sudo.

Naming a target skips detection and always switches:

```bash
dlsys switch hm        # home-manager switch only
dlsys switch nixos     # nixos-rebuild switch only
dlsys switch all       # both layers, unconditionally
```

Use an explicit target when re-running activation is itself the point — a unit
you want restarted, a generation you want re-linked — since `auto` will
correctly decide there is nothing to do.

Refresh pinned inputs first (nixpkgs, home-manager, dl-herd), then switch.
Combine with any target:

```bash
dlsys switch --update              # auto, with flake update
dlsys switch all --update          # both layers, with flake update
```

`nix flake update` writes to `flake.lock`; commit it with a follow-up commit if you want the update to persist across machines:

```bash
git add flake.lock
git commit -m "chore: refresh flake inputs"
git push
```

### Every machine at once

```bash
dlsys rollout                              # suspense, then dance
dlsys rollout --order dance,suspense       # explicit order (may be a subset)
dlsys rollout --update                     # refresh inputs once, then switch everything
```

`rollout` runs `dlsys switch auto` on each machine in turn, stopping at the
first failure and naming the hosts it never attempted. Every host ends up on the
same commit: the working tree must be clean and identical to its upstream branch
before the run starts, and remote hosts `git pull --ff-only` before upgrading.
`--update` refreshes the flake inputs once locally, commits `flake.lock`, and
pushes, so no host resolves its own lock.

Remote `nixos-rebuild` needs a sudo password, so hosts run sequentially over
`ssh -t` and you type it when prompted.

`console` is not covered — it has no address reachable from here, so it is
upgraded by hand at the machine. Once it joins the tailnet, add it to the
host-to-ssh-target map at the top of `dlsys` and it comes along with the
rest.

Unattended `system.autoUpgrade` is off everywhere on purpose: it applied the
public repo's branch head as root with no human in the loop, which turns a
GitHub account compromise into root on every box within a week.

## NixOS layer

`nixos/common.nix` holds the ~80% of `configuration.nix` shared by all
machines (boot, network, plasma6, pipewire, steam, nix settings, printing,
openssh). Per-host slices live in `nixos/hosts/<name>.nix` — hostname,
user, autologin, firewall, hardware-specific systemd units.

Per-machine `hardware-configuration.nix` stays on the machine at
`/etc/nixos/hardware-configuration.nix` and is imported by path via
`--impure`. It's auto-generated by NixOS and not committed here.

`dlsys switch all` runs `sudo nixos-rebuild switch --flake .#$host`
followed by `home-manager switch --flake .#$host`. Use `dlsys switch
nixos` for the system layer alone, or `dlsys switch` (default `hm`)
for the user layer alone. On non-NixOS hosts (WSL, macOS) the `nixos` and
`all` targets error out; use `hm`.

## Neovim config

The neovim Lua config lives in a separate repo: [github.com/dlangevi/nvim](https://github.com/dlangevi/nvim)

It is automatically cloned to `~/.config/nvim/` on first `home-manager switch` if the directory doesn't exist. After that, manage it independently:

```bash
cd ~/.config/nvim
git pull
```
