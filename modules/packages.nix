{ pkgs, ... }:

{
  home.packages = with pkgs; [
    ripgrep
    fd
    bat
    fzf
    zoxide
    gh
    htop
    claude-code
  ];
}
