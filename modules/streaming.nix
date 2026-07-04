{ pkgs, ... }:

{
  home.packages = with pkgs; [
    obs-studio
    itgmania
    smplayer
    mpv
    gparted
    zenity
    cmake
    gnumake
    python3
    nodejs
  ];
}
