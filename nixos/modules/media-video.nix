# Video streaming: Jellyfin.
#
# Audio used to live here too, but Navidrome moved to `dance` -- a Beelink SER8
# that idles at 8-9 W against this box's 60-80 W and is already on 24/7. See
# media-audio.nix. This host keeps video because it has the GPU.
#
# LAN plus tailnet only.
{ config, pkgs, lib, ... }:

let
  # Media lives under /home/dlangevi, which is 0700 -- the jellyfin service
  # user cannot traverse into it and would see nothing.
  #
  # Bind mounts sidestep this: permission checks apply to the components of the
  # NEW path, not the original's parents. The alternative, chmod o+x on the home
  # directory, would weaken it for every service on the box to solve a problem
  # this solves cleanly.
  mediaRoot = "/home/dlangevi/storage";
  libraries = [ "movies" "shows" "recordings" ];

  bindMount = name: {
    name = "/srv/media/${name}";
    value = {
      device = "${mediaRoot}/${name}";
      fsType = "none";
      options = [ "bind" "ro" ];   # neither server should ever write to the library
      # Without this the bind can run before sdb2 is mounted, silently binding
      # an empty directory.
      depends = [ mediaRoot ];
    };
  };

  lanSubnet = "10.0.70.0/24";
  # Tailscale hands out addresses from the CGNAT range. Scoping to this rather
  # than trusting tailscale0 wholesale keeps the same posture as the LAN rule:
  # only the two media ports are reachable, not every service on the box.
  tailnet = "100.64.0.0/10";
  jellyfinPort = 8096;
in
{
  fileSystems = builtins.listToAttrs (map bindMount libraries);

  services.jellyfin = {
    enable = true;
    # Deliberately false: openFirewall opens on every interface. The LAN-scoped
    # rule below is the point.
    openFirewall = false;
  };

  # jellyfin-ffmpeg needs the NVIDIA userspace to reach NVENC. /dev/nvidia* are
  # already mode 0666 so no group plumbing is required.
  #
  # GTX 1060 is Pascal: H.264 + HEVC 8-bit encode only, no AV1, no 10-bit HEVC
  # encode. HDR->SDR tone mapping works. Realistically 2-3 concurrent transcodes.
  hardware.graphics.extraPackages = with pkgs; [ nvidia-vaapi-driver ];

  # Remote access. No port forwarding, no dynamic DNS, works through CGNAT.
  services.tailscale = {
    enable = true;
    # Without this the daemon cannot accept inbound UDP on 41641, so peers fall
    # back to DERP relays -- which works, but adds latency and routes your
    # stream through Tailscale's infrastructure instead of point-to-point.
    openFirewall = true;
  };

  networking.firewall.extraCommands =
    let allow = subnet: port:
      "iptables -A nixos-fw -p tcp -s ${subnet} --dport ${toString port} -j nixos-fw-accept";
    in ''
      ${allow lanSubnet jellyfinPort}
      ${allow tailnet jellyfinPort}
    '';
}
