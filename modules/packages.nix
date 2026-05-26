{ pkgs, ... }:

{
  nixpkgs.config.allowUnfree = true;

  home.packages = with pkgs; [
    ripgrep
    fd
    keepassxc
    prismlauncher
    htop
    claude-code

    bat         # Cat with syntax highlighting
    fzf         # Fuzzy finder
    zoxide      # Smarter cd command
    gh

    vintagestory
    spotify

    # User GUI apps
    discord
    signal-desktop
    calibre
    anki-bin
    obs-studio
    gimp
    zoom-us
    teams-for-linux
    smplayer
    kdePackages.kdenlive
    osu-lazer-bin
    filezilla
    mpv
    alacritty
  ];
}
