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
    # NOTE: We deliberately do NOT set extraLuaConfig / initLua here.
    # The full config (including init.lua) is owned by the cloned
    # dlangevi/nvim repo at $XDG_CONFIG_HOME/nvim (see activation below).
    # Generating an init.lua here would make home-manager symlink it into
    # the same path and collide with the git clone.
  };

  home.activation.cloneNeovimConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    NVIM_CONFIG="${config.xdg.configHome}/nvim"
    if [ ! -d "$NVIM_CONFIG" ]; then
      run ${pkgs.git}/bin/git clone https://github.com/dlangevi/nvim.git "$NVIM_CONFIG"
    fi
  '';
}
