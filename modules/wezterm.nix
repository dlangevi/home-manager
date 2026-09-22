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

      -- Splits and tabs are both wezterm's now (herd grew a wezterm backend).
      -- The two multiplexers are never nested: inside wezterm, wezterm
      -- multiplexes and tmux is not started; every other terminal, and any ssh
      -- from a host without wezterm, still gets tmux. That is what lets the
      -- leader below be C-a, the same as tmux's prefix, with no collision to
      -- design around and no send-prefix escape hatch to write.
      -- A tab is still one host: tab titles carry the hostname (see
      -- format-tab-title), which is what makes a remote tab readable.
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
      -- C-a, matching tmux's prefix exactly; 2000ms matches tmux's repeat-time.
      config.leader = { key = 'a', mods = 'CTRL', timeout_milliseconds = 2000 }

      -- smart-splits.nvim integration. neovim advertises itself by setting the
      -- IS_NVIM user var (the plugin does this on load, no nvim-side config
      -- needed), so a C-h/j/k/l that lands on a neovim pane is forwarded to
      -- neovim to move between *its* splits, and anywhere else moves between
      -- wezterm panes. Same trick for the C-A-h/j/k/l resize keys neovim binds.
      local function is_vim(pane)
        return pane:get_user_vars().IS_NVIM == 'true'
      end

      local direction_keys = { h = 'Left', j = 'Down', k = 'Up', l = 'Right' }

      local function split_nav(resize_or_move, key)
        local mods = resize_or_move == 'resize' and 'CTRL|ALT' or 'CTRL'
        return {
          key = key,
          mods = mods,
          action = wezterm.action_callback(function(win, pane)
            if is_vim(pane) then
              win:perform_action(wezterm.action.SendKey { key = key, mods = mods }, pane)
            elseif resize_or_move == 'resize' then
              win:perform_action(wezterm.action.AdjustPaneSize { direction_keys[key], 3 }, pane)
            else
              win:perform_action(wezterm.action.ActivatePaneDirection(direction_keys[key]), pane)
            end
          end),
        }
      end

      -- herd's subcommands all want a pane: `monitor` is a TUI, `jump` may open
      -- a picker and writes its workspace-switch escape sequence to its own
      -- stdout, and both read WEZTERM_PANE. wezterm has no popup, so they run in
      -- a transient split -- each exits on its own (monitor because of
      -- --jump-exits) and a wezterm pane dies with its program, so the split
      -- cleans itself up. Unlike tmux there is no "focus the monitor already on
      -- screen instead" guard: that needs a per-pane foreground-command query
      -- wezterm's Lua does not offer, so a second prefix+f gives a second
      -- monitor pane. Acceptable; the pane is disposable.
      local function herd_split(percent, args)
        return wezterm.action.SplitPane {
          direction = 'Right',
          size = { Percent = percent },
          command = { args = args },
        }
      end

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
        -- Bare C-arrow cycles tabs with no prefix, as in tmux.
        { key = 'UpArrow', mods = 'CTRL', action = wezterm.action.ActivateTabRelative(-1) },
        { key = 'LeftArrow', mods = 'CTRL', action = wezterm.action.ActivateTabRelative(-1) },
        { key = 'DownArrow', mods = 'CTRL', action = wezterm.action.ActivateTabRelative(1) },
        { key = 'RightArrow', mods = 'CTRL', action = wezterm.action.ActivateTabRelative(1) },

        -- Pane navigation and resize, smart-splits aware (see split_nav).
        split_nav('move', 'h'),
        split_nav('move', 'j'),
        split_nav('move', 'k'),
        split_nav('move', 'l'),
        split_nav('resize', 'h'),
        split_nav('resize', 'j'),
        split_nav('resize', 'k'),
        split_nav('resize', 'l'),

        -- LEADER table: one-for-one with tmux's prefix bindings in tmux.nix, on
        -- purpose. The two never run nested, so the same keys can mean the same
        -- things in both and the muscle memory carries across.
        { key = '-', mods = 'LEADER', action = wezterm.action.SplitPane { direction = 'Down' } },
        { key = '\\', mods = 'LEADER', action = wezterm.action.SplitPane { direction = 'Right' } },
        { key = 'a', mods = 'LEADER|CTRL', action = wezterm.action.ActivateLastTab },
        { key = 'x', mods = 'LEADER', action = wezterm.action.CloseCurrentPane { confirm = true } },
        { key = 'r', mods = 'LEADER', action = wezterm.action.ReloadConfiguration },
        -- tmux's prefix+Enter is break-pane: this pane becomes its own tab.
        {
          key = 'Enter',
          mods = 'LEADER',
          action = wezterm.action_callback(function(_, pane)
            pane:move_to_new_tab()
          end),
        },

        -- Resize with acceleration, tmux's tmux-resize-accel without the shell
        -- script: the first press nudges by 1 and then holds open a resize key
        -- table for 2000ms (tmux's repeat-time) in which bare h/j/k/l step by 3.
        {
          key = 'h',
          mods = 'LEADER|CTRL',
          action = wezterm.action.Multiple {
            wezterm.action.AdjustPaneSize { 'Left', 1 },
            wezterm.action.ActivateKeyTable { name = 'resize', one_shot = false, timeout_milliseconds = 2000 },
          },
        },
        {
          key = 'j',
          mods = 'LEADER|CTRL',
          action = wezterm.action.Multiple {
            wezterm.action.AdjustPaneSize { 'Down', 1 },
            wezterm.action.ActivateKeyTable { name = 'resize', one_shot = false, timeout_milliseconds = 2000 },
          },
        },
        {
          key = 'k',
          mods = 'LEADER|CTRL',
          action = wezterm.action.Multiple {
            wezterm.action.AdjustPaneSize { 'Up', 1 },
            wezterm.action.ActivateKeyTable { name = 'resize', one_shot = false, timeout_milliseconds = 2000 },
          },
        },
        {
          key = 'l',
          mods = 'LEADER|CTRL',
          action = wezterm.action.Multiple {
            wezterm.action.AdjustPaneSize { 'Right', 1 },
            wezterm.action.ActivateKeyTable { name = 'resize', one_shot = false, timeout_milliseconds = 2000 },
          },
        },

        -- Layouts. Only two of tmux's four have any wezterm counterpart.
        -- prefix+o (select-layout active-only) becomes "pick a pane and swap it
        -- with this one", and prefix+M-r is a real rotate. select-layout
        -- even-vertical (M--) and even-horizontal (M-|) have no equivalent at
        -- all: wezterm has a split tree and no layout engine, so there is
        -- nothing to re-lay out. Those two stay tmux-only, deliberately unbound
        -- here rather than faked with something that does not mean the same.
        { key = 'o', mods = 'LEADER', action = wezterm.action.PaneSelect { mode = 'SwapWithActive' } },
        { key = 'r', mods = 'LEADER|ALT', action = wezterm.action.RotatePanes 'Clockwise' },

        -- herd. prefix+f is the dashboard, prefix+j the no-UI jump.
        { key = 'f', mods = 'LEADER', action = herd_split(60, { 'herd', 'monitor', '--jump-exits' }) },
        { key = 'j', mods = 'LEADER', action = herd_split(40, { 'herd', 'jump' }) },
        -- prefix+R snaps a herd workspace back to 70/30 after a resize skewed
        -- it. It cannot run in a split like the other two: an extra pane is
        -- exactly the geometry it would be measuring and fixing. It needs no
        -- terminal, only WEZTERM_PANE to know which window it is repairing, so
        -- run it detached with that handed over explicitly.
        {
          key = 'R',
          mods = 'LEADER',
          action = wezterm.action_callback(function(_, pane)
            wezterm.background_child_process {
              'sh', '-c', 'WEZTERM_PANE=' .. tostring(pane:pane_id()) .. ' exec herd relayout',
            }
          end),
        },
      }

      -- Bare h/j/k/l inside the resize table; anything else falls out of it.
      config.key_tables = {
        resize = {
          { key = 'h', action = wezterm.action.AdjustPaneSize { 'Left', 3 } },
          { key = 'j', action = wezterm.action.AdjustPaneSize { 'Down', 3 } },
          { key = 'k', action = wezterm.action.AdjustPaneSize { 'Up', 3 } },
          { key = 'l', action = wezterm.action.AdjustPaneSize { 'Right', 3 } },
          { key = 'Escape', action = 'PopKeyTable' },
          { key = 'q', action = 'PopKeyTable' },
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

      -- The other machines, as panes in this wezterm rather than as sessions
      -- behind an ssh.
      --
      -- multiplexing = 'WezTerm' (the default) runs wezterm-mux-server on the
      -- far side, which is what makes a remote pane a real pane here: it
      -- survives a dropped link, reconnects on its own, and shows up in
      -- `wezterm cli list`. Plain ssh cannot do any of that, and tmux cannot
      -- do it at all -- a tmux client reaches one server, on one machine.
      --
      -- The paths and usernames are spelled out because they differ per host
      -- and a non-interactive ssh gets none of the PATH a login shell would.
      -- These domains are not connected at startup: a machine that is asleep
      -- should cost nothing until you ask for it.
      config.ssh_domains = {
        {
          name = 'suspense',
          remote_address = 'suspense',
          username = 'dlangevi',
          remote_wezterm_path = '/home/dlangevi/.nix-profile/bin/wezterm',
        },
        {
          name = 'dance',
          remote_address = 'dance',
          username = 'dance',
          remote_wezterm_path = '/home/dance/.nix-profile/bin/wezterm',
        },
        {
          name = 'console',
          remote_address = 'console',
          username = 'console',
          remote_wezterm_path = '/home/console/.nix-profile/bin/wezterm',
        },
      }

      -- Go to the pane that stamped itself `herd_pane=<host>:<tty>`.
      --
      -- Every pane's shell stamps that once (see modules/zsh.nix), and this
      -- walks the whole mux for the match. It cannot be done any other way: a
      -- pane wezterm is proxying from another machine reports a null tty and a
      -- renumbered pane id, so neither of the handles a program outside wezterm
      -- could use survives the crossing. A user var does, and only Lua can read
      -- one back.
      --
      -- Walking rather than listening for the stamp is deliberate.
      -- user-var-changed does not fire for a pane in a workspace that is not
      -- showing, but the var is still recorded on the pane -- so a resolver
      -- built on the event would miss exactly the sessions worth a dashboard.
      local function herd_focus(window, pane, key)
        for _, w in ipairs(wezterm.mux.all_windows()) do
          for _, t in ipairs(w:tabs()) do
            for _, p in ipairs(t:panes()) do
              if p:get_user_vars().herd_pane == key then
                if w:get_workspace() ~= wezterm.mux.get_active_workspace() then
                  wezterm.mux.set_active_workspace(w:get_workspace())
                end
                t:activate()
                p:activate()
                return
              end
            end
          end
        end
        -- Silence here would be indistinguishable from a jump that worked.
        -- herd cannot know: it names a destination and has no way to see
        -- whether anything answered to the name.
        window:toast_notification('herd', 'no pane for ' .. key, nil, 4000)
      end

      -- herd's wezterm backend asks the GUI to show a workspace the only way a
      -- pane can: an OSC 1337 SetUserVar. `herd jump` across workspaces is a
      -- no-op without this handler, and wezterm's CLI deliberately has no
      -- "switch workspace" to use instead -- which workspace a window shows is
      -- a GUI decision. The value arrives already base64-decoded.
      -- (Handlers for one event chain in wezterm, so this and any other
      -- user-var-changed handler both run; nothing here returns.)
      --
      -- `herd_focus` is the same channel carrying the other half of the same
      -- idea: go to a pane on another machine. It has to be resolved here
      -- rather than by herd because the key is a user var, and `wezterm cli`
      -- cannot read those -- only Lua can. See below.
      wezterm.on('user-var-changed', function(window, pane, name, value)
        if name == 'herd_workspace' then
          window:perform_action(wezterm.action.SwitchToWorkspace { name = value }, pane)
        elseif name == 'herd_focus' then
          herd_focus(window, pane, value)
        end
      end)

      -- Stand-in for tmux's status-right, which a wezterm session does not get:
      -- workspace, time, date. tmux also shells out to `acpi` for battery, but
      -- acpi is in no feature's home.packages, so that segment has always
      -- rendered empty -- wezterm.battery_info() is the replacement if this rig
      -- ever runs on a laptop.
      wezterm.on('update-right-status', function(window)
        local now = wezterm.time.now()
        window:set_right_status(wezterm.format {
          { Foreground = { AnsiColor = 'Blue' } },
          { Text = window:active_workspace() .. '  ' },
          { Foreground = { AnsiColor = 'Fuchsia' } },
          { Text = now:format('%R %m-%d') .. ' ' },
        })
      end)

      return config
    '';
  };
}
