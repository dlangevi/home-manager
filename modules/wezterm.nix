{ pkgs, ... }:

{
  # Ship the font with the terminal so base works on non-NixOS hosts too.
  home.packages = with pkgs; [ nerd-fonts.agave ];
  fonts.fontconfig.enable = true;

  programs.wezterm = {
    enable = true;
    extraConfig = ''
      local wezterm = require 'wezterm'
      local config = wezterm.config_builder()

      config.color_scheme = 'Sonokai (Gogh)'
      config.font = wezterm.font_with_fallback {
        'AgaveNerdFont',
        'Noto Sans Mono CJK SC',
        'Noto Color Emoji',
      }
      config.font_size = 11.0

      -- tmux owns tabs and splits; keep the chrome out of the way.
      config.enable_tab_bar = false
      config.window_padding = { left = 2, right = 2, top = 2, bottom = 2 }
      config.scrollback_lines = 10000
      config.audible_bell = 'Disabled'
      config.check_for_updates = false

      -- Match alacritty's default of not treating alt as meta-escape oddly.
      config.use_ime = true

      config.keys = {
        { key = 'c', mods = 'CTRL|SHIFT', action = wezterm.action.CopyTo 'Clipboard' },
        { key = 'v', mods = 'CTRL|SHIFT', action = wezterm.action.PasteFrom 'Clipboard' },
        { key = '+', mods = 'CTRL', action = wezterm.action.IncreaseFontSize },
        { key = '-', mods = 'CTRL', action = wezterm.action.DecreaseFontSize },
        { key = '0', mods = 'CTRL', action = wezterm.action.ResetFontSize },
      }

      return config
    '';
  };
}
