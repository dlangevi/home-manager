{ ... }:

{
  xdg.desktopEntries.AoE2UrlHelper = {
    name = "AoE2 URL Opener";
    comment = "Play this game on Steam (Open URL)";
    exec = "/run/current-system/sw/bin/aoe2url %u";
    icon = "steam_icon_813780";
    terminal = false;
    type = "Application";
    mimeType = [ "x-scheme-handler/aoe2de" ];
    categories = [ "Game" ];
  };
}
