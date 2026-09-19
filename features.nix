{ dl-herd, plasma-manager, ... }:
{
  base         = [ ./modules/base.nix ];
  dev          = [ ./modules/dev.nix ];
  herd         = [ dl-herd.homeModules.default ];
  desktop-apps = [ ./modules/desktop-apps.nix ];
  documents    = [ ./modules/documents.nix ];
  gaming       = [ ./modules/gaming.nix ];
  media        = [ ./modules/media.nix ];
  mpd-client   = [ ./modules/mpd-client.nix ];
  # There is no `music` feature. cdrip and slsk live in ~/auto/music-mgmt and
  # are run from that tree through direnv, so nothing about them is deployed:
  # no package, no config file, nothing for this repo to install.
  #
  # beets on the machine that holds the library, for reading the database
  # cdrip publishes. Local rather than from the music-mgmt flake, which is
  # not an input here at all any more.
  music-server = [ ./modules/music-server.nix ];
  plasma       = [ ./modules/plasma.nix plasma-manager.homeModules.plasma-manager ];
  snapclient   = [ ./modules/snapclient.nix ];
  soulseek     = [ ./modules/soulseek.nix ];
  streaming    = [ ./modules/streaming.nix ];
}
