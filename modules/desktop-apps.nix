{ pkgs, lib, ... }:

let
  ytShortsList = "https://raw.githubusercontent.com/gijsdev/ublock-hide-yt-shorts/master/list.txt";

  # Twitch ads are server-side-injected, so no pure filter list can block them.
  # pixeltris/TwitchAdSolutions ships an uBO scriptlet that swaps the ad stream
  # for a clean one. Fetched at build time and injected into uBO's "My filters".
  # Bump `rev` (and re-run — Nix will print the new hash) when it stops working.
  twitchAdScriptlet = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/pixeltris/TwitchAdSolutions/master/video-swap-new/video-swap-new-ublock-origin.js";
    hash = "sha256-9bfN9sK7If1JrKIWDR18etC3KDHO7U+LGzcRY+3jRPY=";
  };

  ublockManagedStorage = builtins.toJSON {
    name = "uBlock0@raymondhill.net";
    description = "uBO managed settings";
    type = "storage";
    data.adminSettings = builtins.toJSON {
      selectedFilterLists = [
        "user-filters"
        "ublock-filters"
        "ublock-badware"
        "ublock-privacy"
        "ublock-quick-fixes"
        "ublock-unbreak"
        "easylist"
        "easyprivacy"
        "urlhaus-1"
        "plowe-0"
        ytShortsList
      ];
      importedLists = [ ytShortsList ];
      userFilters = builtins.readFile twitchAdScriptlet;
    };
  };
in
{
  home.file.".mozilla/managed-storage/uBlock0@raymondhill.net.json".text = ublockManagedStorage;
  home.file.".floorp/managed-storage/uBlock0@raymondhill.net.json".text = ublockManagedStorage;

  home.packages = with pkgs; [
    spotify
    discord
    signal-desktop
    teams-for-linux
    zoom-us
    obs-studio
    gimp
    kdePackages.kdenlive
    smplayer
    mpv
    calibre
    filezilla
    anki-bin
    kdePackages.spectacle
    kdePackages.kdeconnect-kde
    kdePackages.filelight
    floorp-bin
    moonlight-qt
  ];

  # Google Messages for web, as its own launcher entry rather than a bookmark
  # you have to go find. Unlike KDE Connect's kdeconnect-sms -- which reads
  # Android's SMS/MMS content provider and so cannot see RCS conversations,
  # because Google Messages keeps those in its own private database -- this is
  # the real app, so RCS threads, group chats and media all work. It relays
  # through the phone, so the phone has to be online, and the QR pairing lapses
  # after roughly two weeks of not using it.
  #
  # Points at floorp-bin from this same module rather than the `firefox` on
  # PATH: that one comes from the NixOS layer, which non-NixOS installs of this
  # feature don't have, and the entry would silently dangle there.
  xdg.desktopEntries.google-messages = {
    name = "Messages";
    comment = "Text messages from the phone (Google Messages for web)";
    exec = "${pkgs.floorp-bin}/bin/floorp --new-window https://messages.google.com/web";
    icon = "smartphone";
    terminal = false;
    type = "Application";
    categories = [ "Network" "InstantMessaging" ];
  };
}
