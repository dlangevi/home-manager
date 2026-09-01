{
  description = "dlangevi home-manager config";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # Pinned separately so routine `nix flake update` doesn't retrigger the
    # ollama CUDA rebuild. Bump with:
    #   nix flake lock --update-input nixpkgs-ollama
    nixpkgs-ollama.url = "github:NixOS/nixpkgs/nixos-26.05";
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    dldev = {
      url = "path:/home/dlangevi/auto/dldev";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
  };

  outputs = { nixpkgs, nixpkgs-unstable, nixpkgs-ollama, home-manager, dldev, plasma-manager, ... }:
    let
      system = "x86_64-linux";
      pkgs-unstable = import nixpkgs-unstable { inherit system; config.allowUnfree = true; };
      pkgs-ollama = import nixpkgs-ollama { inherit system; config.allowUnfree = true; };
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = [(final: prev: {
          itgmania = pkgs-unstable.itgmania;
        })];
      };
      username = builtins.getEnv "USER";
      homeDirectory = builtins.getEnv "HOME";

      features = import ./features.nix { inherit dldev plasma-manager; };
      machines = import ./machines.nix;

      # Hardware config comes from `nixos/hardware/<host>.nix` once it has been
      # checked in, which keeps eval pure and lets any host build any config.
      # Hosts that haven't been migrated yet still read the generated file off
      # the machine running the build, and so must be built there with
      # `--impure`. To migrate one: copy its
      # `/etc/nixos/hardware-configuration.nix` to `nixos/hardware/<host>.nix`.
      hardwareModule = host:
        let repoFile = ./nixos/hardware/${host}.nix;
        in if builtins.pathExists repoFile
           then repoFile
           else /etc/nixos/hardware-configuration.nix;

      mkNixos = host: nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit pkgs-ollama; };
        modules = [
          ./nixos/common.nix
          ./nixos/hosts/${host}.nix
          (hardwareModule host)
        ];
      };

      mkHome = featureNames: home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = builtins.concatMap (name: features.${name}) featureNames;
        extraSpecialArgs = { inherit username homeDirectory; };
      };
    in
    {
      homeConfigurations =
        builtins.mapAttrs (_: featureNames: mkHome featureNames) machines;

      nixosConfigurations =
        builtins.mapAttrs (host: _: mkNixos host) machines;

      # Expose the home-manager CLI so the bootstrap script can invoke it
      # via `nix run .#home-manager` on machines that don't have it
      # installed yet.
      packages.${system}.home-manager =
        home-manager.packages.${system}.home-manager;

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [ nixfmt-rfc-style nil gh ];
      };
    };
}
