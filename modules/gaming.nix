{ pkgs, ... }:

let
  aoe2url = pkgs.writeShellScriptBin "aoe2url"
    (builtins.readFile ./gaming/scripts/aoe2url);
  captureage = pkgs.writeShellScriptBin "captureage"
    (builtins.readFile ./gaming/scripts/captureage);
in
{
  home.packages = with pkgs; [
    prismlauncher
    wine
    protontricks
    vintagestory
    osu-lazer-bin
  ] ++ [ aoe2url captureage ];

  xdg.desktopEntries.AoE2UrlHelper = {
    name = "AoE2 URL Opener";
    comment = "Play this game on Steam (Open URL)";
    exec = "aoe2url %u";
    icon = "steam_icon_813780";
    terminal = false;
    type = "Application";
    mimeType = [ "x-scheme-handler/aoe2de" ];
    categories = [ "Game" ];
  };
}
