{
  description = "dlangevi home-manager config";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    dl-herd = {
      url = "git+ssh://git@github.com/dlangevi/dl-herd.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
  };

  outputs = { nixpkgs, nixpkgs-unstable, home-manager, dl-herd, plasma-manager, ... }:
    let
      system = "x86_64-linux";
      pkgs-unstable = import nixpkgs-unstable { inherit system; config.allowUnfree = true; };
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = [(final: prev: {
          itgmania = pkgs-unstable.itgmania;
        })];
      };
      username = builtins.getEnv "USER";
      homeDirectory = builtins.getEnv "HOME";

      # Prefer a working copy of dl-herd when one is checked out, so edits there
      # take effect without a push + `nix flake update` cycle; fall back to the
      # locked GitHub input on machines that don't have it. Absolute path
      # rather than `homeDirectory` so this doesn't change meaning under sudo.
      #
      # Caveat: the local flake brings its own nixpkgs (its lock pins
      # nixos-unstable), so `inputs.dl-herd.inputs.nixpkgs.follows` does not
      # apply in this branch and herd gets rebuilt against that pin.
      #
      # `git+file://`, not `path:`. `path:` copies the directory verbatim and
      # ignores .gitignore, so every switch hauled the whole working tree into
      # the store -- 4.2G measured on suspense (a 2.2G cargo target/ plus 1.6G
      # of .claude transcripts) against 664K of actually-tracked source. That
      # copy ran on every `dlsys switch` and was the long pause at
      # `copying '/home/dlangevi/auto/dl-herd' to the store`. The git fetcher
      # copies tracked files only, which is the 664K.
      #
      # The local-override intent is unchanged: uncommitted edits to *tracked*
      # files are still picked up (nix reads the dirty working tree and warns).
      # What changes is that a brand-new file needs `git add` before it is
      # visible -- the same rule this repo already has for its own modules.
      herdLocal = "/home/dlangevi/auto/dl-herd";
      herdSrc =
        if builtins.pathExists (herdLocal + "/flake.nix")
        then builtins.getFlake "git+file://${herdLocal}"
        else dl-herd;

      # The apply tool itself. Built from this repo so `nix run .#dlsys` works
      # with nothing but nix and a checkout -- that is what bootstrap.sh relies
      # on, and why home-manager is not a prerequisite for bootstrapping.
      #
      # cargoLock.lockFile rather than a cargoHash: adding a dependency then
      # costs a `cargo add`, not a hand-updated sha256 that fails the build
      # once before you learn the right value.
      dlsysPkg = pkgs.rustPlatform.buildRustPackage {
        pname = "dlsys";
        version = "0.1.0";

        # Only the crate, not the whole repo. With `src = ./.` every edit to
        # any module .nix would change the derivation and rebuild dlsys --
        # on this host and, during a rollout, on every remote host too.
        src = pkgs.lib.fileset.toSource {
          root = ./.;
          fileset = pkgs.lib.fileset.unions [ ./Cargo.toml ./Cargo.lock ./crates ];
        };
        cargoLock.lockFile = ./Cargo.lock;

        # dlsys shells out to all of these. Wrapping them on PATH keeps it
        # working when invoked from a bare `nix run` on a machine whose user
        # environment has none of them yet -- the bootstrap case.
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postInstall = ''
          wrapProgram $out/bin/dlsys \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git pkgs.openssh ]}
        '';
      };

      features = import ./features.nix {
        inherit plasma-manager;
        dl-herd = herdSrc;
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
        modules = [
          ./nixos/common.nix
          ./nixos/hosts/${host}.nix
          (hardwareModule host)
        ];
      };

      # `hostname` is threaded in because a home-manager module otherwise has no
      # way to know which machine it is being built for -- there is no runtime
      # call to reach for, the way wezterm's Lua has wezterm.hostname(). It is
      # simply the attr name from machines.nix, which was being discarded here.
      # modules/tmux.nix uses it to leave this machine out of its own domain
      # menu.
      mkHome = hostname: featureNames: home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = builtins.concatMap (name: features.${name}) featureNames;
        extraSpecialArgs = {
          inherit username homeDirectory hostname;
          dlsys = dlsysPkg;
        };
      };
    in
    {
      homeConfigurations =
        builtins.mapAttrs (host: featureNames: mkHome host featureNames) machines;

      nixosConfigurations =
        builtins.mapAttrs (host: _: mkNixos host) machines;

      # Expose the home-manager CLI so the dlsys script can invoke it
      # via `nix run .#home-manager` on machines that don't have it
      # installed yet.
      packages.${system} = {
        # Exposed so dlsys can invoke home-manager via `nix run .#home-manager`
        # on machines that don't have it installed yet.
        home-manager = home-manager.packages.${system}.home-manager;

        # The apply tool. `nix run .#dlsys` is what bootstrap.sh execs into.
        dlsys = dlsysPkg;
      };

      devShells.${system}.default = pkgs.mkShell {
        # The Rust toolchain is here for crates/dlsys. .envrc activates this
        # shell, so iterating is `cargo run -- switch` rather than a rebuild.
        packages = with pkgs; [
          nixfmt-rfc-style
          nil
          gh
          cargo
          rustc
          rust-analyzer
          clippy
          rustfmt
        ];
        RUST_SRC_PATH = "${pkgs.rust.packages.stable.rustPlatform.rustLibSrc}";
      };
    };
}
