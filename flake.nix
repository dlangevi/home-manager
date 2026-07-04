{
  description = "dlangevi home-manager config";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    dldev = {
      url = "path:/home/dlangevi/auto/dldev";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    zen-browser = {
      url = "github:youwen5/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, nixpkgs-unstable, home-manager, dldev, zen-browser, ... }:
    let
      system = "x86_64-linux";
      pkgs-unstable = import nixpkgs-unstable { inherit system; config.allowUnfree = true; };
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = [(final: prev: {
          itgmania = pkgs-unstable.itgmania;
          zen-browser = zen-browser.packages.${system}.default;
        })];
      };
      username = builtins.getEnv "USER";
      homeDirectory = builtins.getEnv "HOME";

      features = import ./features.nix { inherit dldev; };
      machines = import ./machines.nix;

      mkHome = featureNames: home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = builtins.concatMap (name: features.${name}) featureNames;
        extraSpecialArgs = { inherit username homeDirectory; };
      };
    in
    {
      homeConfigurations =
        builtins.mapAttrs (_: featureNames: mkHome featureNames) machines;

      # Expose the home-manager CLI so the bootstrap script can invoke it
      # via `nix run .#home-manager` on machines that don't have it
      # installed yet.
      packages.${system}.home-manager =
        home-manager.packages.${system}.home-manager;
    };
}
