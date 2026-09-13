# The playback end of the snapcast chain set up in nixos/modules/snapcast.nix.
# Runs on every machine that should be part of the synchronised group.
#
# This is a systemd *user* service rather than a system one on purpose. The
# client has to reach the logged-in user's PipeWire session to share the sound
# card; a system unit would have to take a raw ALSA device exclusively, which
# on suspense means nothing else on the desktop can make a sound. The cost is
# that playback follows the session -- no login on a box, no audio from it,
# which is the behaviour you want anyway.
{ pkgs, lib, ... }:

let
  # dance hosts snapserver. Resolves over the LAN, and over MagicDNS when off
  # it.
  server = "dance";
  port = 1704;
in
{
  home.packages = [ pkgs.snapcast ];

  systemd.user.services.snapclient = {
    Unit = {
      Description = "Snapcast client (synchronised multi-room audio)";
      # --player pulse talks to pipewire-pulse rather than PulseAudio proper;
      # nixos/common.nix runs PipeWire with the Pulse shim and
      # services.pulseaudio disabled.
      After = [ "pipewire-pulse.service" ];
      Wants = [ "pipewire-pulse.service" ];
    };

    Service = {
      # --hostID is left at its default, which is the machine hostname: that
      # is what names each client in snapweb, and it has to stay stable for
      # per-client volume and latency trim to stick across restarts.
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.snapcast}/bin/snapclient"
        "--player pulse"
        "tcp://${server}:${toString port}"
      ];
      Restart = "on-failure";
      # dance and suspense boot together; without a delay suspense spins on
      # connection refused while snapserver is still coming up.
      RestartSec = 5;
    };

    Install.WantedBy = [ "default.target" ];
  };
}
