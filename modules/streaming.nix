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

  programs.zsh.shellAliases = {
    adp-tool = "~/build/analog-dance-pad/adp-tool/build/adp-tool";
  };
}
