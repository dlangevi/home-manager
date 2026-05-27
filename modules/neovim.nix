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
    initLua = ''
      -- Load the real config from the cloned nvim repo
      local config_path = vim.fn.stdpath("config") .. "/lua"
      vim.opt.rtp:prepend(vim.fn.stdpath("config"))

      local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
      if not vim.loop.fs_stat(lazypath) then
        vim.fn.system({
          "git",
          "clone",
          "--filter=blob:none",
          "https://github.com/folke/lazy.nvim.git",
          "--branch=stable",
          lazypath,
        })
      end
      vim.opt.rtp:prepend(lazypath)

      vim.g.mapleader = " "
      vim.g.maplocalleader = " "
      vim.opt.termguicolors = true

      require('lazy').setup('plugins', {
        change_detection = {
          enabled = true,
          notify = false,
        },
        performance = {
          cache = {
            enabled = true
          }
        }
      })
    '';
  };

  home.activation.cloneNeovimConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    NVIM_CONFIG="${config.xdg.configHome}/nvim"
    if [ ! -d "$NVIM_CONFIG" ]; then
      run ${pkgs.git}/bin/git clone https://github.com/dlangevi/nvim.git "$NVIM_CONFIG"
    fi
  '';
}
