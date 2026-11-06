{ ... }:
{
  # Only sets the modifier key; everything else is sway's own sensible
  # default keybinding set (home-manager fills it in around this).
  wayland.windowManager.sway = {
    enable = true;
    config = {
      modifier = "Mod1"; # left Alt
    };
  };

  # Default swaybar runs i3status; enableDefault pulls in disk/cpu/memory
  # we don't want on a status bar this small. Keep just wifi, volume, clock.
  programs.i3status = {
    enable = true;
    enableDefault = false;
    general = {
      colors = true;
      interval = 5;
    };
    modules = {
      "wireless _first_" = {
        position = 1;
        settings = {
          format_up = "W: (%quality at %essid) %ip";
          format_down = "W: down";
        };
      };
      "volume master" = {
        position = 2;
        settings = {
          format = "♪ %volume";
          format_muted = "♪ muted";
          device = "pulse:0";
        };
      };
      "tztime local" = {
        position = 3;
        settings = {
          format = "%Y-%m-%d %H:%M:%S";
        };
      };
    };
  };
}
