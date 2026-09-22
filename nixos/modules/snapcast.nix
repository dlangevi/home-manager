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
# The trade-off Jukebox forces: the Navidrome *web UI* has no jukebox controls
# ("Jukebox mode is currently not supported through the Navidrome Web UI"), so
# the remote has to be a Subsonic client that implements the jukeboxControl
# endpoint. That is a short list -- DSub, Ultrasonic or Wavio on Android,
# play:Sub on iOS. Notably Symfonium and Feishin do *not*, despite being the
# obvious picks otherwise; both have the feature open as a request only.
#
# Jukebox.AdminOnly defaults to true upstream and is left that way, so the
# account driving the remote must be an admin.
#
# The third source, and the one meant for day-to-day listening, is MPD. It
# reads both libraries Navidrome serves and writes into its own fifo, but
# unlike the Jukebox leg the control protocol is MPD's own -- so any machine
# can drive the queue with ncmpcpp or mpc (see modules/mpd-client.nix) instead
# of needing a Subsonic client that implements jukeboxControl. One queue and
# one play state live on dance; every client is just a view of it.
#
# A second stream source turns the same speaker group into a Spotify Connect
# target: librespot advertises itself over mDNS as a device any Spotify app
# on the LAN can pick from its Connect device list, decodes whatever gets
# cast to it with no credentials of its own, and writes raw PCM into its own
# fifo the same way the Navidrome/mpv leg does. Which of the two fifos a
# client's group actually plays is chosen at runtime from snapweb -- Nix only
# wires up the sources, not the routing.
{ config, pkgs, lib, ... }:

