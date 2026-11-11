# Plasma tuning. Five unrelated things live here:
#
#   0. KRunner is purely D-Bus activated -- the unit plasma-workspace ships has
#      no [Install] section at all -- so it does not exist until the first
#      Alt+Space, and that keypress pays the whole cold start: process spawn,
#      Qt/QML load, every runner plugin, and a ksycoca build under krunner's
#      own XDG_DATA_DIRS. On a cold boot that is the 10+ seconds between
#      reaching the desktop and being able to launch anything. The journal
#      shows it plainly: the session finishes at T+3.1s, then nothing until
#      the first query 14s later drags baloorunner and a sycoca rebuild in
#      behind it. Start it eagerly instead (below).
#
#   1. Baloo was content-indexing all of $HOME with no scope restriction, which on
#      this machine meant recursively extracting file contents across ~/storage
#      (710 GB), ~/defaults, ~/Seagate, ~/downloads and ~/code. The result was a
#      18.7 GiB index and baloo_file_extractor permanently pinning a core. Every Qt
#      file dialog, KRunner and Kickoff query that database synchronously, which is
#      what made app launch feel slow. Filenames-only indexing plus excluding the
#      bulk trees fixes it; full-text search inside files is the price.
#
#   2. Stock animation duration (factor 1.0) reads as floaty.
#
#   3. Default terminal. Konsole is hardcoded as KIO's fallback, so wezterm has
#      to be named explicitly.
#
#   4. Snapcast hotkeys. Plasma's mixer enumerates local PipeWire streams, so
#      this machine's own snapclient already has a native volume control and
#      the other box in the room has none -- there is no widget that can
#      represent a remote client at all. snapweb has those controls and is a
#      browser tab you have to go open. Global shortcuts onto snapctl are the
#      native mechanism that is left.
#
#      Playback is deliberately not here: mpd-mpris (modules/mpd-client.nix)
#      publishes the queue over MPRIS, which the media applet, the lock
#      screen and the hardware media keys already consume. Binding transport
#      to snapctl as well would be a second, worse surface for the same thing.
#
# Only the keys named below are written -- see overrideConfig.
{ config, lib, pkgs, hostname, snapctl, ... }:
let
  # Standalone home-manager (this is `home-manager.lib.homeManagerConfiguration`
  # in flake.nix, not folded into suspense's nixosSystem) has no view into the
  # NixOS config, so it cannot read
  # nixos/hosts/suspense.nix's `services.displayManager.defaultSession` the
  # way that file's own `output_name` conditional does. This flag is that same
  # fact, copied by hand -- flip it in lockstep whenever defaultSession there
  # changes away from (or back to) "plasmax11". Flipped back to true
  # (2026-11-11): the Wayland cutover was reverted in suspense.nix after a
  # live NVIDIA/KWin/XWayland flicker artifact outweighed the capture-race
  # fix it was meant to deliver -- see that file's comment for the detail.
  onPlasmaX11 = true;

  # Both variants below are measured-live values from each backend, not a
  # name substitution on one template -- geometry differs between them too
  # (the 1080p panel's undo position is 0,219 under X11 but 0,0 under
  # Wayland), not just the connector names.
  sunshineDesktopPrepCmd =
    if onPlasmaX11 then {
      # Restored from commit aaac5b5 (the last X11-only version, predating
      # the Wayland capture-backend test). No scale or vrrpolicy verbs: both
      # are confirmed no-ops/unsupported under X11 on this GPU --
      # `kscreen-doctor -o` reports "Vrr: incapable" on both outputs here,
      # and the scale verb silently leaves scale at 1 (see commit aaac5b5's
      # message for the live test).
      do = "/run/current-system/sw/bin/kscreen-doctor output.DP-0.disable output.DP-4.mode.2560x1440@165 output.DP-4.position.0,0";
      undo = "/run/current-system/sw/bin/kscreen-doctor output.DP-4.mode.2560x1440@165 output.DP-4.position.1920,0 output.DP-0.enable output.DP-0.mode.1920x1080@165 output.DP-0.position.0,219";
    } else {
      # From commit b9bf65c, tested live under a Wayland login
      # (2026-11-09): KWin/KScreen's Wayland connector names (DP-1 = 1080p,
      # DP-3 = 1440p), and here the scale and vrrpolicy verbs both do take
      # effect (unlike X11) -- scale doubles the 1440p panel's UI for
      # legibility on a remote client, vrrpolicy.never works around a
      # confirmed NVIDIA-595.x/KWin-6.6.x VRR+LFC flicker bug during
      # streaming.
      #
      # A 2026-11-11 game-streaming session flickered and scale was briefly
      # suspected (dropping it to 1 live, stream still running, appeared to
      # stop the flicker) -- but that was a false positive. The game had its
      # own in-game HDR toggle on while this output runs SDR-only (`kscreen-
      # doctor -o` reports HDR incapable/disabled here); disabling HDR in
      # the game fixed it, unrelated to KWin's output scale. Restored.
      do = "/run/current-system/sw/bin/kscreen-doctor output.DP-1.disable output.DP-3.mode.2560x1440@165 output.DP-3.position.0,0 output.DP-3.scale.2 output.DP-3.vrrpolicy.never";
      undo = "/run/current-system/sw/bin/kscreen-doctor output.DP-3.vrrpolicy.automatic output.DP-3.scale.1 output.DP-3.mode.2560x1440@165 output.DP-3.position.1920,0 output.DP-1.enable output.DP-1.mode.1920x1080@165 output.DP-1.position.0,0";
    };
