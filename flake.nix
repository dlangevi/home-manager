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
      url = "git+ssh://git@github.com/dlangevi/dldev.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    music-mgmt = {
      url = "path:/home/dlangevi/auto/music-mgmt";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
  };

  outputs = { nixpkgs, nixpkgs-unstable, nixpkgs-ollama, home-manager, dldev, music-mgmt, plasma-manager, ... }:
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

      # Prefer a working copy of dldev when one is checked out, so edits there
      # take effect without a push + `nix flake update` cycle; fall back to the
      # locked GitHub input on machines that don't have it. Absolute path
      # rather than `homeDirectory` so this doesn't change meaning under sudo.
      #
      # Caveat: the local flake brings its own nixpkgs (its lock pins
      # nixos-unstable), so `inputs.dldev.inputs.nixpkgs.follows` does not
      # apply in this branch and agent-session gets rebuilt against that pin.
      dldevLocal = "/home/dlangevi/auto/dldev";
      dldevSrc =
        if builtins.pathExists (dldevLocal + "/flake.nix")
        then builtins.getFlake "path:${dldevLocal}"
        else dldev;

      features = import ./features.nix {
        inherit music-mgmt plasma-manager;
        dldev = dldevSrc;
      };
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
