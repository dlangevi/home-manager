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
