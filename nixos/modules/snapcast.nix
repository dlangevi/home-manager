# Synchronised multi-room playback for dance + suspense, which sit in the same
# room with their own speakers.
#
# Navidrome on its own cannot do this. The Subsonic API is stateless HTTP
# streaming: each client pulls its own byte ranges and plays them on its own
# clock, so two clients drift by seconds. In the same room that is an audible
# slap echo rather than a subtle wander -- anything past ~20-30 ms reads as a
# second copy of the music.
#
# Snapcast supplies the missing shared clock. The chain is:
#
#   Navidrome Jukebox -> mpv (--ao=pcm) -> fifo -> snapserver -> snapclients
#
# Jukebox mode makes the *server* play the track rather than streaming it to
# the phone; pointing mpv's PCM output at a fifo instead of a sound card turns
# that single output into a snapcast source. The snapclients (a home-manager
# user service on each box, see modules/snapclient.nix) then play it back
# sample-aligned, with a per-client latency offset tunable at runtime from
# snapweb to compensate for speaker distance.
#
# The trade-off Jukebox forces: the Navidrome *web UI* has no jukebox
# controls, so the remote has to be a Subsonic client that implements them
# (play:Sub, Symfonium, Feishin, DSub). Jukebox.AdminOnly defaults to true
# upstream and is left that way, so the controlling account must be an admin.
{ config, pkgs, lib, ... }:

let
  # snapserver's own RuntimeDirectory is owned by its DynamicUser, so the fifo
  # gets its own directory that both services can be given access to.
  fifoDir = "/run/snapcast";
  fifo = "${fifoDir}/navidrome";

  # Forced identically on both ends of the pipe. A fifo carries raw PCM with
  # no header describing it (see --ao-pcm-waveheader=no below), so snapserver
  # cannot detect a mismatch -- it would just play the bytes at the wrong rate.
  sampleFormat = "48000:16:2";

  snapPort = 1704;      # snapclient connections
  snapwebPort = 1780;   # snapweb: per-client volume and latency trim

  lanSubnet = "10.0.70.0/24";
  tailnet = "100.64.0.0/10";
in
{
  # Owner navidrome (writes), group snapfifo (reads). snapserver keeps
  # DynamicUser and joins that group instead, which is why the fifo is created
  # here rather than by snapserver: with `mode=create` snapcast mkfifo()s it
  # under systemd's 0022 umask, landing on 0644 with a dynamic owner, and
  # navidrome could not write to it.
  users.groups.snapfifo = { };

  systemd.tmpfiles.rules = [
    "d ${fifoDir} 0755 root root -"
    "p ${fifo} 0640 navidrome snapfifo -"
  ];

  services.snapserver = {
    enable = true;
    # Deliberately false: openFirewall opens on every interface, against the
    # scoped rules the rest of this host uses.
    openFirewall = false;
    settings = {
      # mode=read, not the default mode=create: the fifo already exists with
      # the ownership set above and snapserver must not replace it.
      stream.source =
        "pipe://${fifo}?name=Navidrome&mode=read&sampleformat=${sampleFormat}";
      tcp-streaming = {
        enabled = true;
        port = snapPort;
      };
      # The JSON-RPC control socket is only used via snapweb below.
      tcp-control.enabled = false;
      http = {
        enabled = true;
        port = snapwebPort;
      };
    };
  };

  systemd.services.snapserver.serviceConfig.SupplementaryGroups = [ "snapfifo" ];

  services.navidrome.settings = {
    Jukebox.Enabled = true;

    # Absolute path rather than relying on PATH: navidrome runs chrooted into
    # /run/navidrome, where no profile is assembled. /nix/store is already
    # bound in by the upstream unit, so the store path resolves.
    MPVPath = lib.getExe pkgs.mpv;

    # Upstream default is
    #   mpv --audio-device=%d --no-audio-display %f --input-ipc-server=%s
    # Two changes matter:
    #
    #   --ao=pcm --ao-pcm-file      write PCM to the fifo instead of a sound
    #                               card. This also drops --audio-device=%d,
    #                               which has no meaning without a device.
    #   --ao-pcm-waveheader=no      mpv writes a 44-byte WAV header per track
    #                               by default. snapcast reads the fifo as raw
    #                               PCM, so that header would be played as
    #                               samples -- an audible click at every track
    #                               change.
    #
    # The --audio-* flags pin the stream to sampleFormat; without them mpv
    # emits whatever the source file happens to be and the rate silently
    # disagrees with what snapserver was told to expect.
    #
    # --no-config keeps mpv off any user config it might find, since it
    # inherits HOME=/var/lib/navidrome. Arg 0 stays the literal "mpv":
    # navidrome substitutes MPVPath for it, and only for it.
    MPVCmdTemplate = lib.concatStringsSep " " [
      "mpv"
      "--no-config"
      "--no-audio-display"
      "--audio-samplerate=48000"
      "--audio-format=s16"
      "--audio-channels=stereo"
      "--ao=pcm"
      "--ao-pcm-waveheader=no"
      "--ao-pcm-file=${fifo}"
      "%f"
      "--input-ipc-server=%s"
    ];
  };

  systemd.services.navidrome = {
    # snapserver holds the read end open. If it is not running, mpv's
    # open(O_WRONLY) on the fifo blocks, navidrome's 3s wait for the mpv IPC
    # socket times out, and the track fails rather than queueing.
    after = [ "snapserver.service" ];
    wants = [ "snapserver.service" ];

    serviceConfig = {
      # The whole directory rather than the fifo alone: systemd would have to
      # invent a mountpoint for a bare fifo inside the chroot, and a directory
      # bind is unambiguous. Read-write, unlike the library binds -- this is
      # the one thing navidrome writes to.
      BindPaths = [ fifoDir ];

      # Navidrome puts the mpv IPC socket in os.TempDir(), i.e. /tmp. The
      # chroot has no /tmp at all, so without this every jukebox track dies
      # waiting for a socket that could never be created.
      PrivateTmp = true;
    };
  };

  networking.firewall.extraCommands =
    let allow = subnet: port:
      "iptables -A nixos-fw -p tcp -s ${subnet} --dport ${toString port} -j nixos-fw-accept";
    in ''
      ${allow lanSubnet snapPort}
      ${allow tailnet snapPort}
      ${allow lanSubnet snapwebPort}
      ${allow tailnet snapwebPort}
    '';
}
