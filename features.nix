{ dl-herd, music-mgmt, plasma-manager, ... }:
{
  base         = [ ./modules/base.nix ];
  dev          = [ ./modules/dev.nix ];
  herd         = [ dl-herd.homeModules.default ];
  desktop-apps = [ ./modules/desktop-apps.nix ];
  documents    = [ ./modules/documents.nix ];
  gaming       = [ ./modules/gaming.nix ];
  media        = [ ./modules/media.nix ];
  # cdrip, on the machine with the optical drive.
  music        = [ music-mgmt.homeModules.default ];
  # beets on the machine that holds the library, for reading the database
  # cdrip publishes. Local rather than from the music-mgmt flake: that is a
  # `path:` input, which only resolves on the machine holding the repo.
  music-server = [ ./modules/music-server.nix ];
  plasma       = [ ./modules/plasma.nix plasma-manager.homeModules.plasma-manager ];
  snapclient   = [ ./modules/snapclient.nix ];
  soulseek     = [ ./modules/soulseek.nix ];
  streaming    = [ ./modules/streaming.nix ];
}
