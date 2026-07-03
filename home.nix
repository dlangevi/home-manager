{ config, pkgs, username, homeDirectory, ... }:

{
  imports = [
    ./modules/packages.nix
    ./modules/zsh.nix
    ./modules/tmux.nix
    ./modules/git.nix
    ./modules/neovim.nix
    ./modules/keepassxc.nix
    ./modules/syncthing.nix
  ];

  home.username = username;
  home.homeDirectory = homeDirectory;
  home.stateVersion = "25.05";

  programs.home-manager.enable = true;
}
