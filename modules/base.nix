{ pkgs, username, homeDirectory, ... }:

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

  programs.ssh = {
    enable = true;
    addKeysToAgent = "yes";
    matchBlocks = {
      "console" = {
        hostname = "console";
        user = username;
        identityFile = "~/.ssh/id_ed25519";
      };
      "dance" = {
        hostname = "dance";
        user = username;
        identityFile = "~/.ssh/id_ed25519";
      };
      "suspense" = {
        hostname = "suspense";
        user = username;
        identityFile = "~/.ssh/id_ed25519";
      };
    };
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
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
    claude-code
  ];
}
