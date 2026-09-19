{ pkgs, ... }:

{
  # Ship the font with the terminal so base works on non-NixOS hosts too.
  home.packages = with pkgs; [ nerd-fonts.agave ];
  fonts.fontconfig.enable = true;

  # The xdg-terminal-exec spec's answer to "which terminal?". KIO 6.26 still
  # uses kdeglobals TerminalApplication instead (set in plasma.nix), so this is
  # for everything else that launches a terminal, and for when KDE adopts the
  # spec.
  xdg.configFile."xdg-terminals.list".text = "org.wezfurlong.wezterm.desktop\n";

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

      -- tmux owns splits; wezterm owns tabs. One tab per tmux server, which is
      -- what makes a remote server usable -- a single tmux client can only ever
      -- talk to one server, so the second host needs a tab, not a nested
      -- session with its bindings shadowed by the outer server.
      config.enable_tab_bar = true
      config.tab_bar_at_bottom = false      -- default, but state it: tabs on top
      config.use_fancy_tab_bar = false 
      config.hide_tab_bar_if_only_one_tab = true 
      config.tab_max_width = 24
      -- Keyboard-only rig; the button is dead weight next to CTRL|SHIFT+t.
      config.show_new_tab_button_in_tab_bar = false
      config.window_padding = { left = 2, right = 2, top = 2, bottom = 2 }
      config.scrollback_lines = 10000
      config.audible_bell = 'Disabled'
      config.check_for_updates = false

      -- fcitx5 pinyin comes from base/input-method.nix; without IME support
      -- the candidate window never appears.
      config.use_ime = true

      -- Clickable links. The defaults already match http(s), mailto and bare
      -- www. hosts; state them explicitly so the extras below are additions
      -- rather than a replacement of the built-in set.
      config.hyperlink_rules = wezterm.default_hyperlink_rules()
      -- Dev servers are printed as host:port with no scheme, which no default
      -- rule matches.
      table.insert(config.hyperlink_rules, {
        regex = [[\b(localhost|127\.0\.0\.1|0\.0\.0\.0)(:\d+)?(/\S*)?\b]],
        format = 'http://$0',
      })

      config.mouse_bindings = {
        -- Plain left click opens the link under the cursor (and otherwise just
        -- finishes a selection); no modifier, since the whole point is that a
        -- link behaves like a link.
        {
          event = { Up = { streak = 1, button = 'Left' } },
          mods = 'NONE',
          action = wezterm.action.CompleteSelectionOrOpenLinkAtMouseCursor 'ClipboardAndPrimarySelection',
        },
        -- CTRL+click stays wired too, for anything that expects it.
        {
          event = { Up = { streak = 1, button = 'Left' } },
          mods = 'CTRL',
          action = wezterm.action.OpenLinkAtMouseCursor,
        },
        -- Swallow the matching Down event so the program underneath does not
        -- also see the CTRL+click.
        {
          event = { Down = { streak = 1, button = 'Left' } },
          mods = 'CTRL',
          action = wezterm.action.Nop,
        },
      }

      config.keys = {
        { key = 'c', mods = 'CTRL|SHIFT', action = wezterm.action.CopyTo 'Clipboard' },
        { key = 'v', mods = 'CTRL|SHIFT', action = wezterm.action.PasteFrom 'Clipboard' },
        { key = '+', mods = 'CTRL', action = wezterm.action.IncreaseFontSize },
        { key = '-', mods = 'CTRL', action = wezterm.action.DecreaseFontSize },
        { key = '0', mods = 'CTRL', action = wezterm.action.ResetFontSize },

        -- Tabs. These duplicate wezterm's defaults rather than relying on them,
        -- so the bindings survive a future disable_default_key_bindings.
        { key = 't', mods = 'CTRL|SHIFT', action = wezterm.action.SpawnTab 'CurrentPaneDomain' },
        { key = 'w', mods = 'CTRL|SHIFT', action = wezterm.action.CloseCurrentTab { confirm = true } },
        { key = '[', mods = 'CTRL|SHIFT', action = wezterm.action.ActivateTabRelative(-1) },
        { key = ']', mods = 'CTRL|SHIFT', action = wezterm.action.ActivateTabRelative(1) },

        -- Keyboard-only link opening: labels every URL on screen, type the
        -- label to hand it to xdg-open. A mouse is never required.
        {
          key = 'u',
          mods = 'CTRL|SHIFT',
          action = wezterm.action.QuickSelectArgs {
            label = 'open url',
            patterns = { [[\b\w+://\S+]] },
            action = wezterm.action_callback(function(window, pane)
              local url = window:get_selection_text_for_pane(pane)
              if url ~= "" then
                wezterm.open_with(url)
              end
            end),
          },
        },
      }

      -- ALT+1..8 jumps straight to a tab. Chosen over CTRL|SHIFT+number because
      -- tmux's prefix is C-a and its own ALT bindings are M--, M-| and M-r, so
      -- nothing here is swallowed on the way through.
      for i = 1, 8 do
        table.insert(config.keys, {
          key = tostring(i),
          mods = 'ALT',
          action = wezterm.action.ActivateTab(i - 1),
        })
      end

      -- Tab title = hostname of the machine that tab's shell is on. The title
      -- string is the transport (see tmux.nix and zsh.nix); wezterm knows
      -- nothing about ssh or mosh and does not need to.
      local host_by_tab = {}
      wezterm.on('format-tab-title', function(tab)
        -- Accept only a bare hostname, so a program that sets its own title
        -- (nvim, less, a build) cannot leak into the tab bar. Remembering the
        -- last good value per tab beats falling back to the local hostname,
        -- which would mislabel a remote tab as this machine.
        local host = (tab.active_pane.title or ""):match('^%s*([%w._-]+)%s*$')
        if host then
          host_by_tab[tab.tab_id] = host
        end
        return ' ' .. (host_by_tab[tab.tab_id] or wezterm.hostname():match('^[^.]+')) .. ' '
      end)

      return config
    '';
  };
}
