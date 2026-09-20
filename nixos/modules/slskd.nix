# slskd, a headless Soulseek daemon with a REST API -- replaces Nicotine+
# (../modules/soulseek.nix) as the acquisition backend for music-mgmt's
# ingestion queue (request.jpc.dlangevi.com, served from dance).
#
# Nicotine+ has no API/CLI/RPC surface at all, so nothing on dance could ever
# drive a search+download programmatically against it. slskd exists
# specifically for this: same Soulseek network, but with a REST API a script
# can call to search, pick a result, and enqueue a download, plus a web UI
# for manual use exactly like Nicotine+'s GUI gave.
#
# NixOS-level (this machine's the daemon owner) rather than home-manager, and
# system-wide rather than per-user: this is a network-listening service, not
# a GUI app one user launches, so it belongs alongside sunshine/resilio in
# this host's own imports, not the features.nix list home-manager reads.
{ config, pkgs, lib, ... }:

let
  # slskd's own web API/UI port. Reachable from dance (running the ingestion
  # service) over the tailnet only -- see firewall rule in suspense.nix.
  webPort = 5030;

  # Where finished downloads land. This is suspense's sshfs mount of dance's
  # storage (dance-storage.nix), so a finished album is immediately visible
  # to dance's tag/art/publish pipeline with no extra transfer step.
  downloadsDir = "/mnt/dance/storage/collective-import/.staging";
in
{
  services.slskd = {
    enable = true;
    # Soulseek listening port stays firewalled the same way Nicotine+'s was;
    # openFirewall here only covers that port, not the web API (webPort),
    # which is scoped explicitly in suspense.nix's own firewall block
    # instead since it needs a source-subnet restriction openFirewall can't
    # express.
    openFirewall = true;

    # SLSKD_SLSK_USERNAME / SLSKD_SLSK_PASSWORD (Soulseek network login) and
    # SLSKD_USERNAME / SLSKD_PASSWORD (web UI/API login) live here, created
    # out of band -- same pattern as media-audio.nix's Cloudflare credentials
    # file. root:root 600.
    environmentFile = "/var/lib/secrets/slskd.env";

    settings = {
      directories.downloads = downloadsDir;
      web.port = webPort;
      # Bound to the tailnet-reachable address implicitly via the firewall
      # rule in suspense.nix rather than restricted here -- slskd itself
      # just needs to listen on all interfaces for that rule to have
      # anything to scope.
      web.address = "0.0.0.0";
      # API key auth (set via SLSKD_API_KEY in environmentFile, or generated
      # on first run and read back out of slskd's own data dir) is what the
      # ingestion service on dance authenticates with -- separate from the
      # web.authentication username/password meant for a human hitting the
      # UI directly.
    };
  };

  systemd.tmpfiles.rules = [
    "d ${downloadsDir} 0755 slskd users -"
  ];
}
