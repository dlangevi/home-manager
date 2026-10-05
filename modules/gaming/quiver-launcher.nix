# Quiver Launcher ships for Linux only as a Velopack AppImage, so this is a
# pinned binary drop rather than a build. Two things about it drive the shape:
#
#  - It exists to download third-party release binaries and exec them. Those
#    are distro-built ELFs expecting /lib64/ld-linux-x86-64.so.2, which NixOS
#    does not have. appimageTools runs the app inside a buildFHSEnv namespace,
#    and children inherit it, so they resolve. autoPatchelf on the extracted
#    payload would fix the launcher and break everything it launches.
#  - Velopack's in-app updater cannot rewrite /nix/store. Bump `version` and
#    `hash` here instead; there is no auto-update path and that is deliberate.
#
# The library (apps.json, settings.json, Apps/, Cache/) normally lives beside
# the executable. /nix/store is not writable, so Quiver falls back to
# ~/.local/share/QuiverLauncher -- which is where we want it anyway.
{ pkgs, ... }:

let
  pname = "quiver-launcher";
  version = "3.4.5";

  src = pkgs.fetchurl {
    url = "https://github.com/tgeorgiadis/quiver-launcher/releases/download/v${version}/QuiverLauncher-linux-x64.AppImage";
    hash = "sha256-h33fo2KBBGifV1hI/wNRKizzEqRB3t6PgBhbuzNiYQc=";
  };

  # Extracted separately from wrapAppImage only so extraInstallCommands can
  # reach the bundled icon.
  contents = pkgs.appimageTools.extract { inherit pname version src; };

  quiver-launcher = pkgs.appimageTools.wrapAppImage {
    inherit pname version;
    src = contents;

    # defaultFhsEnvArgs already carries fontconfig, openssl, SDL2, X11, wayland,
    # libGL and dbus. icu is the one hard requirement it misses: the publish
    # leaves InvariantGlobalization off, so libSystem.Globalization.Native.so
    # dlopens ICU at startup and the app dies without it.
    extraPkgs = p: [ p.icu p.stdenv.cc.cc.lib ];

    # Upstream files this under scalable/ even though it is a 256x256 PNG.
    extraInstallCommands = ''
      install -Dm444 ${contents}/usr/share/icons/hicolor/scalable/apps/QuiverLauncher.png \
        $out/share/icons/hicolor/256x256/apps/quiver-launcher.png
    '';

    meta = {
      description = "Launcher for apps distributed through GitHub/GitLab releases";
      homepage = "https://github.com/tgeorgiadis/quiver-launcher";
      platforms = [ "x86_64-linux" ];
      mainProgram = pname;
    };
  };
in
{
  home.packages = [ quiver-launcher ];

  xdg.desktopEntries.quiver-launcher = {
    name = "Quiver Launcher";
    comment = "Download and manage apps from GitHub releases";
    exec = "quiver-launcher";
    icon = "quiver-launcher";
    terminal = false;
    type = "Application";
    categories = [ "Game" "Utility" ];
    # Matches the bundled .desktop so window matching still works.
    settings.StartupWMClass = "QuiverLauncher";
  };
}
