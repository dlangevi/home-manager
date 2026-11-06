{ config, pkgs, ... }:
let
  statusConfig = "${config.xdg.configHome}/i3status-rust/config-default.toml";
in
{
  # Only sets the modifier key; everything else is sway's own sensible
  # default keybinding set (home-manager fills it in around this).
  wayland.windowManager.sway = {
    enable = true;
    config = {
      modifier = "Mod1"; # left Alt
      bars = [
        {
          statusCommand = "${pkgs.i3status-rust}/bin/i3status-rs ${statusConfig}";
        }
      ];
      # Tagged with --class by the wifi click command below so this rule
      # only catches that one popup, not every wezterm window.
      floating.criteria = [ { app_id = "nmtui"; } ];
    };
    extraConfig = ''
      for_window [app_id="nmtui"] resize set 800 500, move position center
    '';
  };

  # Plain i3status can't react to clicks/scrolls -- i3status-rust speaks the
  # same i3bar click-event protocol swaybar already understands, so it's a
  # drop-in replacement that also gets us wifi click + volume scroll for free.
  programs.i3status-rust = {
    enable = true;
    bars.default.blocks = [
      {
        block = "net";
        format = " $icon {$ssid $signal_strength|Wifi down} ";
        click = [
          {
            button = "left";
            cmd = "wezterm start --class nmtui -- nmtui";
          }
        ];
      }
      { block = "sound"; } # scroll adjusts volume, left-click toggles mute
      {
        block = "time";
        interval = 5;
        format = " $timestamp.datetime(f:'%Y-%m-%d %H:%M:%S') ";
      }
    ];
  };
}
