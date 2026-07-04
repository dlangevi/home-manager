{ pkgs, ... }:

{
  home.packages = with pkgs; [
    cargo
    rustc
    rust-analyzer
    clippy
    rustfmt
    pkg-config
    gcc
    cmake
    gnumake
    python3
    nodejs
    yarn
  ];
}
