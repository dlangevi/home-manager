# Plasma tuning. Three unrelated things live here:
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
# Only the keys named below are written -- see overrideConfig.
{ ... }:
{
  programs.plasma = {
    enable = true;

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
