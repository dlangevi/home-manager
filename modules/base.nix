{ config, pkgs, self, username, homeDirectory, dlsys, ... }:

{
  imports = [
    ./zsh.nix
    ./tmux.nix
    ./git.nix
    ./neovim.nix
    ./keepassxc.nix
    ./syncthing.nix
    ./claude.nix
    ./input-method.nix
    ./wezterm.nix
  ];

  home.username = username;
  home.homeDirectory = homeDirectory;
  home.stateVersion = "25.11";

  programs.home-manager.enable = true;

  # dlsys is a normal store package now (crates/dlsys), not an out-of-store
  # symlink into the working tree. The symlink existed because the bash
  # script resolved its own path and cd'd there, so a store copy would have
  # landed in /nix/store where there is no flake.nix or git. The Rust binary
  # finds the repo by convention instead -- DLSYS_FLAKE, else
  # ~/.config/home-manager -- which removes that constraint.
  #
  # If dlsys is ever broken or missing, ./bootstrap.sh in the repo still
  # works: it needs only nix and execs `nix run .#dlsys`.

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # Unfree in two separate worlds, and enabling one does nothing for the other:
  #
  #   - Everything this repo builds already works: flake.nix sets
  #     config.allowUnfree globally, which covers rar above, steam, nvidia.
  #   - Ad-hoc commands do not. `nix run nixpkgs#rar` resolves the registry's
  #     nixpkgs, which evaluates with an empty config and refuses -- the
  #     prompt to re-run with NIXPKGS_ALLOW_UNFREE=1 that keeps showing up.
  #
  # The obvious fixes both fail, measured rather than assumed:
  #
  #   nix run nixpkgs#unrar                           -> refuses
  #   NIXPKGS_ALLOW_UNFREE=1 nix run nixpkgs#unrar    -> refuses
  #   NIXPKGS_ALLOW_UNFREE=1 + --impure               -> works, but needs a flag
  #   pure-eval = false in nix.conf                   -> inert; see below
  #
  # The env var is read through builtins.getEnv, which pure evaluation blocks,
  # so it is dead on its own. Turning pure eval off in nix.conf does not
  # revive it: flake commands apply pure-eval from the command line *after*
  # the config files are read, so --option pure-eval false works and the
  # identical setting in a config file is silently overwritten. Don't bother
  # putting it there.
  #
  # What does work is removing the need for an env var at all. This points
  # the `nixpkgs` registry entry at this flake, whose legacyPackages is a
  # nixpkgs that already carries allowUnfree in its own expression -- no env,
  # so nothing for pure evaluation to object to. home-manager records the
  # store path of the flake, not the live working tree, so `nix run
  # nixpkgs#...` neither warns about a dirty repo nor breaks while this one
  # is mid-edit; it tracks whatever the last switch built.
  nix.registry.nixpkgs.flake = self;

  # Still worth setting for the non-flake path -- nix-shell, nix-build and
  # nix-env are impure already, so the var is live there. The file covers the
  # cases where the environment is not inherited, like cron or a
  # non-interactive `ssh host cmd`.
  home.sessionVariables.NIXPKGS_ALLOW_UNFREE = "1";
  xdg.configFile."nixpkgs/config.nix".text = ''
    { allowUnfree = true; }
  '';

  home.packages = [ dlsys ] ++ (with pkgs; [
    ripgrep
    fd
    bat
    zoxide
    gh
    htop
    # cudaSupport only pulls in the autoAddDriverRunpath hook (no CUDA, nothing
    # unfree); without it btop's dlopen of libnvidia-ml.so.1 fails and the GPU
    # box never appears on NVIDIA hosts.
    (btop.override { cudaSupport = true; })
    wget
    unzip
    # unrar extracts only; rar is the proprietary RARLAB binary that also
    # creates archives. Both are unfree (unrar as unfreeRedistributable, rar
    # outright), which is why they need the config below as well as being
    # declared here.
    #
    # They collide: rar ships bin/unrar too, so installing both fails the
    # profile buildEnv outright. lowPrio hands the name to the standalone
    # package, which is the newer of the two extractors -- rar 7.21 bundles
    # UNRAR 7.21, the standalone one reports 7.23. rar/ itself is unaffected,
    # nothing else provides that name.
    unrar
    (lib.lowPrio rar)
    xclip
    cntr
    jq
    mosh
  ]);
}
