{ pkgs, username, homeDirectory, ... }:

{
  imports = [
    ./zsh.nix
    ./tmux.nix
    ./git.nix
    ./neovim.nix
    ./keepassxc.nix
    ./syncthing.nix
    ./claude.nix
  ];

  home.username = username;
  home.homeDirectory = homeDirectory;
  home.stateVersion = "25.11";

  programs.home-manager.enable = true;

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

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
  ];
}
