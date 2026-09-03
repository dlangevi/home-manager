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
}
