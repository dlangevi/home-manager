{
  description = "dlangevi home-manager config";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    dldev = {
      url = "path:/home/dlangevi/auto/dldev";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, home-manager, dldev, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      mkHome = modules: home-manager.lib.homeManagerConfiguration {
        inherit pkgs modules;
      };
    in
    {
      homeConfigurations = {
        base     = mkHome [ ./home.nix ];
        dev      = mkHome [ ./home.nix dldev.homeModules.default ];
        personal = mkHome [ ./home.nix dldev.homeModules.default ./modules/aoe2.nix ];
      };
    };
}
