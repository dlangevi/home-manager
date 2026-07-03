# home-manager

NixOS home-manager configuration for dlangevi. Manages shell (zsh), tmux, git, neovim (bootstrap), desktop entries, and custom scripts.

## Structure

```
flake.nix             # Flake entry point
home.nix              # Base module aggregator — imports all modules
modules/
  packages.nix        # Portable CLI tools (ripgrep, fd, bat, fzf, zoxide, gh, htop, claude-code)
  zsh.nix             # Zsh + oh-my-zsh + fzf + EDITOR env var
  tmux.nix            # Tmux (nix-native, no TPM)
  git.nix             # Git + GitHub CLI
  neovim.nix          # Neovim + auto-clone config from github.com/dlangevi/nvim
  aoe2.nix            # AoE2 URL handler desktop entry (aoe2de://) — opt-in feature
```

Features are selected during `bootstrap init`; no need to manually choose profiles.

**Note for people who aren't me:** the `dldev` feature pulls in a private local flake input (`path:/home/dlangevi/auto/dldev`) and will fail to evaluate if that path doesn't exist. If you're cloning this repo as a reference or template, select only `base` (and optionally `aoe2`) during `bootstrap init`.

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
./bootstrap init
```

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

## Updating

Everyday:

```bash
./bootstrap upgrade
```

Refresh pinned inputs first (nixpkgs, home-manager, dldev), then switch:

```bash
./bootstrap upgrade --update
```

`nix flake update` writes to `flake.lock`; commit it with a follow-up commit if you want the update to persist across machines:

```bash
git add flake.lock
git commit -m "chore: refresh flake inputs"
git push
```

## Neovim config

The neovim Lua config lives in a separate repo: [github.com/dlangevi/nvim](https://github.com/dlangevi/nvim)

It is automatically cloned to `~/.config/nvim/` on first `home-manager switch` if the directory doesn't exist. After that, manage it independently:

```bash
cd ~/.config/nvim
git pull
```
