# Music streaming: Navidrome.
#
# Split out of media-video.nix because audio moved off the workstation. dance is
# a Beelink SER8 that idles at 8-9 W and is already on 24/7, against suspense's
# 60-80 W -- roughly $72/yr at Seattle City Light's 13.38c/kWh. Audio never
# transcodes on the LAN, so this host needs no GPU, no VAAPI and no transcoding
# headroom; Navidrome itself runs in ~50 MB and speaks Subsonic natively.
#
# LAN plus tailnet only.
{ config, pkgs, lib, ... }:

let
  # /srv/media rather than under /home/dance, which is 0700 and would hide the
  # library from the navidrome service user. Because the media is not inside a
  # home directory here, this host needs none of the read-only bind mounts
  # media-video.nix uses to work around exactly that problem.
  #
  # It also lands on the root NVMe (786 GB free) rather than the storage NVMe,
  # whose remaining 400 GB is being eaten by OBS/ITG recordings.
  musicDir = "/srv/media/music";

  lanSubnet = "10.0.70.0/24";
  # Tailscale hands out addresses from the CGNAT range. Scoping to this rather
  # than trusting tailscale0 wholesale keeps the same posture as the LAN rule:
  # only the one port is reachable, not every service on the box.
  tailnet = "100.64.0.0/10";
  navidromePort = 4533;
in
{
  # 0755 because the navidrome unit uses DynamicUser, so there is no stable uid
  # to grant access to; dance owns the directory so rsync can write into it.
  systemd.tmpfiles.rules = [
    "d /srv/media 0755 root root -"
    "d ${musicDir} 0755 dance users -"
  ];

  services.navidrome = {
    enable = true;
    # Deliberately false: openFirewall opens on every interface. The scoped
    # rules below are the point.
    openFirewall = false;
    settings = {
      MusicFolder = musicDir;
      Address = "0.0.0.0";
      Port = navidromePort;
      # The library is large and mostly static. Full rescans only when tags
      # change, not on every startup.
      ScanSchedule = "@every 24h";
    };
  };

  # Remote access. No port forwarding, no dynamic DNS, works through CGNAT.
  services.tailscale = {
    enable = true;
    # Without this the daemon cannot accept inbound UDP on 41641, so peers fall
    # back to DERP relays -- which works, but adds latency.
    openFirewall = true;
  };

  networking.firewall.extraCommands =
    let allow = subnet:
      "iptables -A nixos-fw -p tcp -s ${subnet} --dport ${toString navidromePort} -j nixos-fw-accept";
    in ''
      ${allow lanSubnet}
      ${allow tailnet}
    '';
}
