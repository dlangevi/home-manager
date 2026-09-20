{
  "console"  = [ "base" "desktop-apps" "mpd-client" ];
  "dance"    = [ "base" "desktop-apps" "streaming" "music-server" "snapclient" "mpd-client" "herd" ];
  # "soulseek" (Nicotine+) dropped: slskd (nixos/modules/slskd.nix, imported
  # directly by nixos/hosts/suspense.nix) replaces it as the acquisition
  # backend for music-mgmt's ingestion queue, since Nicotine+ has no API a
  # script could ever drive.
  "suspense" = [ "base" "dev" "herd" "desktop-apps" "gaming" "documents" "plasma" "snapclient" "mpd-client" ];
}
