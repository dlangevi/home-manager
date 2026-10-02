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
{ config, snapctl, ... }:
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
    };
  };
}
