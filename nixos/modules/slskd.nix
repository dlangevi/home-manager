# slskd, a headless Soulseek daemon with a REST API -- the acquisition
# backend for the album-requests ingestion queue (~/auto/media-services,
# served from dance). Runs on dance itself, alongside the ingestion service
# that drives it -- this serves neighbours' requests and needs to be up
# whenever dance is, unlike suspense which sleeps. Nicotine+ stays on
# suspense (../modules/soulseek.nix) for David's own personal use; it has no
# API/CLI/RPC surface at all, so nothing could ever drive it
# programmatically, which is why slskd exists as a separate daemon rather
# than reusing it.
#
# NixOS-level rather than home-manager, and system-wide rather than
# per-user: this is a network-listening service, not a GUI app one user
# launches, so it belongs alongside media-audio/snapcast in this host's own
# imports, not the features.nix list home-manager reads.
{ config, pkgs, lib, ... }:

let
  # slskd's own web API/UI port. Only the ingestion service (same host, see
  # album-requests.nix) needs to reach it, so it's bound to loopback only
  # -- no firewall rule required.
  webPort = 5030;

  # Where finished downloads land -- the ingestion service's own staging
  # root (media-services/backend/app.py's STAGING_ROOT). Must NOT be under /home: slskd's
  # default hardening sets ProtectHome=true/ProtectSystem=strict, which
  # masks /home entirely regardless of ReadWritePaths. /srv/media is
  # already the writable, non-/home location this pipeline publishes into
  # (see media-audio.nix's collectiveImportDir / pipeline.py's
  # COLLECTIVE_IMPORT_ROOT), so stage into a hidden subfolder there.
  downloadsDir = "/srv/media/collective-import/.staging";
in
{
  services.slskd = {
    enable = true;
    # Soulseek listening port (P2P transfers, not the web API) -- same
    # firewall treatment Nicotine+'s port got on suspense.
    openFirewall = true;

    # SLSKD_SLSK_USERNAME / SLSKD_SLSK_PASSWORD (Soulseek network login) and
    # SLSKD_USERNAME / SLSKD_PASSWORD (web UI/API login) live here, created
    # out of band -- gitignored (*.env, secrets/) so it never lands in the
    # repo despite sitting inside its checkout.
    environmentFile = "/home/dance/.config/home-manager/secrets/slskd.env";

    settings = {
      directories.downloads = downloadsDir;
      # Share the household library back to the Soulseek network -- read-only
      # (already mounted ro at /srv/media/music; the module also adds it to
      # ReadOnlyPaths regardless), world-readable (755 dance:users), so
      # slskd's own user can traverse it with no extra permission changes.
      #
      # /srv/media/music is still a work in progress -- the "!" prefix
      # excludes a subtree entirely rather than by filename, needed for
      # Reckoner Stems' GarageBand project bundle: the officially-released
      # stem mp3s next to it are fine to share, but the bundle itself is
      # just someone's derivative DAW project (.caf/.plist/.tiff internals,
      # no real audio releases), not something to hand out to random peers.
      shares.directories = [
        "/srv/media/music"
        "!/srv/media/music/Radiohead/Reckoner Stems/Reckoner GarageBand '08.band"
      ];
      shares.filters = [
        "\\.ini$"
        "Thumbs\\.db$"
        "\\.DS_Store$"
        "\\.reapeaks$"       # Reaper peak-cache scratch files, not audio
        "\\.url$"            # dead Windows shortcuts to old release-group promo pages
        "\\.message$"        # scene-group boilerplate text, not real metadata
        "_____padding_file_.*____$" # BitComet torrent padding filler
      ];
      web.port = webPort;
      # Loopback only: the ingestion service is the only consumer and it's
      # co-located on dance. Change to "0.0.0.0" + a tailnet firewall rule
      # if the web UI ever needs remote access for manual searches.
      web.address = "127.0.0.1";
      # API key auth (set via SLSKD_API_KEY in environmentFile, or generated
      # on first run and read back out of slskd's own data dir) is what the
      # ingestion service authenticates with -- separate from the
      # web.authentication username/password meant for a human hitting the
      # UI directly.
    };
  };

  # slskd creates its own per-album directories under downloadsDir at its
  # own default umask (022 -> 755), which leaves them group-read-only --
  # the setgid bit on downloadsDir only inherits the *group*, not write
  # permission. Without this, the ingestion service (user dance, only in
  # group users) can copy files out of a finished download but can't
  # delete them afterwards, and shutil.move throws mid-move. Same fix as
  # resilio's UMask override in suspense.nix.
  systemd.services.slskd.serviceConfig.UMask = "0002";

  # 2775 + group "users": both slskd (writing downloaded files) and dance
  # (the ingestion service, creating per-request subdirectories) need write
  # access here. Setgid so subdirectories dance creates stay group "users"
  # too, same pattern as resilio's shared tree in suspense.nix.
  systemd.tmpfiles.rules = [
    "d ${downloadsDir} 2775 slskd users -"
  ];
}
