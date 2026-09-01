{ dldev, plasma-manager, ... }:
{
  base         = [ ./modules/base.nix ];
  dev          = [ ./modules/dev.nix ];
  dldev        = [ dldev.homeModules.default ];
  desktop-apps = [ ./modules/desktop-apps.nix ];
  documents    = [ ./modules/documents.nix ];
  gaming       = [ ./modules/gaming.nix ];
  media        = [ ./modules/media.nix ];
  plasma       = [ ./modules/plasma.nix plasma-manager.homeModules.plasma-manager ];
  streaming    = [ ./modules/streaming.nix ];
}
