# Spoken-word context for the Frame Art slideshow: holding Left on the
# remote asks this service to identify the painting on screen and read out
# a short history of it. Everything runs locally on dance, so the feature
# needs no external account or API key:
#  - identification and the blurb come from `claude -p`, reusing the
#    credentials already live in /home/dance/.claude/ (same reuse as
#    querying.nix).
#  - speech comes from Piper, a local/offline TTS engine -- no network call
#    and no per-request cost once the voice model is fetched at build time.
# Output is cached under siteDir/narration and served by the existing
# frameart nginx vhost (frameart-host.nix) on its usual port 8088, so this
# module only runs the generation step; it does not serve the audio files
# itself.
{ config, pkgs, lib, ... }:

let
  siteDir = "/srv/www/frameart";
  appDir = ./frameart-narrate;
  port = 8089;

  # Same subnets frameart-host.nix opens on 8088: the monitor's own home
  # router subnet (not dance's LAN), dance's LAN, and the tailnet.
  monitorSubnet = "192.168.0.0/24";
  lanSubnet = "10.0.70.0/24";
  tailnet = "100.64.0.0/10";

  # Pinned at the file level (fetchurl, not a voice-download step at
  # runtime) so the service never needs network access to speak. Piper
  # looks for the config next to the model under the model's own name with
  # ".json" appended -- passing -c explicitly does not override that in
  # 1.4.2 -- so both files are linked into one directory under a shared
  # "voice" basename.
  voiceModel = pkgs.fetchurl {
    url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx";
    sha256 = "17q1mzm6xd5i2rxx2xwqkxvfx796kmp1lvk4mwkph602k7k0kzjy";
  };
  voiceConfig = pkgs.fetchurl {
    url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json";
    sha256 = "184hnvd8389xpdm0x2w6phss23v5pb34i0lhd4nmy1gdgd0rrqgg";
  };
  voiceDir = pkgs.linkFarm "frameart-narrate-voice" [
    { name = "voice.onnx"; path = voiceModel; }
    { name = "voice.onnx.json"; path = voiceConfig; }
  ];

  pythonEnv = pkgs.python3.withPackages (ps: with ps; [ fastapi uvicorn pydantic ]);
in
{
  # siteDir itself comes from frameart-host.nix; this just adds the
  # subdirectory the service writes into, owned by the same user.
  systemd.tmpfiles.rules = [
    "d ${siteDir}/narration 0755 dance users -"
  ];

  systemd.services.frameart-narrate = {
    description = "Frame Art spoken-history narration relay";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "simple";
      User = "dance";
      Group = "users";
      WorkingDirectory = toString appDir;
      # /home/dance/.nix-profile/bin last and deliberately: that is where
      # the authenticated `claude` lives (querying.nix explains why it
      # cannot come from this module).
      Environment = [
        "FRAMEART_IMAGES_DIR=${siteDir}"
        "PIPER_VOICE_MODEL=${voiceDir}/voice.onnx"
        "PATH=${lib.makeBinPath [ pkgs.piper-tts pythonEnv ]}:/home/dance/.nix-profile/bin:/run/current-system/sw/bin"
      ];
      ExecStart = "${pythonEnv}/bin/uvicorn app:app --host 0.0.0.0 --port ${toString port}";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  networking.firewall.extraCommands =
    let
      allow = subnet:
        "iptables -A nixos-fw -p tcp -s ${subnet} --dport ${toString port} -j nixos-fw-accept";
    in ''
      ${allow monitorSubnet}
      ${allow lanSubnet}
      ${allow tailnet}
    '';
}
