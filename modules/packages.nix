{ pkgs, lib, ... }:

{
  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [ "claude-code" ];

  home.packages = with pkgs; [
    ripgrep
    fd
    bat
    fzf
    zoxide
    gh
    htop
    claude-code
    cargo
    rustc
  ];
}