let
  # snapserver's own RuntimeDirectory is owned by its DynamicUser, so the fifo
  # gets its own directory that both services can be given access to.
  fifoDir = "/run/snapcast";
  fifo = "${fifoDir}/navidrome";
  spotifyFifo = "${fifoDir}/spotify";
  mpdFifo = "${fifoDir}/mpd";

  # MPD takes exactly one music_directory, but the box holds two libraries:
  # the household's (navidrome's MusicFolder) and the neighbour-contributed
  # one, both set up in media-audio.nix. So MPD gets its own root whose only
  # contents are symlinks to those two, giving one database covering both with
  # the libraries still separated as top-level folders in the browse view.
  #
  # Symlinks rather than the bind mounts media-audio.nix uses: those exist to
  # dodge a traversal-permission problem (navidrome cannot enter 0700
  # /home/dance), and a symlink would not have solved it, since traversal is
  # checked against the target's own parents. Here both targets already sit
  # under a world-traversable /srv/media, so there is nothing to dodge and a
  # mount unit would only add ordering to get wrong.
  jpcMusicDir = "/srv/media/jpc-music";
  mpdRoot = "/srv/media/mpd";

  # Forced identically on both ends of the pipe. A fifo carries raw PCM with
  # no header describing it (see --ao-pcm-waveheader=no below), so snapserver
  # cannot detect a mismatch -- it would just play the bytes at the wrong rate.
  sampleFormat = "48000:16:2";

  # Spotify's own streaming rate. librespot has no flag to resample -- only
  # --format to change bit depth -- so this has to match what it emits rather
  # than being picked to match the Navidrome leg.
  spotifySampleFormat = "44100:16:2";

  mpdPort = 6600;       # MPD control protocol, for ncmpcpp/mpc on any machine
  # Second MPD output, alongside the fifo->snapcast leg: a plain HTTP audio
  # stream a browser <audio> element can hit directly. Bound to loopback only.
  # Was reverse-proxied at jpc.dlangevi.com/radio by media-audio.nix; that
  # route was dropped when jpc-landing/radio got consolidated into the
  # media-services frontend checkout and needs re-wiring if the radio page
  # comes back.
  mpdHttpdPort = 8020;

  snapPort = 1704;      # snapclient connections
  snapwebPort = 1780;   # snapweb: per-client volume and latency trim

  # librespot's own HTTP handshake server (the "internal server" its
  # --zeroconf-port advertises); pinned rather than left random so the
  # firewall rule below can scope to a single port.
  spotifyZeroconfPort = 5354;
  spotifyMdnsPort = 5353;

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
    # root:snapfifo rather than a fixed writer user, unlike the Navidrome
    # fifo above: librespot has no reason to run as anything but a
    # DynamicUser, so both ends of this pipe join the snapfifo group instead
    # of one of them owning it outright.
    "p ${spotifyFifo} 0660 root snapfifo -"
    # Owner mpd (writes), group snapfifo (reads) -- the same shape as the
    # Navidrome fifo above, and load-bearing for a reason specific to MPD:
    # upstream's unit sets PrivateUsers=yes, which maps every supplementary
    # group the host grants it to the overflow gid. Group membership in
    # snapfifo would therefore buy MPD nothing; owning the fifo outright is
    # what lets it write.
    "p ${mpdFifo} 0640 mpd snapfifo -"

    # L+ rather than L: it replaces whatever is at the path, so a retargeted
    # library takes effect on the next activation instead of being silently
    # skipped because the link already exists.
    "d ${mpdRoot} 0755 root root -"
    "L+ ${mpdRoot}/music - - - - ${config.services.navidrome.settings.MusicFolder}"
    "L+ ${mpdRoot}/jpc-music - - - - ${jpcMusicDir}"
  ];

  services.snapserver = {
    enable = true;
    # Deliberately false: openFirewall opens on every interface, against the
    # scoped rules the rest of this host uses.
    openFirewall = false;
    settings = {
      # mode=read, not the default mode=create: the fifos already exist with
      # the ownership set above and snapserver must not replace them.
      stream.source = [
        "pipe://${fifo}?name=Navidrome&mode=read&sampleformat=${sampleFormat}"
        "pipe://${spotifyFifo}?name=Spotify&mode=read&sampleformat=${spotifySampleFormat}"
        # Appended rather than made the first source: snapserver assigns the
        # first stream to clients it has never seen, and reordering would only
        # affect those while quietly changing what a fresh client lands on.
        # Point an existing group at "MPD" from snapweb instead.
        "pipe://${mpdFifo}?name=MPD&mode=read&sampleformat=${sampleFormat}"
      ];
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

  # MPD, reading the same library Navidrome serves and playing it into
  # snapcast. Nothing on this box has a sound card worth using, so the fifo is
  # the only output -- MPD here is a queue and a decoder, never a player.
  services.mpd = {
    enable = true;
    # Deliberately false, matching navidrome and snapserver above:
    # openFirewall opens on every interface, against the scoped rules at the
    # bottom of this file. Also silences the module's warning about binding to
    # a non-loopback address without saying anything about the firewall.
    openFirewall = false;
    settings = {
      # The symlink farm built in tmpfiles above, not navidrome's MusicFolder
      # directly -- that would leave the neighbour library invisible to MPD
      # while navidrome serves it. The two still cannot drift: one of the two
      # links is navidrome's own setting.
      music_directory = mpdRoot;

      # Both entries in mpdRoot point outside it, so the default being "yes"
      # is the difference between two libraries and an empty database. Pinned
      # rather than inherited for that reason.
      follow_outside_symlinks = true;

      # The point of the whole arrangement is that clients run elsewhere.
      bind_to_address = "any";
      port = mpdPort;

      audio_output = [
        {
          type = "fifo";
          name = "Snapcast";
          path = mpdFifo;
          # Forced to match the stream source above for the same reason the
          # Navidrome leg is: a fifo carries raw PCM with no header, so a
          # mismatch is not detected, it is just played at the wrong rate.
          format = sampleFormat;
          # The fifo plugin has no hardware mixer, so without this MPD reports
          # no volume control at all and ncmpcpp's volume keys do nothing.
          # Snapcast's own per-client volume still applies on top; this one is
          # the master.
          mixer_type = "software";
        }
        {
          # For the (currently unrouted, see mpdHttpdPort above) radio page:
          # an independent MPD output, decoded
          # and encoded on demand for whatever HTTP clients connect, separate
          # from the fifo leg above (MPD supports multiple simultaneous
          # outputs; this one has nothing to do with snapcast's shared clock).
          type = "httpd";
          name = "Radio";
          bind_to_address = "127.0.0.1";
          port = toString mpdHttpdPort;
          encoder = "vorbis";
          quality = "5";
          format = "48000:16:2";
          # Own mixer, since this leg has no bearing on the snapcast/jukebox
          # master volume above.
          mixer_type = "software";
        }
      ];
    };
  };

  # No ordering against snapserver, unlike navidrome below. MPD's fifo output
  # opens both ends itself, so a missing reader costs it nothing -- it
  # discards into its own read fd rather than blocking on write.

  # Spotify Connect receiver. No credentials configured here on purpose --
  # zeroconf mode hands the login off to whatever official Spotify app casts
  # to it, the same way a Sonos or Chromecast target works, so nothing
  # secret needs to live in this repo.
  systemd.services.librespot = {
    # Working, but off for now -- flip back to true to re-enable.
    enable = false;
    description = "Spotify Connect receiver, feeding snapserver's Spotify stream";
    wantedBy = [ "multi-user.target" ];
    # Same ordering reason as navidrome below: snapserver must hold the read
    # end of the fifo open before librespot's open(O_WRONLY) can succeed.
    after = [ "network-online.target" "snapserver.service" ];
    wants = [ "network-online.target" "snapserver.service" ];
    serviceConfig = {
      DynamicUser = true;
      SupplementaryGroups = [ "snapfifo" ];
      ExecStart = lib.concatStringsSep " " [
        (lib.getExe pkgs.librespot)
        "--name Snapcast"
        "--backend pipe"
        "--device ${spotifyFifo}"
        "--format S16"
        "--bitrate 320"
        "--disable-audio-cache"
        "--disable-credential-cache"
        "--zeroconf-port ${toString spotifyZeroconfPort}"
      ];
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

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
    let
      allow = subnet: port:
        "iptables -A nixos-fw -p tcp -s ${subnet} --dport ${toString port} -j nixos-fw-accept";
      allowUdp = subnet: port:
        "iptables -A nixos-fw -p udp -s ${subnet} --dport ${toString port} -j nixos-fw-accept";
    in ''
      ${allow lanSubnet mpdPort}
      ${allow tailnet mpdPort}
      ${allow lanSubnet snapPort}
      ${allow tailnet snapPort}
      ${allow lanSubnet snapwebPort}
      ${allow tailnet snapwebPort}
      ${allow lanSubnet spotifyZeroconfPort}
      ${allow tailnet spotifyZeroconfPort}
      # mDNS is LAN-only: it relies on multicast, which Tailscale doesn't
      # carry, so there's no tailnet rule to add here.
      ${allowUdp lanSubnet spotifyMdnsPort}
    '';
}
