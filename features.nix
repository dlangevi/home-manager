{ dldev, ... }:
{
  base  = [ ./home.nix ];
  dldev = [ dldev.homeModules.default ];
  aoe2  = [ ./modules/aoe2.nix ];
}
