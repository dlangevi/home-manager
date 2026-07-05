{ pkgs, ... }:

{
  home.packages = with pkgs; [
    spotify
    discord
    signal-desktop
    teams-for-linux
    zoom-us
    obs-studio
    gimp
    kdePackages.kdenlive
    smplayer
    mpv
    alacritty
    calibre
    filezilla
    anki-bin
    kdePackages.spectacle
    kdePackages.kdeconnect-kde
    kdePackages.filelight
    zen-browser
  ];
}
