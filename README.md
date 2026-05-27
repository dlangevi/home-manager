# home-manager

NixOS home-manager configuration for dlangevi. Manages shell (zsh), tmux, git, neovim (bootstrap), desktop entries, and custom scripts.

## Structure

```
home.nix              # Entry point — imports all modules
modules/
  packages.nix        # Portable CLI tools (ripgrep, fd, bat, fzf, zoxide, gh, htop, claude-code)
  zsh.nix             # Zsh + oh-my-zsh + fzf + EDITOR env var
  tmux.nix            # Tmux (nix-native, no TPM)
  git.nix             # Git + GitHub CLI
  neovim.nix          # Neovim + auto-clone config from github.com/dlangevi/nvim
```

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

### 3. Add channels

```bash
nix-channel --add https://github.com/nix-community/home-manager/archive/master.tar.gz home-manager
nix-channel --add https://channels.nixos.org/nixpkgs-unstable unstable
nix-channel --update
```

### 4. Install home-manager

```bash
nix-shell '<home-manager>' -A install
```

### 5. Clone this repo

```bash
# Back up the default config home-manager generated
mv ~/.config/home-manager ~/.config/home-manager.default

# Clone
git clone git@github.com:dlangevi/home-manager.git ~/.config/home-manager
```

### 6. Apply

```bash
home-manager switch -b backup
```

The `-b backup` flag moves any conflicting existing files to `*.backup` instead of failing.

This will:
- Install all packages
- Set up zsh with oh-my-zsh
- Configure tmux with vim-tmux-navigator and yank plugins
- Set up git and gh CLI
- Clone neovim config from `github.com/dlangevi/dotconfig` into `~/.config/nvim/` (if it doesn't already exist)

### 7. Set zsh as default shell

```bash
# Find the nix-managed zsh path
which zsh

# Add it to allowed shells and set as default
command -v zsh | sudo tee -a /etc/shells
chsh -s $(command -v zsh)
```

### 8. Local secrets

Create `~/.zshenv.local` for machine-specific environment variables (not tracked by git):

```bash
export ASANA_TOKEN="your-token-here"
```

## Setup on NixOS

On NixOS, nix is already installed. Start from step 3 (channels).

If home-manager is already installed as a NixOS module, you may need to remove it from your system config first and use standalone mode instead.

## Updating

After editing any module:

```bash
home-manager switch
```

To update packages to latest versions:

```bash
nix-channel --update
home-manager switch
```

## Neovim config

The neovim Lua config lives in a separate repo: [github.com/dlangevi/nvim](https://github.com/dlangevi/nvim)

It is automatically cloned to `~/.config/nvim/` on first `home-manager switch` if the directory doesn't exist. After that, manage it independently:

```bash
cd ~/.config/nvim
git pull
```
