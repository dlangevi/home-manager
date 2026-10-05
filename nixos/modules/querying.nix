# The literary agent querying interface (~/auto/assistant/querying), a page
# listing the agent records plus a button that runs a scoped `claude -p` job
# in a git worktree. Runs the checked-out clone directly -- no build step,
# just uvicorn pointed at the repo, same as album-requests.nix.
#
# Deliberately NOT reverse-proxied. Unlike the media services this holds
# agents' contact details and draft query letters, and it has a button that
# spends tokens, so it is bound to 127.0.0.1 and reached over an SSH tunnel:
#
#   ssh -L 8200:127.0.0.1:8200 dance@dance
#
# Publishing it later means adding an nginx vhost and deciding on auth, which
# nothing else on this box does yet. Until there is a reason, a tunnel is the
# whole access-control story.
{ config, pkgs, lib, ... }:

let
  repoDir = "/home/dance/auto/assistant/querying";
  port = 8200;

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

      ExecStart = "${pythonEnv}/bin/uvicorn web.app:app --host 127.0.0.1 --port ${toString port}";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # No firewall rule, by design. 127.0.0.1 is not reachable from the LAN or the
  # tailnet, and the absence of a rule here is what keeps it that way.
}
