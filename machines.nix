{
  # blur is an underpowered laptop with a tired battery -- it gets chat-apps
  # (messaging is worth the Electron weight) but not media-apps (OBS,
  # Kdenlive, GIMP are occasional-use and heavy even idle).
  "blur"     = [ "base" "desktop-apps" "chat-apps" "herd" "sway" ];
  # chonk was registered while `desktop-apps` was still the monolith that
  # also carried chat and media apps. That feature has since been split
  # three ways, and this list is its registration taken literally, so chonk
  # currently gets neither chat-apps nor media-apps -- add them if it turns
  # out to want them.
  #
  # Also an underpowered laptop (2010 Core i5, nouveau GT218) -- gets sway
  # the same way blur does; see nixos/hosts/chonk.nix for the rest of that.
  "chonk"    = [ "base" "desktop-apps" "herd" "sway" ];
  "console"  = [ "base" "desktop-apps" "chat-apps" "media-apps" "mpd-client" "soulseek" "herd" "wake-suspense" ];
  "dance"    = [ "base" "desktop-apps" "chat-apps" "media-apps" "streaming" "music-server" "snapclient" "mpd-client" "herd" ];
  # slskd (nixos/modules/slskd.nix) is the acquisition backend for
  # the album-requests ingestion queue (~/auto/media-services) -- Nicotine+ has no API a script could ever
  # drive. Nicotine+ ("soulseek" feature) stays on console and suspense
  # anyway for David's own personal, manual use.
  "suspense" = [ "base" "dev" "herd" "desktop-apps" "chat-apps" "media-apps" "anki" "gaming" "documents" "plasma" "snapclient" "mpd-client" "soulseek" "sway" ];
}
