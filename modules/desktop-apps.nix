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
    filezilla
    # Here rather than in media-apps: it is a thin client for suspense's GPU,
    # so it is useful on exactly the machines that are too weak to run the
    # heavy media set -- blur included. Every machine takes desktop-apps.
    moonlight-qt
    kdePackages.spectacle
    kdePackages.filelight
  ];

  # floorp-bin now comes from the home-manager module rather than
  # home.packages, because that is what wraps the binary with an enterprise
  # policies.json. Only `policies` is set -- no `profiles`, so nothing here
  # writes profiles.ini or touches the existing profile; the managed-storage
  # files above keep configuring uBO exactly as before.
  #
  # force_installed installs both add-ons on first launch of any profile and
  # stops them being removed from about:addons. The xpi is fetched from AMO by
  # the browser at runtime (so it self-updates and is not pinned by this
  # flake); pinning instead would mean adding the rycee firefox-addons NUR as
  # an input and a lock bump per extension update.
  programs.floorp = {
    enable = true;
    policies.ExtensionSettings = {
      "uBlock0@raymondhill.net" = {
        install_url = "https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi";
        installation_mode = "force_installed";
        private_browsing = true;
      };
      "{d7742d87-e61d-4b78-b8a1-b469842139fa}" = {
        install_url = "https://addons.mozilla.org/firefox/downloads/latest/vimium-ff/latest.xpi";
        installation_mode = "force_installed";
      };
    };
  };

  # Nothing in the session declares a default browser, so the handler for
  # http/https was resolved from whichever mimeinfo.cache the asking process
  # happened to scan first. xdg-open and KIO disagree about that order, which
  # is why wezterm's ctrl-shift-click landed on the `firefox` that
  # `programs.firefox.enable` puts in the system profile while `xdg-mime
  # query` reported floorp. Pin it explicitly.
  #
  # Done as an activation step rather than `xdg.mimeApps`, which would replace
  # ~/.config/mimeapps.list with a read-only store symlink -- discord, signal
  # and teams register their own url schemes into that file at runtime, and
  # those registrations would start failing.
  home.activation.defaultBrowser = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${pkgs.xdg-utils}/bin/xdg-mime default floorp.desktop \
      x-scheme-handler/http x-scheme-handler/https \
      text/html application/xhtml+xml
  '';
}
