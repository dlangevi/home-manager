{ config, pkgs, username, homeDirectory, dlsys, ... }:

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
  #   - Ad-hoc commands do not. `nix run nixpkgs#rar` evaluates the registry's
  #     nixpkgs with an empty config and refuses, which is the prompt to
  #     re-run with NIXPKGS_ALLOW_UNFREE=1 that keeps showing up.
  #
  # Fixing the second needs BOTH lines below. Measured, not assumed:
  #
  #   nix run nixpkgs#unrar                           -> refuses
  #   NIXPKGS_ALLOW_UNFREE=1 nix run nixpkgs#unrar    -> refuses
  #   nix run --option pure-eval false nixpkgs#unrar  -> refuses
  #   both together                                   -> works
  #
  # The var is read via builtins.getEnv, which pure evaluation blocks, so it
  # is inert on its own; and pure-eval off grants nothing without a var to
  # read. Flake commands default to pure eval. Turning that default off gives
  # up a guarantee nothing here relied on -- every build in this repo already
  # passes --impure, because the flake reads $USER and $HOME.
  # nix.package is not optional alongside nix.settings -- home-manager
  # asserts on it, because it shells out to that nix to validate the
  # generated nix.conf.
  nix.package = pkgs.nix;
  nix.settings = {
    # Carried over deliberately. ~/.config/nix/nix.conf already existed,
    # hand-written and unmanaged, holding exactly this line -- and the whole
    # file is generated now, so leaving it out would silently disable flakes
    # for every command on this machine.
    experimental-features = [ "nix-command" "flakes" ];
    pure-eval = false;
  };
  home.sessionVariables.NIXPKGS_ALLOW_UNFREE = "1";

  # The non-flake path (nix-shell, nix-build, nix-env) honours the env var
  # too, but only when the environment is inherited. This file covers the
  # cases where it is not -- cron, a non-interactive `ssh host cmd`.
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
