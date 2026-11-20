{ pkgs, ... }:

{
  home.packages = with pkgs; [
    spotify
    obs-studio
    gimp
    kdePackages.kdenlive
    smplayer
    mpv
    calibre
  ];
}
