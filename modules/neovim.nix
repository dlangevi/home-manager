{ pkgs, config, lib, ... }:

{
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    extraPackages = with pkgs; [
      # Language servers
      lua-language-server
      nil
      clang-tools
      rust-analyzer
      pyright
      clang
      nodejs
      # Tools
      ripgrep
      fd
      tree-sitter
    ];
  };

  home.activation.cloneNeovimConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    NVIM_CONFIG="${config.xdg.configHome}/nvim"
    if [ ! -d "$NVIM_CONFIG" ]; then
      run ${pkgs.git}/bin/git clone https://github.com/dlangevi/nvim.git "$NVIM_CONFIG"
    fi
  '';
}
