{ dldev, ... }:
{
  base         = [ ./modules/base.nix ];
  dev          = [ ./modules/dev.nix ];
  dldev        = [ dldev.homeModules.default ];
  desktop-apps = [ ./modules/desktop-apps.nix ];
  gaming       = [ ./modules/gaming.nix ];
  media        = [ ./modules/media.nix ];
}