in
{
  # Pull KRunner up to login time. plasma-workspace.target is the right anchor:
  # it is reached once the desktop is actually up, so krunner warms in the idle
  # moment after the session paints rather than delaying it.
  #
  # A .wants/ symlink rather than an [Install] drop-in, because drop-in
  # [Install] sections do nothing until `systemctl --user enable` runs -- the
  # symlink *is* what enabling would create. Out-of-store so it points at the
  # stable /run/current-system path and survives every rebuild; this feature is
  # only selected by NixOS hosts, so that path is always there.
  xdg.configFile."systemd/user/plasma-workspace.target.wants/plasma-krunner.service".source =
    config.lib.file.mkOutOfStoreSymlink
      "/run/current-system/sw/share/systemd/user/plasma-krunner.service";

  # Sunshine's single "Desktop" app: the 1080p panel is never captured anyway
  # -- services.sunshine.settings.output_name pins capture to the 1440p panel
  # in nixos/hosts/suspense.nix -- so a connected Moonlight client gets
  # nothing from it except desktop clutter. Disabling it for the session's
  # duration instead gives the 1440p panel the whole desktop.
  #
  # prep-cmd's "do" runs on stream start, "undo" on stream end/disconnect --
  # both inherit almost no environment (same as a KDE global shortcut), hence
  # the absolute /run/current-system/sw/bin path rather than a bare command.
  # Both name an explicit mode, not just position/enable -- tested live and
  # found that `output.<name>.enable` alone, after an interleaving disable of
  # another output, left the output enabled but modeless, i.e. actually
  # blank; naming the mode is what makes it come back with a picture.
  #
  # The actual do/undo strings (including the backend-dependent connector
  # names and whether scale/vrrpolicy are included at all) are
  # `sunshineDesktopPrepCmd` above -- see its comment for why.
  xdg.configFile."sunshine/apps.json" = lib.mkIf (hostname == "suspense") {
    text = builtins.toJSON {
      env.PATH = "$(PATH):$(HOME)/.local/bin";
      apps = [
        {
          name = "Desktop";
          image-path = "desktop.png";
          prep-cmd = [ sunshineDesktopPrepCmd ];
        }
      ];
    };
  };

  # Manual escape hatch for sunshineDesktopPrepCmd's scale verb above: Sunshine
  # only runs an app's "undo" on the *next* app launch, never on a bare client
  # disconnect (confirmed in src/process.cpp -- terminate() is called before
  # launching a new app, on sunshine's own shutdown, or when a monitored
  # process exits; a Moonlight disconnect that isn't also an explicit "quit
  # app" is none of those). So closing Moonlight without quitting the app
  # leaves the 1440p panel's scale wherever "do" left it, for however long
  # until the next stream start. `ui-scale <1|2>` lets you fix that by hand
  # without waiting for the next connect.
  #
  # Same no-op-under-X11 caveat as the prep-cmd's scale verb: this has no
  # visible effect while onPlasmaX11 (above) is true, i.e. right now -- it
  # only does something the next time Wayland is the default session.
  home.packages = lib.optional (hostname == "suspense") (
    pkgs.writeShellScriptBin "ui-scale" ''
      set -euo pipefail
      if [ "$#" -ne 1 ] || { [ "$1" != "1" ] && [ "$1" != "2" ]; }; then
        echo "usage: ui-scale <1|2>" >&2
        exit 1
      fi
      exec /run/current-system/sw/bin/kscreen-doctor \
        output.${if onPlasmaX11 then "DP-4" else "DP-3"}.scale."$1"
    ''
  );

  programs.plasma = {
    enable = true;

    # Volume for the *other* room's speakers. Meta+Shift+Left/Right are
    # already KWin's move-window-to-screen, so the pair here is Up/Down.
    #
    # The absolute store path rather than a bare `snapctl`: a global shortcut
    # runs with almost no environment, and naming the path also decouples this
    # feature from the snapclient feature, which only happens to be selected
    # on the same machine today.
    hotkeys.commands = {
      "snapcast-dance-volume-up" = {
        name = "Snapcast: dance volume up";
        key = "Meta+Shift+Up";
        command = "${snapctl}/bin/snapctl volume dance +5 --notify";
      };
      "snapcast-dance-volume-down" = {
        name = "Snapcast: dance volume down";
        key = "Meta+Shift+Down";
        command = "${snapctl}/bin/snapctl volume dance -5 --notify";
      };
      "snapcast-dance-mute" = {
        name = "Snapcast: dance mute toggle";
        key = "Meta+Shift+M";
        command = "${snapctl}/bin/snapctl mute dance --notify";
      };
    };

    # Steam Big Picture always opens on DP-0 (the 1080p panel) rather than the
    # 32" DP-4, because Steam restores whatever geometry it last saw and the
    # 1080p one is where the desktop-mode client lives.
    #
    # Two details this rule depends on, both measured on suspense rather than
    # guessed -- a hand-written version of this rule sitting in kwinrulesrc had
    # each of them wrong, which is why it silently did nothing:
    #
    #   * The window's WM_CLASS is `"steamwebhelper", "steam"` -- the BPM
    #     window is a CEF helper, not the Steam client proper. match-whole
    #     would compare the pair "steamwebhelper steam", so it has to be off
    #     and match the class alone. The desktop client shares that class,
    #     which is what the title match is for.
    #
    #   * KWin numbers screens positionally, not by connector name, and the
    #     order is *not* left-to-right: `workspace.screens` reports
    #     0=DP-4 (2560x1440 @ 1920,0) and 1=DP-0 (1920x1080 @ 0,360), i.e.
    #     the primary comes first. So the 32" is 0. Unplugging or re-ordering
    #     displays renumbers this; there is no name-based alternative in
    #     kwinrules.
    #
    # `force` rather than `initially` so Steam cannot drag it back on a later
    # show -- BPM hides and re-maps the same window when you toggle out and in.
    window-rules = [
      {
        description = "Steam Big Picture on the 32\" display";
        match = {
          window-class = {
            value = "steam";
            type = "exact";
            match-whole = false;
          };
          title = {
            value = "Steam Big Picture Mode";
            type = "substring";
          };
        };
        apply.screen = {
          value = 0;
          apply = "force";
        };
      }
    ];

    # Write only the keys named below and leave the rest of Plasma's config
    # mutable. Load-bearing, not a default we're coasting on: kwinrc holds ~26
    # [Tiling][<uuid>] blocks of live layout state that overrideConfig = true
    # would delete on every activation.
    overrideConfig = false;

    workspace = {
      # The bouncing cursor and taskbar spinner make launches *feel* slower than
      # they are -- the window is often already up while they're still running.
      cursor = {
        cursorFeedback = "None";
        taskManagerFeedback = false;
      };
      tooltipDelay = 200; # ms; stock is ~700
      splashScreen.theme = "None";
    };

    configFile = {
      # Animation speed moved to kdeglobals [KDE] in Plasma 6; cf. the
      # kwin.upd:animation-speed marker already in that file's update_info.
      kdeglobals."KDE"."AnimationDurationFactor" = 0.25;

      # Default terminal for anything that asks the desktop for one: Dolphin's
      # Open Terminal, KRunner, any `Terminal=true` desktop entry. KIO reads
      # this key and falls back to a hardcoded "konsole" if it is unset --
      # both strings are visible in libKF6KIOGui.so.6.26. The launcher hands
      # the command over as `-e <cmd>`, which wezterm accepts as an alias for
      # its `start` subcommand, and inherits the job's cwd for the
      # open-here case.
      kdeglobals."General"."TerminalApplication" = "wezterm";

      # Baloo: filenames only, bulk trees excluded. Key names per
      # src/lib/baloosettings.kcfg in KDE/baloo.
      baloofilerc."Basic Settings"."Indexing-Enabled" = true;
      baloofilerc."General"."only basic indexing" = true;
      baloofilerc."General"."index hidden folders" = false;
      # PathList; Baloo stores this with the [$e] shell-expansion marker.
      # ~/documents and ~/Sync are deliberately absent so they stay searchable.
      baloofilerc."General"."exclude folders" = {
        shellExpand = true;
        value = builtins.concatStringsSep "," (map (d: "$HOME/${d}/") [
          "storage"   # 710 GB, /dev/sdb2
          "defaults"  # 20 GB
          "Seagate"   # 15 GB
          "downloads" # 13 GB
          "code"      # 5.2 GB
          "go"
          "src"
          "itg"
          "auto"
          ".cache"
          ".local/share/Steam"
        ]);
      };

      # KWin's fullscreen-unredirect optimization (an app in exclusive
      # fullscreen gets to write straight to the front buffer, bypassing the
      # compositor) is exactly what breaks Sunshine's X11 capture: Sunshine
      # grabs a snapshot of that buffer with no atomic swap to sync against,
      # so a capture mid-scanout shows old pixels above the tear line and new
      # pixels below it. Only visible over Moonlight -- the local display
      # scans out the same buffer and never notices the tear.
      #
      # WindowsBlockCompositing=false keeps the compositor live through
      # fullscreen games, which is what Sunshine needs here, at the cost of
      # the unredirect fast-path's local-only performance win -- irrelevant
      # for a machine whose point is to be streamed from.
      kwinrc."Compositing"."WindowsBlockCompositing" = false;

      # AllowTearing is Wayland's equivalent of the X11 unredirect fast path
      # above, and carries the same capture-tearing risk Sunshine's stream is
      # exposed to -- confirmed live 2026-11-11 streaming an XWayland game
      # (Steam/Proton, GPU only 55% utilized, well under its power limit,
      # with the default AllowTearing=false): turning this on measurably
      # improved in-game performance. But the same Wayland session also hit
      # a separate, worse NVIDIA/KWin/XWayland flicker-artifact bug that led
      # to reverting the whole Wayland cutover (see suspense.nix's
      # defaultSession comment), so this only matters again once Wayland is
      # retried -- tied to onPlasmaX11 so it goes along for that ride rather
      # than sitting on as a no-op (or worse, a live footgun if Wayland
      # becomes selectable again some other way) while X11 is the default.
      kwinrc."Compositing"."AllowTearing" = !onPlasmaX11;
    };
  };
}
