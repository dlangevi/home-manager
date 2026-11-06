{ config, pkgs, lib, ... }:
let
  statusConfig = "${config.xdg.configHome}/i3status-rust/config-default.toml";
  modifier = config.wayland.windowManager.sway.config.modifier;

  # spectacle needs KWin's screenshot DBus interface, which isn't there under
  # sway. grim+slurp talk to sway directly over wlr-screencopy -- no portal,
  # no compositor-specific backend required.
  screenshotRegion = pkgs.writeShellApplication {
    name = "screenshot-region";
    runtimeInputs = with pkgs; [ grim slurp wl-clipboard xclip ];
    text = ''
      dir="$HOME/Pictures/Screenshots"
      mkdir -p "$dir"
      file="$dir/$(date +%Y-%m-%d_%H-%M-%S).png"
      geometry=$(slurp) || exit 1
      grim -g "$geometry" "$file"
      wl-copy --type image/png < "$file"
      # Xwayland runs alongside sway's native clipboard here (DISPLAY is
      # set), and whatever reads the paste may ask the X11 CLIPBOARD
      # selection instead of the Wayland one -- fill both so it's found
      # either way.
      if [ -n "''${DISPLAY:-}" ]; then
        xclip -selection clipboard -t image/png -i "$file" &
        disown
      fi
      echo "$file"
    '';
  };
in
{
  # Only sets the modifier key; everything else is sway's own sensible
  # default keybinding set (home-manager fills it in around this).
  wayland.windowManager.sway = {
    enable = true;
    config = {
      modifier = "Mod1"; # left Alt
      # Home-manager's sway module defaults terminal to foot; point it at
      # wezterm instead.
      terminal = "wezterm";
      bars = [
        {
          statusCommand = "${pkgs.i3status-rust}/bin/i3status-rs ${statusConfig}";
        }
      ];
      # Tagged with --class by the wifi click command below so this rule
      # only catches that one popup, not every wezterm window.
      floating.criteria = [ { app_id = "nmtui"; } ];
      window.titlebar = false;
      input."type:keyboard".xkb_options = "ctrl:nocaps";
      keybindings = lib.mkOptionDefault {
        "${modifier}+Shift+s" = "exec ${screenshotRegion}/bin/screenshot-region";
      };
    };
    extraConfig = ''
      for_window [app_id="nmtui"] resize set 800 500, move position center, focus

      # Upstream wezterm bug (github.com/wezterm/wezterm/issues/6463): its
      # Wayland scaling_changed handler mistakes sway's initial tiled-size
      # configure event for a trivial DPI change and skips applying it, so
      # the window draws at wezterm's floating default size until something
      # else forces a recalculation -- moving the mouse over it is the
      # symptom users hit. Toggling floating on then off immediately on map
      # does the same forced recalculation without needing that mouse move.
      for_window [app_id="org.wezfurlong.wezterm"] floating enable, floating disable
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
