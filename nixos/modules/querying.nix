# The literary agent querying interface (~/auto/assistant/querying), a page
# listing the agent records plus a button that runs a scoped `claude -p` job
# in a git worktree. Runs the checked-out clone directly -- no build step,
# just uvicorn pointed at the repo, same as album-requests.nix.
#
# Reverse-proxied under the existing jpc.dlangevi.com TLS vhost (media-audio.nix)
# rather than reachable directly on its own port. It was loopback only, with
# an SSH tunnel as the whole access-control story, then briefly LAN+tailnet on
# plain HTTP; that let the basic-auth credential cross the wire
# base64-encoded and in the clear. The reverse proxy gets it the TLS the rest
# of this box's vhosts already have, for free.
#
# The password is not a formality. Unlike the media services this holds the
# agents' contact details and draft query letters, and its buttons spend
# tokens on an unattended `claude -p` run and merge branches into `main`.
# web/auth.py enforces it and fails closed: with no QUERYING_PASSWORD in the
# environment it serves loopback and refuses everyone else, so a missing
# secret cannot quietly publish the records.
{ config, pkgs, lib, ... }:

let
  repoDir = "/home/dance/auto/assistant/querying";
  port = 8200;

  # Same domain media-audio.nix already issues a wildcard ACME cert for --
  # covers this subdomain for free. Needs its own A-record override on the
  # UDM Pro, same as every other *.jpc.dlangevi.com name (see that module's
  # comments on mpdSubdomain).
  jpcDomain = "jpc.dlangevi.com";
  querySubdomain = "query.${jpcDomain}";

  # Mirrors the project's own flake devShell. Kept in step by hand: this box
  # runs the repo, it does not build it, so there is no single source for the
  # two lists to share.
  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    google-api-python-client
    google-auth-httplib2
    google-auth-oauthlib
    tomlkit
    fastapi
    uvicorn
  ]);
in
{
  systemd.services.querying = {
    description = "literary agent querying interface (127.0.0.1 only)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "simple";
      User = "dance";
      Group = "users";
      WorkingDirectory = repoDir;

      # git: web/worktree.py shells out to it for every job -- create the
      # worktree, read the diff, merge on approval.
      #
      # /home/dance/.nix-profile/bin last and deliberately: that is where the
      # authenticated `claude` lives (its credentials are in
      # /home/dance/.claude/), and it is installed into dance's own profile
      # rather than by this module. A job cannot run without it, and nothing
      # here can provide it -- `claude` is not in nixpkgs.
      Environment =
        "PATH=${lib.makeBinPath [ pkgs.git pythonEnv ]}:/home/dance/.nix-profile/bin:/run/current-system/sw/bin";

      # QUERYING_USER / QUERYING_PASSWORD, created out of band and gitignored
      # (secrets/), the same shape album-requests.nix uses. Deliberately not a
      # Nix value: the store is world-readable. The unit will not start until
      # this file exists, which is the intended order -- write the secret,
      # then switch.
      EnvironmentFile = "/home/dance/.config/home-manager/secrets/querying.env";

      # Loopback only now: nginx is the only thing that needs to reach this,
      # and it's co-located on dance. No firewall rule needed.
      ExecStart = "${pythonEnv}/bin/uvicorn web.app:app --host 127.0.0.1 --port ${toString port}";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  services.nginx.virtualHosts.${querySubdomain} = {
    useACMEHost = jpcDomain;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString port}";
    };
  };
}
