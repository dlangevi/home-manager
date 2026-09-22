{
  "console"  = [ "base" "desktop-apps" "mpd-client" "soulseek" "herd" ];
  "dance"    = [ "base" "desktop-apps" "streaming" "music-server" "snapclient" "mpd-client" "herd" ];
  # slskd (nixos/modules/slskd.nix) is the acquisition backend for
  # music-mgmt's ingestion queue -- Nicotine+ has no API a script could ever
  # drive. Nicotine+ ("soulseek" feature) stays on console and suspense
  # anyway for David's own personal, manual use.
  "suspense" = [ "base" "dev" "herd" "desktop-apps" "gaming" "documents" "plasma" "snapclient" "mpd-client" "soulseek" ];
}
