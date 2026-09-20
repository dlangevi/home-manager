# The ingestion queue web app itself (music-mgmt/ingest), reverse-proxied at
# request.jpc.dlangevi.com by media-audio.nix. Runs the checked-out
# ~/auto/music-mgmt tree directly, the same way its CLI tooling is run by
# hand today -- no separate deployment/build step, just uvicorn pointed at
# the repo.
{ config, pkgs, lib, ... }:

let
  repoDir = "/home/dance/auto/music-mgmt";
  port = 8100; # matches media-audio.nix's ingestPort

  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    mutagen
    fastapi
    uvicorn
    httpx
    pydantic
  ]);
in
{
  systemd.services.music-mgmt-ingest = {
    description = "music-mgmt ingestion queue (request.jpc.dlangevi.com backend)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    # SLSKD_URL / SLSKD_API_KEY (pointing at suspense's slskd, slskd.nix)
    # live here, created out of band like the other credentials files in
    # this repo -- root:root 600, readable because the unit runs as root
    # via EnvironmentFile below despite executing as user dance.
    serviceConfig = {
      Type = "simple";
      User = "dance";
      Group = "users";
      WorkingDirectory = repoDir;
      EnvironmentFile = "/var/lib/secrets/music-mgmt-ingest.env";
      # opustags/file/curl/jq: pipeline.py and bin/fetch-*-images shell out
      # to these, matching what the flake devShell provides interactively.
      Environment = "PATH=${lib.makeBinPath [ pkgs.opustags pkgs.file pkgs.curl pkgs.jq pythonEnv ]}:/run/current-system/sw/bin";
      ExecStart = "${pythonEnv}/bin/uvicorn ingest.app:app --host 127.0.0.1 --port ${toString port}";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
