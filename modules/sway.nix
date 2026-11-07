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
          # swaybar's tray resolves StatusNotifierItem icons by name through
          # the XDG icon themes on XDG_DATA_DIRS, and with no theme named it
          # searches only hicolor -- which carries none of those names. fcitx5
          # asks for "input-keyboard-symbolic", the lookup failed, and swaybar
          # drew its red frowning-face placeholder instead. Adwaita has that
          # name and the rest of the freedesktop set.
          extraConfig = ''
            tray icon_theme Adwaita
          '';
        }
      ];
      # Tagged with --class by the bar click commands below so these rules
      # only catch those popups, not every wezterm window.
      floating.criteria = [ { app_id = "nmtui"; } { app_id = "bluetuith"; } ];
      window.titlebar = false;
      input."type:keyboard".xkb_options = "ctrl:nocaps";
      keybindings = lib.mkOptionDefault {
        "${modifier}+Shift+s" = "exec ${screenshotRegion}/bin/screenshot-region";
      };
    };
    extraConfig = ''
      for_window [app_id="nmtui"] resize set 800 500, move position center, focus
      # bluetuith lists adapters, devices and per-device profiles side by
      # side, so it needs more room than nmtui.
      for_window [app_id="bluetuith"] resize set 900 600, move position center, focus

      # Launcher moved off Mod1+d -- see modules/sway.nix keybindings.
      unbindsym ${modifier}+d
      bindsym ${modifier}+p exec ${pkgs.dmenu}/bin/dmenu_path | ${pkgs.dmenu}/bin/dmenu | ${pkgs.findutils}/bin/xargs swaymsg exec --
    '';
  };

  # Named by the bar's `tray icon_theme` above; without it on the profile
  # there are no icons for the tray to find.
  home.packages = [
    pkgs.adwaita-icon-theme
    # Pairing/unpairing surface for the bluetooth block below. A TUI rather
    # than blueman: keyboard-only like the rest of this setup, and a small
    # Go binary instead of blueman's GTK + Python tree on a laptop this
    # underpowered.
    pkgs.bluetuith
  ];

  # Sway sets no cursor theme of its own, so the pointer falls back to the
  # stock X11 cross -- Breeze is what Plasma was drawing here before. One
  # declaration covers both consumers: the sway seat, and Xwayland via
  # Xresources. GTK/Qt apps follow XCURSOR_THEME, which this sets too --
  # deliberately *not* home-manager's gtk module, which would take ownership
  # of gtk-3.0/settings.ini away from Plasma on suspense.
  home.pointerCursor = {
    package = pkgs.kdePackages.breeze;
    name = "breeze_cursors";
    size = 24;
    sway.enable = true;
    x11.enable = true;
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
        # full_format/not_charging_format/empty_format each default to a
        # bare " $icon " independently of `format` -- the block force-sets
        # status to Full above full_threshold (95%) regardless of plug
        # state, so at a high charge the icon-only default was winning and
        # swallowing percentage/time even right after unplugging at ~98%.
        format = " $icon$percentage {$time_remaining.dur(hms:true, min_unit:m)|} ";
        full_format = " $icon$percentage ";
        not_charging_format = " $icon$percentage ";
        empty_format = " $icon$percentage ";
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
        block = "bluetooth";
        # This block monitors one device by MAC -- it is not an adapter
        # on/off indicator, there isn't one. These are the headphones;
        # bluez reports their battery over D-Bus without its experimental
        # flag, so $percentage populates. Right-click (the block's own
        # default action) connects/disconnects; left-click opens bluetuith
        # to pair anything else.
        mac = "AC:BF:71:CA:44:D0";
        # Empty when disconnected, so the block costs no bar space while
        # the headphones are off -- and stays invisible on suspense, which
        # also gets this feature but will never see this MAC. Same trick
        # the battery block above uses with missing_format.
        disconnected_format = "";
        format = " $icon $name{ $percentage|} ";
        click = [
          {
            button = "left";
            cmd = "wezterm start --class bluetuith -- bluetuith";
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
