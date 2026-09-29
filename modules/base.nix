{ config, pkgs, username, homeDirectory, dlsys, ... }:

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

  # dlsys is a normal store package now (crates/dlsys), not an out-of-store
  # symlink into the working tree. The symlink existed because the bash
  # script resolved its own path and cd'd there, so a store copy would have
  # landed in /nix/store where there is no flake.nix or git. The Rust binary
  # finds the repo by convention instead -- DLSYS_FLAKE, else
  # ~/.config/home-manager -- which removes that constraint.
  #
  # If dlsys is ever broken or missing, ./bootstrap.sh in the repo still
  # works: it needs only nix and execs `nix run .#dlsys`.

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  home.packages = [ dlsys ] ++ (with pkgs; [
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
  ]);
}
