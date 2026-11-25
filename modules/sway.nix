{ config, pkgs, lib, ... }:
let
  modifier = config.wayland.windowManager.sway.config.modifier;

  nmApplet = pkgs.networkmanagerapplet;

  # The headset bluetooth block used to right-click-toggle by itself
  # (i3status-rust's own default action for its `bluetooth` block). Waybar's
  # bluetooth module has no per-MAC toggle, so this is that one bit of
  # specific behaviour kept as its own script.
  headsetMac = "AC:BF:71:CA:44:D0";
  toggleHeadset = pkgs.writeShellApplication {
    name = "toggle-headset-bluetooth";
    runtimeInputs = [ pkgs.bluez ];
    text = ''
      if bluetoothctl info "${headsetMac}" | grep -q "Connected: yes"; then
        bluetoothctl disconnect "${headsetMac}"
      else
        bluetoothctl connect "${headsetMac}"
      fi
    '';
  };

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
      # swaybar's tray can show icons but not the StatusNotifierItem Menu
      # (com.canonical.dbusmenu) protocol at all -- it has no client-side
      # menu renderer, so nm-applet (which is Menu-only, no Activate) was
      # permanently unclickable no matter what was configured here. Waybar
      # (programs.waybar below) replaces it precisely for that: its tray
      # module is built on libdbusmenu-gtk3 and actually renders that menu.
      bars = [ ];
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

  # GTK resolves tray and app icons through the icon theme it's told to use
  # (gtk-icon-theme-name, defaulting to "Adwaita" when unset) -- unlike
  # swaybar's own custom lookup, which had no default and needed one named
  # explicitly. Waybar is a real GTK app, so this is just here to make sure
  # Adwaita is actually on the profile for that default to resolve to.
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

  # Replaces swaybar + i3status-rust. The only reason to move off a working
  # bar was the tray: swaybar cannot render a StatusNotifierItem's Menu
  # (com.canonical.dbusmenu), which is nm-applet's *entire* interaction
  # model (it has no Activate method at all) -- so nm-applet's icon was
  # permanently unclickable there. Waybar's tray module is built on
  # libdbusmenu-gtk3 and actually renders that menu.
  programs.waybar = {
    enable = true;
    # Scoped the same way as the nm-applet/polkit-agent units above --
    # suspense also runs the `plasma` feature, which has its own panel and
    # tray, so this must only start inside an actual sway session.
    systemd.enable = true;
    systemd.targets = [ "sway-session.target" ];

    settings.mainBar = {
      layer = "top";
      position = "top";
      height = 24;
      modules-right = [
        "battery"
        "network"
        "bluetooth"
        "backlight"
        "pulseaudio"
        "tray"
        "clock"
      ];

      battery = {
        # suspense has no battery; blur and chonk do. Waybar's battery
        # module auto-hides itself when there are no batteries to report on,
        # unlike i3status-rust's block, which needed an explicit empty
        # missing_format to avoid a permanent "missing" indicator.
        format = "{icon} {capacity}%";
        format-charging = "🔌 {capacity}% {time}";
        format-icons = [ "🪫" "🔋" ];
      };

      network = {
        # format-ethernet/format-wifi already distinguish wired vs wireless
        # on their own, so there's no need for the ip-address fallback
        # i3status-rust's single shared `format` needed to avoid
        # misreporting a live ethernet link (no ssid) as down.
        format-wifi = "📶 {essid} ({signalStrength}%)";
        format-ethernet = "🌐 {ipaddr}";
        format-disconnected = "down";
        on-click = "${nmApplet}/bin/nm-connection-editor";
      };

      bluetooth = {
        # Generic adapter/connected-device status rather than i3status-rust's
        # single-MAC-only block -- it'll show any paired device's battery,
        # not just the one headset. Left click still opens overskride to
        # pair anything new; right click keeps the one-headset quick
        # connect/disconnect toggle the old block's default action gave.
        format-connected = "🎧 {num_connections}";
        format-connected-battery = "🎧 {device_battery_percentage}%";
        format-off = "";
        on-click = "${pkgs.overskride}/bin/overskride";
        on-click-right = "${toggleHeadset}/bin/toggle-headset-bluetooth";
      };

      backlight = {
        # No `device` set on purpose, same as before: it picks up whatever
        # is in /sys/class/backlight (intel_backlight here, the amdgpu
        # equivalent elsewhere). Waybar's module doesn't apply
        # i3status-rust's perceptual root_scaling curve -- brightnessctl's
        # steps are linear here, a minor regression traded for the tray fix.
        format = "{icon} {percent}%";
        format-icons = [ "🌑" "🌒" "🌓" "🌔" "🌕" ];
        on-scroll-up = "${pkgs.brightnessctl}/bin/brightnessctl set 5%+";
        on-scroll-down = "${pkgs.brightnessctl}/bin/brightnessctl set 5%-";
      };

      pulseaudio = {
        format = "{icon} {volume}%";
        format-muted = "🔇";
        format-icons.default = [ "🔈" "🔉" "🔊" ];
        on-click = "${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle";
        scroll-step = 5;
      };

      tray = {
        icon-size = 16;
        spacing = 8;
      };

      clock = {
        interval = 1;
        format = "{:%Y-%m-%d %H:%M:%S}";
      };
    };

    style = ''
      * {
        font-family: monospace;
        font-size: 11px;
      }
      window#waybar {
        background: #1d1f21;
        color: #c5c8c6;
      }
    '';
  };
}
