{ config, pkgs, ... }:

{
  imports = [
    ./modules/packages.nix
    ./modules/zsh.nix
    ./modules/tmux.nix
    ./modules/git.nix
    ./modules/neovim.nix
    ./modules/desktop.nix
  ];

  home.username = "dlangevi";
  home.homeDirectory = "/home/dlangevi";
  home.stateVersion = "25.05";

  programs.home-manager.enable = true;
}
