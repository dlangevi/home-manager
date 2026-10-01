# The control surface for the MPD instance on dance, which is wired into
# snapcast in nixos/modules/snapcast.nix.
#
# There is no local daemon anywhere. MPD is a client/server protocol over TCP,
# so every machine here runs only clients pointed at dance:6600 -- the queue,
# the library view and the play state are server-side and therefore shared.
# Two people on two machines see and drive the same playback, which is the
# whole point of pairing it with snapcast: one queue, one clock, every speaker
# in the house.
#
# Home-manager rather than NixOS: these are CLIs a user invokes, no daemon, no
# hardware, no root.
{ pkgs, ... }:

let
  server = "dance";
  port = 6600;
in
{
  # ncmpcpp is the interactive client; mpc is the one-shot CLI, for scripts and
  # keybindings (`mpc toggle`, `mpc next`) where opening a TUI makes no sense.
  home.packages = [ pkgs.mpc ];

  # mpc and every other MPD client read these; ncmpcpp is configured
  # explicitly below rather than relying on them, since its own config file
  # wins over the environment and would otherwise silently fall back to
  # localhost.
  home.sessionVariables = {
    MPD_HOST = server;
    MPD_PORT = toString port;
  };

  programs.ncmpcpp = {
    enable = true;
    settings = {
      mpd_host = server;
      mpd_port = port;
    };

    # mpd_music_dir is deliberately unset. It only exists so ncmpcpp can reach
    # the audio files itself (local album art, "delete from disk"), and the
    # path differs per machine -- /srv/media/mpd on dance, where nothing else
    # mounts that layout, nothing at all elsewhere -- so a single value here
    # would be wrong on most hosts. Everything that goes through the MPD
    # protocol works without it.
  };

  # MPRIS, so the desktop can drive the queue. mpd-mpris is a plain translator:
  # it holds an MPD connection to dance and publishes org.mpris.MediaPlayer2.mpd
  # on the *local* session bus, which is what Plasma's media applet, the lock
  # screen, and kglobalaccel's media-key handling all read. Nothing about it is
  # Plasma-specific -- any MPRIS-aware desktop picks it up -- so it lives beside
  # the other clients rather than in modules/plasma.nix.
  #
  # The upstream module passes -no-instance, which is what pins the bus name to
  # exactly org.mpris.MediaPlayer2.mpd instead of appending a pid. Plasma's
  # applet copes either way; media keys are less reliable against a name that
  # changes every restart.
  #
  # One surprise worth naming: MPRIS has a single Volume property, and
  # mpd-mpris maps it onto MPD's own volume. For the fifo output that is the
  # software mixer declared in nixos/modules/snapcast.nix -- the snapcast
  # *master*, with per-client volume applied on top. So the applet's slider
  # moves every speaker in the house, not just this machine's. Per-client trim
  # is snapctl's job (modules/snapclient.nix).
  services.mpd-mpris = {
    enable = true;
    mpd = {
      # Defaults to config.services.mpd.enable, which is false here and would
      # therefore already be right -- pinned anyway, because the option
      # silently ignores host/port when true and that failure is invisible.
      useLocal = false;
      host = server;
      inherit port;
    };
  };
}
