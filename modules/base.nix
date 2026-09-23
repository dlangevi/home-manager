{ config, pkgs, username, homeDirectory, ... }:

{
  imports = [
    ./zsh.nix
    ./tmux.nix
    ./git.nix
    ./neovim.nix
    ./keepassxc.nix
    ./syncthing.nix
    ./claude.nix
    ./input-method.nix
    ./wezterm.nix
  ];

  home.username = username;
  home.homeDirectory = homeDirectory;
  home.stateVersion = "25.11";

  programs.home-manager.enable = true;

  # dlsys on PATH ($HOME/.local/bin is added in zsh.nix). An out-of-store
  # symlink rather than a copy into the store: the script resolves its own
  # path and cds there, and it has to land in the repo working tree -- a
  # store copy would cd into /nix/store, where there is no flake.nix or git.
  home.file.".local/bin/dlsys".source =
    config.lib.file.mkOutOfStoreSymlink "${homeDirectory}/.config/home-manager/dlsys";

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  home.packages = with pkgs; [
    ripgrep
    fd
    bat
    zoxide
    gh
    htop
    # cudaSupport only pulls in the autoAddDriverRunpath hook (no CUDA, nothing
    # unfree); without it btop's dlopen of libnvidia-ml.so.1 fails and the GPU
    # box never appears on NVIDIA hosts.
    (btop.override { cudaSupport = true; })
    wget
    unzip
    xclip
    cntr
    jq
    mosh
  ];
}
