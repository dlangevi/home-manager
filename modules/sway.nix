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

      # Launcher moved off Mod1+d -- see modules/sway.nix keybindings.
      unbindsym ${modifier}+d
      bindsym ${modifier}+p exec ${pkgs.dmenu}/bin/dmenu_path | ${pkgs.dmenu}/bin/dmenu | ${pkgs.findutils}/bin/xargs swaymsg exec --
    '';
  };

  # Plain i3status can't react to clicks/scrolls -- i3status-rust speaks the
  # same i3bar click-event protocol swaybar already understands, so it's a
  # drop-in replacement that also gets us wifi click + volume scroll for free.
  programs.i3status-rust = {
    enable = true;
    bars.default.icons = "emoji";
    bars.default.blocks = [
      {
        block = "battery";
        # suspense has no battery; blur does. Showing nothing there beats a
        # permanent "missing" block on the one machine without one. The
        # emoji icon set already has a charging-plug icon, so $icon alone
        # tells plugged-in-vs-not; time_remaining counts down to empty on
        # battery and up to full while charging, same placeholder either way.
        missing_format = "";
        format = " $icon$percentage {$time_remaining.dur(hms:true, min_unit:m)|} ";
      }
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
      {
        block = "sound";
        # $icon alone is the condensed speaker glyph; the emoji set swaps it
        # to a muted speaker on its own once right-click (toggle_mute, the
        # block's default) mutes -- no separate click wiring needed.
        format = " $icon {$volume|} ";
      }
      {
        block = "time";
        interval = 5;
        format = " $timestamp.datetime(f:'%Y-%m-%d %H:%M:%S') ";
      }
    ];
  };
}
