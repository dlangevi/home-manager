# The ingestion queue web app itself (~/auto/media-services, its own
# standalone tree separate from music-mgmt), reverse-proxied at
# jpc.dlangevi.com/request by media-audio.nix. Runs the checked-out tree
# directly -- no separate deployment/build step, just uvicorn pointed at
# the repo.
{ config, pkgs, lib, ... }:

let
  repoDir = "/home/dance/auto/media-services";
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
  systemd.services.album-requests = {
    description = "album-requests ingestion queue (jpc.dlangevi.com/request backend)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    # SLSKD_URL / SLSKD_API_KEY (pointing at slskd on this same host,
    # slskd.nix) live here, created out of band -- gitignored (*.env,
    # secrets/) so it never lands in the repo despite sitting inside its
    # checkout.
    serviceConfig = {
      Type = "simple";
      User = "dance";
      Group = "users";
      WorkingDirectory = repoDir;
      EnvironmentFile = "/home/dance/.config/home-manager/secrets/album-requests.env";
      # opustags/file/curl/jq: pipeline.py and bin/fetch-*-images shell out
      # to these, matching what the flake devShell provides interactively.
      Environment = "PATH=${lib.makeBinPath [ pkgs.opustags pkgs.file pkgs.curl pkgs.jq pythonEnv ]}:/run/current-system/sw/bin";
      ExecStart = "${pythonEnv}/bin/uvicorn backend.app:app --host 127.0.0.1 --port ${toString port}";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
