{ config, pkgs, lib, ... }:
let
  statusConfig = "${config.xdg.configHome}/i3status-rust/config-default.toml";
  modifier = config.wayland.windowManager.sway.config.modifier;

  nmApplet = pkgs.networkmanagerapplet;

  # Both session agents below are scoped to sway-session.target rather than
  # graphical-session.target. suspense selects *both* the `plasma` and `sway`
  # features, so a graphical-session binding would also start these inside a
  # Plasma session -- which already ships its own polkit agent and its own
  # NetworkManager secret agent (plasma-nm). Two polkit agents means two
  # dialogs for one authorisation. sway-session.target is started by
  # home-manager's sway module (systemd.enable, on by default) and exists
  # only in a sway session, so this binds the units to the one session that
  # actually lacks these pieces.
  swaySessionUnit = {
    After = [ "sway-session.target" ];
    PartOf = [ "sway-session.target" ];
  };

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
    # SDDM's sway.desktop just execs bare `sway`, which resolves to this
    # home-manager-installed package (user profile wins PATH over
    # /run/current-system/sw) -- NOT the NixOS programs.sway package, so
    # that module's own wrapperFeatures.gtk has no effect on what actually
    # runs. This module's wrapperFeatures.gtk defaults to false, which is
    # the real reason swaybar's tray can't decode SVG icons (fcitx5,
    # nm-applet) and falls back to its red frowning-face placeholder --
    # the GDK_PIXBUF_MODULE_FILE var that registers librsvg only gets set
    # by this wrapper.
    wrapperFeatures.gtk = true;
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
      # The GUI network/bluetooth surfaces, plus nm-applet's own secret and
      # connection dialogs, which are transients that tile badly.
      floating.criteria = [
        { app_id = "nm-connection-editor"; }
        { app_id = "nm-applet"; }
        { app_id = "io.github.kaii_lb.Overskride"; }
      ];
      window.titlebar = false;
      input."type:keyboard".xkb_options = "ctrl:nocaps";
      keybindings = lib.mkOptionDefault {
        "${modifier}+Shift+s" = "exec ${screenshotRegion}/bin/screenshot-region";

        # The Fn row emits these XF86 symbols but nothing bound them --
        # neither this config nor home-manager's sway defaults ship media
        # keybindings, so the whole row was dead.
        #
        # No OSD daemon here (no mako yet), but the bar is the feedback:
        # the sound and backlight blocks both update live, so a keypress
        # is visible there.
        "XF86AudioRaiseVolume" =
          "exec ${pkgs.wireplumber}/bin/wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+";
        "XF86AudioLowerVolume" =
          "exec ${pkgs.wireplumber}/bin/wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-";
        # -l 1.0 on the raise only: it caps at 100% so the key cannot
        # push PipeWire into software gain above unity and clip.
        "XF86AudioMute" =
          "exec ${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle";
        "XF86AudioMicMute" =
          "exec ${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle";

        "XF86MonBrightnessUp" = "exec ${pkgs.brightnessctl}/bin/brightnessctl set 5%+";
        "XF86MonBrightnessDown" = "exec ${pkgs.brightnessctl}/bin/brightnessctl set 5%-";
      };
    };
    extraConfig = ''
      for_window [app_id="nm-connection-editor"] move position center, focus
      for_window [app_id="nm-applet"] move position center, focus
      for_window [app_id="io.github.kaii_lb.Overskride"] move position center, focus

      # Launcher moved off Mod1+d -- see modules/sway.nix keybindings.
      unbindsym ${modifier}+d
      bindsym ${modifier}+p exec ${pkgs.dmenu}/bin/dmenu_path | ${pkgs.dmenu}/bin/dmenu | ${pkgs.findutils}/bin/xargs swaymsg exec --
    '';
  };

  # The piece that was actually missing, not just an uglier UI.
  #
  # NetworkManager stores a PSK one of two ways, chosen per connection by
  # `802-11-wireless-security.psk-flags`. Flag 0 (system-owned) means NM
  # writes it into /etc/NetworkManager/system-connections/*.nmconnection
  # itself and can reconnect unattended from boot. Flag 1 (agent-owned)
  # means NM never persists it at all -- it asks a registered secret agent
  # for the password on every single connect.
  #
  # nmtui registers as a secret agent, but only for as long as it is open,
  # and it creates connections agent-owned. So every network added on this
  # host since the Plasma -> sway move was unusable the moment the popup
  # closed; the journal had been logging
  #   device (wlp2s0): no secrets: No agents were available for this request
  # on and off since 2026-11-10. The three networks that still worked
  # (arborese, arboretum, ForbiddenCity) were the pre-sway ones plasma-nm
  # had written system-owned.
  #
  # nm-applet is a session-long secret agent, so a stored secret is
  # reachable whenever the session is up -- and, unlike nmtui, its password
  # dialog exposes the store-for-all-users choice that sets flag 0 in the
  # first place. --indicator (via preferStatusNotifierItems below) makes it
  # publish a StatusNotifierItem, which is the protocol swaybar's tray
  # speaks; its menu is the scan-and-connect list.
  services.network-manager-applet.enable = true;
  xsession.preferStatusNotifierItems = true;
  systemd.user.services.network-manager-applet = {
    Unit = lib.mkForce ({
      Description = "Network Manager applet";
      Requires = [ "tray.target" ];
    } // swaySessionUnit // {
      After = [ "sway-session.target" "tray.target" ];
    });
    Install.WantedBy = lib.mkForce [ "sway-session.target" ];
  };

  # polkitd runs (nixos/common.nix) but nothing was registered with it, so
  # any action needing an authorisation prompt had nowhere to draw one and
  # simply failed. Plasma supplied this on the other hosts; sway supplies
  # nothing, so it has to be named. Needed by overskride for adapter-level
  # bluez operations, and by nm-connection-editor when editing a connection
  # the networkmanager group does not already cover.
  systemd.user.services.polkit-gnome-authentication-agent-1 = {
    Unit = {
      Description = "polkit-gnome authentication agent";
    } // swaySessionUnit;
    Service = {
      ExecStart =
        "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
      Restart = "on-failure";
    };
    Install.WantedBy = [ "sway-session.target" ];
  };

  # Named by the bar's `tray icon_theme` above; without it on the profile
  # there are no icons for the tray to find.
  home.packages = [
    pkgs.adwaita-icon-theme
    # nm-applet itself comes from the systemd unit above; this is for the
    # Mod1+p launcher and PATH, which is how nm-connection-editor gets
    # reached when the bar is not where you happen to be looking.
    nmApplet
    # Pairing/unpairing surface for the bluetooth block below. GTK4 and
    # Rust rather than blueman's GTK + Python tree, and launched on demand
    # rather than sitting resident -- which matters on a laptop this
    # underpowered. It registers a bluez pairing agent while open, so a
    # pairing actually completes to a stored link key instead of the
    # half-paired state scripted bluetoothctl leaves behind.
    pkgs.overskride
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
        # $icon already differs wired vs wireless, so leaning on it plus an
        # ip fallback avoids a hardcoded "Wifi down" that misreports a live
        # ethernet link (no ssid) as no connection at all.
        format = " $icon {$ssid $signal_strength|$ip|down} ";
        click = [
          {
            button = "left";
            # Connecting to a *nearby* network is the tray icon's menu --
            # nm-applet is the only thing that can scan and prompt. This
            # click is the other half: the editor for connections already
            # saved, which is where a stale password or a wrong
            # autoconnect gets fixed.
            cmd = "${nmApplet}/bin/nm-connection-editor";
          }
        ];
      }
      {
        block = "bluetooth";
        # This block monitors one device by MAC -- it is not an adapter
        # on/off indicator, there isn't one. These are the headphones;
        # bluez reports their battery over D-Bus without its experimental
        # flag, so $percentage populates. Right-click (the block's own
        # default action) connects/disconnects; left-click opens overskride
        # to pair anything else.
        mac = "AC:BF:71:CA:44:D0";
        # Visible but minimal when disconnected -- just the icon, which is
        # what you right-click to connect. An empty string here hid the
        # block entirely and left no way to initiate a connection, which
        # was the whole point of having it.
        #
        # $available is a flag the block only sets when bluez knows the
        # device at all. Gating on it means a disconnected-but-paired
        # headset still shows its icon here, while a machine that has
        # never seen this MAC (suspense, which also gets this feature)
        # renders nothing.
        disconnected_format = "{ $available$icon |}";
        format = " $icon $name{ $percentage|} ";
        click = [
          {
            button = "left";
            cmd = "${pkgs.overskride}/bin/overskride";
          }
        ];
      }
      {
        block = "backlight";
        # Scroll to dim/brighten, exactly like the sound block below --
        # the block talks to systemd-logind over D-Bus to set brightness,
        # so this needs no udev rule or setuid helper.
        #
        # No `device` set on purpose: it then picks up whatever is in
        # /sys/class/backlight, which is intel_backlight here and would be
        # the amdgpu equivalent elsewhere. missing_format hides it on a
        # desktop with no panel to dim.
        missing_format = "";
        format = " $icon $brightness ";
        # intel_backlight exposes 7500 raw steps, and perceived lightness
        # tracks roughly the cube root of luminance -- scrolling linearly
        # through raw values wastes most of the travel at the bright end
        # where nothing looks different. The docs suggest 2.4-3.0 for
        # devices like this.
        root_scaling = 2.4;
        # The emoji icon set lists backlight as 🌕🌔🌓🌒🌑 -- brightest
        # glyph first -- so the default mapping puts a full moon at
        # minimum brightness and a new moon at maximum. Inverting makes
        # the moon wax as the screen gets brighter, which is the only
        # reading anyone expects.
        invert_icons = true;
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
