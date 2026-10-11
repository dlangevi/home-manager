# The literary agent querying interface (~/auto/assistant/querying), a page
# listing the agent records plus a button that runs a scoped `claude -p` job
# in a git worktree. Runs the checked-out clone directly -- no build step,
# just uvicorn pointed at the repo, same as album-requests.nix.
#
# Reachable from the LAN and the tailnet, behind a password. It was loopback
# only, with an SSH tunnel as the whole access-control story; that is still the
# way in from outside, but the page is wanted on other machines in the house:
#
#   ssh -L 8200:127.0.0.1:8200 dance@dance     # from away
#   http://dance:8200                          # from the LAN
#
# The password is not a formality. Unlike the media services this holds the
# agents' contact details and draft query letters, and its buttons spend
# tokens on an unattended `claude -p` run and merge branches into `main`.
# web/auth.py enforces it and fails closed: with no QUERYING_PASSWORD in the
# environment it serves loopback and refuses everyone else, so a missing
# secret cannot quietly publish the records.
#
# Still NOT reverse-proxied, so this is basic auth over plain HTTP -- the
# credential crosses the LAN base64-encoded on every request. Adequate against
# someone opening a browser on the same network, worth nothing against someone
# watching the wire. TLS means the nginx vhost nothing else on this box has.
{ config, pkgs, lib, ... }:

let
  repoDir = "/home/dance/auto/assistant/querying";
  port = 8200;

  # Same values the other LAN-scoped services on this box use.
  lanSubnet = "10.0.70.0/24";
  tailnet = "100.64.0.0/10";

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

      # 0.0.0.0, not 127.0.0.1: the firewall rule below reaches nothing if the
      # socket is not listening on the LAN interface in the first place.
      ExecStart = "${pythonEnv}/bin/uvicorn web.app:app --host 0.0.0.0 --port ${toString port}";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # Scoped to the LAN and the tailnet rather than opened with
  # allowedTCPPorts, which would accept the port on every interface. Same
  # helper shape as mympd.nix and snapcast.nix.
  networking.firewall.extraCommands =
    let
      allow = subnet:
        "iptables -A nixos-fw -p tcp -s ${subnet} --dport ${toString port} -j nixos-fw-accept";
    in ''
      ${allow lanSubnet}
      ${allow tailnet}
    '';
}
