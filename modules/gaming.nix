{ pkgs, ... }:

let
  aoe2url = pkgs.writeShellScriptBin "aoe2url"
    (builtins.readFile ./gaming/scripts/aoe2url);
  captureage = pkgs.writeShellScriptBin "captureage"
    (builtins.readFile ./gaming/scripts/captureage);
in
{
  imports = [ ./gaming/quiver-launcher.nix ];

  home.packages = with pkgs; [
    prismlauncher
    wine
    # Deployment/profile manager for the Cyberpunk mod stack. Native Linux;
    # NexusMods.App was the better fit but was discontinued Jan 2026 and
    # nixpkgs now ships it only as an insecure tombstone. Limo does not do
    # Cyberpunk dependency resolution -- that stays manual.
    limo
    vintagestory
    osu-lazer-bin
    # Switch 1 emulator (Yuzu/Sudachi fork). Needs prod.keys + firmware
    # supplied by the user at runtime; the package ships neither.
    eden
    mgba
    flips
  ] ++ [ aoe2url captureage ];

  # Per-game, not session-wide: enableSessionWide exports MANGOHUD=1 globally
  # and would overlay every Vulkan/GL app on the desktop. Opt in instead with a
  # Steam launch option of `MANGOHUD=1 %command%` -- for Proton titles prefer
  # the env var over the `mangohud %command%` wrapper, whose LD_PRELOAD does
  # not reliably carry into the Windows executable.
  programs.mangohud = {
    enable = true;
    settings = {
      fps = true;
      frametime = true;
      frame_timing = 1;
      gpu_stats = true;
      gpu_temp = true;
      vram = true;
      cpu_stats = true;
      cpu_temp = true;
      ram = true;
      position = "top-left";
      toggle_hud = "Shift_R+F12";
    };
  };

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
