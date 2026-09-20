# myMPD: a web remote for the MPD instance in snapcast.nix, for driving the
# shared queue from a browser instead of ncmpcpp or a phone app.
#
# This is a second front end on the same queue, not a second library. MPD
# already holds one queue and one play state for the whole house (see the
# header of snapcast.nix), so what myMPD shows is exactly what ncmpcpp and
# MALP show -- it is a view, and closing the tab stops nothing.
#
# It does not replace Navidrome. Navidrome stays the multi-user, per-account
# library the household and its guests use; this is a personal remote with no
# user model at all, which is why it is scoped to the LAN and the tailnet and
# given no auth of its own.
#
# Reachable two ways: directly on its port (below), and as
# https://mpd.jpc.dlangevi.com through the nginx vhost in media-audio.nix. The
# direct port stays open deliberately -- it is the fallback when DNS or the
# cert is the thing that is broken.
#
# myMPD rather than ympd: nixpkgs carries both, but ympd is 1.3.0 and has been
# dead since 2018. myMPD is the same author's successor, actively released
# (25.x here), and the only other web MPD client packaged at all.
{ config, lib, ... }:

let
  httpPort = 8580;

  lanSubnet = "10.0.70.0/24";
  tailnet = "100.64.0.0/10";
in
{
  services.mympd = {
    enable = true;
    # Deliberately false, matching every other service on this box:
    # openFirewall opens on every interface, against the scoped rules below.
    openFirewall = false;
    settings = {
      # Upstream defaults to 80, which nginx already holds here for the
      # landing page (media-audio.nix).
      http_port = httpPort;
    };
  };

  # The NixOS module's `settings` only writes myMPD's *config* directory,
  # which covers the http/ssl options and nothing else. MPD connection and
  # music directory are runtime *state*, owned by the web UI -- so they cannot
  # be declared here, and two fields have to be set once under
  # "MPD connection" on first run:
  #
  #   Host             127.0.0.1        (pre-seeded by the env below)
  #   Music directory  /srv/media/mpd   (mpdRoot from snapcast.nix)
  #
  # The music directory is what lets myMPD read cover art off disk; without it
  # it falls back to MPD's own albumart command, which works but is slower and
  # misses anything not embedded. Same shape as the one-time setup Navidrome
  # and snapweb already need -- Nix wires the service up, the app's own UI
  # owns its runtime state.
  #
  # MPD_HOST/MPD_PORT are read only on first start, and only when no host is
  # recorded in the state directory yet. Set because myMPD's autodetection
  # otherwise probes for a unix socket -- /run/mpd/socket and friends -- which
  # this MPD does not have, since it binds TCP only.
  systemd.services.mympd.environment = {
    MPD_HOST = "127.0.0.1";
    MPD_PORT = toString config.services.mpd.settings.port;
  };

  networking.firewall.extraCommands =
    let
      allow = subnet: port:
        "iptables -A nixos-fw -p tcp -s ${subnet} --dport ${toString port} -j nixos-fw-accept";
    in ''
      ${allow lanSubnet httpPort}
      ${allow tailnet httpPort}
    '';
}
