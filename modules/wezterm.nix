{ pkgs, ... }:

let
  # Launches wezterm in passthrough mode -- see the long comment in the Lua
  # below. The env var is the whole mechanism; this exists so the desktop entry
  # has something to point Exec= at (a .desktop file cannot set environment
  # variables) and so the mode is reachable from a shell by name.
  weztermPassthrough = pkgs.writeShellScriptBin "wezterm-passthrough" ''
    export WEZTERM_PASSTHROUGH=1
    # --always-new-process: without it wezterm hands the request to an already
    # running GUI, which was started without the variable and would open an
    # ordinary window instead.
    exec ${pkgs.wezterm}/bin/wezterm start --always-new-process "$@"
  '';

in
{
  # Ship the font with the terminal so base works on non-NixOS hosts too.
  home.packages = with pkgs; [ nerd-fonts.agave ] ++ [ weztermPassthrough ];
  fonts.fontconfig.enable = true;

  xdg.desktopEntries.wezterm-passthrough = {
    name = "WezTerm (passthrough)";
    genericName = "Terminal";
    comment = "WezTerm with the tmux keymap disabled, for driving a remote tmux";
    exec = "${weztermPassthrough}/bin/wezterm-passthrough";
    icon = "org.wezfurlong.wezterm";
    terminal = false;
    type = "Application";
    categories = [ "System" "TerminalEmulator" ];
    settings.StartupWMClass = "org.wezfurlong.wezterm";
  };

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

      -- Passthrough profile. Everything below that mirrors tmux -- the C-a
      -- leader and its whole table, the bare C-arrow and C-hjkl bindings --
      -- exists because wezterm is the outer multiplexer on this machine. Point
      -- a window at a *remote* tmux instead and every one of those keys is a
      -- key the remote server never sees: C-a is swallowed, C-hjkl never
      -- reaches vim-tmux-navigator, C-arrow changes the wrong window. So a
      -- passthrough window keeps the look (fonts, colours, links, copy/paste)
      -- and drops the multiplexing: wezterm becomes a plain terminal and the
      -- remote tmux gets its prefix back, unprefixed and one key away.
      --
      -- Two ways in, because there are two ways such a window gets opened:
      -- WEZTERM_PASSTHROUGH in the environment (what the desktop launcher and
      -- the wezterm-passthrough wrapper set), and `wezterm ssh <host>`, which
      -- is remote by definition. wezterm's Lua exposes no argv, so the second
      -- is read off /proc -- Linux-only, which every machine this flake targets
      -- is; a platform without it just falls back to the env var.
      local function detect_passthrough()
        if os.getenv('WEZTERM_PASSTHROUGH') then
          return true
        end
        local f = io.open('/proc/self/cmdline', 'rb')
        if not f then
          return false
        end
        local argv = f:read('*a') or ""
        f:close()
        -- NUL-separated. A bare `ssh` argument is either the `wezterm ssh`
        -- subcommand or `wezterm start -- ssh host`; both are remote.
        for arg in argv:gmatch('[^\0]+') do
          if arg == 'ssh' then
            return true
          end
        end
        return false
      end

      local passthrough = detect_passthrough()

      config.color_scheme = 'Sonokai (Gogh)'
      config.font = wezterm.font_with_fallback {
        'AgaveNerdFont',
        'Noto Sans Mono CJK SC',
        'Noto Color Emoji',
      }
      config.font_size = 11.0

      -- Splits and tabs are both wezterm's now (herd grew a wezterm backend),
      -- but tmux is not retired and the two do get nested: ssh into a host and
      -- run tmux there and wezterm is the outer multiplexer, both bound to C-a.
      -- wezterm wins that, always and unconditionally -- no sniffing at what a
      -- pane is running to decide who gets the key, because a leader that is
      -- sometimes the leader is worse than either answer. The cost is paid the
      -- way tmux itself pays it for tmux-in-tmux: LEADER a forwards one literal
      -- C-a to the pane, which is `bind-key a send-prefix` in tmux.nix spelled
      -- for wezterm. So the inner tmux is two keys away rather than one, and
      -- nothing else about it changes.
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

      -- Not cosmetic: this is what keeps a mux pane repainting. Every pane
      -- here is a mux-client pane (default_domain, below), and a client pane
      -- that misses a server push can only recover by polling -- except
      -- wezterm calls that poll from get_changed_since(), which only runs
      -- while drawing a frame. No push means no repaint means no frame means
      -- no poll, and the pane sits stale until a keypress or mouse event
      -- forces a draw. The status tick is the one thing that forces a draw on
      -- its own, so its interval is the ceiling on how long a pane can be
      -- wrong; 1000ms (the default) was visible as output arriving in bursts.
      -- The real fix belongs upstream -- the client's poll backoff runs to
      -- MAX_POLL_INTERVAL = 30s -- and this only narrows the window.
      -- Costs running the update-status callback below 10x a second.
      config.status_update_interval = 100

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
      -- Left unset in passthrough windows, so C-a is just C-a.
      if not passthrough then
        config.leader = { key = 'a', mods = 'CTRL', timeout_milliseconds = 2000 }
      end

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
      -- cleans itself up.
      local function herd_split(percent, args)
        return wezterm.action.SplitPane {
          direction = 'Right',
          size = { Percent = percent },
          command = { args = args },
        }
      end

      -- tmux's prefix+f guard (tmux-monitor-focus in tmux.nix), in Lua: if this
      -- tab already shows a herd monitor, go to it rather than splitting a
      -- second one. `agent-session` is herd's former name, matched until old
      -- panes cycle out -- tmux-monitor-focus matches both for that reason too.
      --
      -- get_foreground_process_name returns a path, and returns nil for a pane
      -- on another host: the mux does not proxy process names. So a monitor
      -- running on a remote tab is not seen and splits again. tmux's version
      -- fails the same way across an ssh boundary, and the pane is disposable.
      local function herd_monitor_focus(window)
        for _, p in ipairs(window:active_tab():panes()) do
          local proc = p:get_foreground_process_name()
          local base = proc and proc:match('([^/]+)$')
          if base == 'herd' or base == 'agent-session' then
            p:activate()
            return true
          end
        end
        return false
      end

      -- Workspace naming, mirroring tmux-session in modules/zsh.nix: $HOME is
      -- `home`, anything under it is the home-relative path, anything else the
      -- absolute path. Dots become underscores -- a tmux constraint (it reads
      -- `.` as a target separator) that wezterm does not share, kept anyway so
      -- one directory yields one name under both and herd sees a session
      -- started either way as the same session.
      local function workspace_name_for(path)
        local home = wezterm.home_dir
        local name
        if path == home then
          name = 'home'
        elseif path:sub(1, #home + 1) == home .. '/' then
          name = path:sub(#home + 2)
        else
          name = path
        end
        return (name:gsub('%.', '_'))
      end

      -- Empty input means "here", and a bare word is home-relative -- both the
      -- way `tmux-session` reads its argument.
      local function resolve_path(pane, line)
        if line == nil then return nil end
        if line == "" then
          local cwd = pane:get_current_working_dir()
          return cwd and cwd.file_path or wezterm.home_dir
        elseif line:sub(1, 1) == '~' then
          return wezterm.home_dir .. line:sub(2)
        elseif line:sub(1, 1) ~= '/' then
          return wezterm.home_dir .. '/' .. line
        end
        return line
      end

      -- tmux-session's create-or-attach: `tmux new -A -s`. SwitchToWorkspace
      -- alone would do it -- it creates what is missing -- but its `spawn`
      -- hands back no reference to the window it made, and the agent variant
      -- needs one to add a second tab to. tmux-session -a made two windows,
      -- `script` and `agent`; a tmux window is a wezterm tab.
      local function switch_to_path(window, pane, path, agent)
        if path == nil then return end
        local name = workspace_name_for(path)
        local exists = false
        for _, w in ipairs(wezterm.mux.get_workspace_names()) do
          if w == name then exists = true end
        end
        if not exists then
          local _, _, mux_win = wezterm.mux.spawn_window { workspace = name, cwd = path }
          if agent then
            mux_win:spawn_tab { cwd = path, args = { 'herd', 'layout' } }
          end
        end
        window:perform_action(wezterm.action.SwitchToWorkspace { name = name }, pane)
      end

      -- Last-workspace toggle, tmux's prefix+L (switch-client -l). wezterm
      -- fires no workspace-change event, so the change is noticed in
      -- update-status instead of at each switch site -- which catches every
      -- route into a workspace, including the ones outside this file (herd's
      -- wz_workspace_cwd, a bare SwitchToWorkspace). The cost is the status
      -- interval: two switches inside one second collapse, and the middle one
      -- is never recorded.
      local workspace_now, workspace_prev = {}, {}
      local function note_workspace(window)
        local id, ws = window:window_id(), window:active_workspace()
        if workspace_now[id] ~= ws then
          workspace_prev[id] = workspace_now[id]
          workspace_now[id] = ws
        end
      end

      -- The workspace list behind LEADER s, rebuilt by hand because the
      -- built-in FUZZY|WORKSPACES launcher renders bare names and takes no
      -- formatting. A name alone stopped being enough once a session could
      -- live on another machine's mux: `music-mgmt` does not say whether it is
      -- here or on dance, and those are different sessions doing different
      -- work. So each row carries the domains its panes are actually on.
      --
      -- Domains are read off the panes rather than stored when the workspace is
      -- made, because a workspace is not pinned to one domain -- a tab spawned
      -- into another host joins it, and then both names show. That is the
      -- honest answer; picking one to display would hide the split.
      local function workspace_picker()
        return wezterm.action_callback(function(window, pane)
          local domains, choices = {}, {}
          for _, w in ipairs(wezterm.mux.all_windows()) do
            local ws = w:get_workspace()
            local seen = domains[ws]
            if not seen then
              seen = { names = {} }
              domains[ws] = seen
            end
            for _, t in ipairs(w:tabs()) do
              for _, p in ipairs(t:panes()) do
                local d = p:get_domain_name()
                if d and not seen[d] then
                  seen[d] = true
                  table.insert(seen.names, d)
                end
              end
            end
          end

          -- get_workspace_names is the authority on what exists (it is what
          -- switch_to_path checks), and it is already sorted.
          for _, ws in ipairs(wezterm.mux.get_workspace_names()) do
            local seen = domains[ws]
            local where = seen and table.concat(seen.names, ', ') or ""
            table.insert(choices, {
              id = ws,
              label = ws .. (where ~= "" and '  [' .. where .. ']' or ""),
            })
          end

          window:perform_action(
            wezterm.action.InputSelector {
              title = 'Workspaces',
              fuzzy = true,
              choices = choices,
              action = wezterm.action_callback(function(win, inner_pane, id)
                -- id is nil when the selector is cancelled.
                if id then
                  win:perform_action(wezterm.action.SwitchToWorkspace { name = id }, inner_pane)
                end
              end),
            },
            pane
          )
        end)
      end

      -- Every machine runs a wezterm mux server, and every machine's config
      -- names a domain for every machine -- the local one as a unix domain, the
      -- rest as ssh domains -- so a window here can hold tabs living on any of
      -- them at once, and those tabs outlive the GUI showing them.
      --
      -- One mux per host, not one per domain name: a mux server listens on
      -- $XDG_RUNTIME_DIR/wezterm/sock whatever its unix domain is called, and a
      -- client with the same config connects to that same path. So naming the
      -- domain after its host is purely so the launcher reads as a machine
      -- list, and a tab opened on dance from here is in the *same* mux that
      -- dance's own GUI attaches to when someone sits down at it.
      --
      -- multiplexing = 'WezTerm' is what makes the remote half of that true:
      -- wezterm ssh's in, starts `wezterm-mux-server` on the far end (it is on
      -- PATH there via ~/.nix-profile, since base ships wezterm everywhere) and
      -- then speaks the mux protocol rather than piping a raw pty. That
      -- protocol is version-locked between the two ends -- both come from this
      -- flake's pin, so they agree, but a host upgraded while another is not
      -- will refuse to connect until `dlsys rollout` catches it up.
      --
      -- Connections use wezterm's built-in ssh client, not /usr/bin/ssh: it
      -- reads ~/.ssh/config and ~/.ssh/id_* and talks to the agent, but an
      -- exotic ProxyJump or Match block is not guaranteed to be honoured. Keys
      -- and a flat tailnet name are, which is all these hosts need.
      --
      -- console is on the tailnet (100.123.29.32, MagicDNS resolves it); it is
      -- simply powered off most of the day, which costs nothing here because
      -- domains are not connected until something asks for one.
      local ssh_hosts = {
        { host = 'suspense', user = 'dlangevi', key = 's' },
        { host = 'dance',    user = 'dance',    key = 'd' },
        { host = 'console',  user = 'console',  key = 'c' },
      }

      local this_host = wezterm.hostname():match('^[^.]+')

      -- Declared unconditionally rather than from the table above, so a machine
      -- not listed there (or not yet added) still gets its own mux instead of
      -- default_domain naming a domain that does not exist.
      config.unix_domains = { { name = this_host } }

      config.ssh_domains = {}
      for _, h in ipairs(ssh_hosts) do
        if h.host ~= this_host then
          table.insert(config.ssh_domains, {
            name = h.host,
            remote_address = h.host,
            username = h.user,
            multiplexing = 'WezTerm',
            -- Predictive local echo, the mux protocol's answer to typing over a
            -- link with latency: show the keypress immediately and reconcile
            -- when the server's version of the line arrives.
            local_echo_threshold_ms = 10,
          })
        end
      end

      -- Spawn into this host's mux rather than straight into a child process,
      -- so a pane survives the GUI that opened it -- the wezterm-side answer to
      -- what tmux detach/attach does, and the reason panes come back after a
      -- GUI crash or a deliberate close. The mux server is started on demand;
      -- nothing has to be running first.
      --
      -- Not in a passthrough window. That window is a disposable view onto a
      -- remote tmux, which is doing the persisting itself, and leaving it on
      -- the plain process domain also keeps one launcher that still opens a
      -- terminal when the mux is the thing that is broken.
      --
      -- No matching `wezterm connect` launcher is needed: with default_domain
      -- pointing at the mux, a plain `wezterm start` -- which is what both the
      -- packaged .desktop file and KDE's TerminalApplication run -- adopts the
      -- windows already in the mux instead of adding another one.
      if not passthrough then
        config.default_domain = this_host
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
      }

      -- Everything from here to the end of tmux_keys is tmux's keymap wearing
      -- wezterm's clothes, and so is exactly what a passthrough window omits.
      local tmux_keys = {
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

        -- LEADER table: one-for-one with tmux's prefix table, so the same keys
        -- mean the same things in both and the muscle memory carries across.
        -- Keep the two in step by hand -- they are parallel definitions of one
        -- keymap, and tmux.nix says the same there.
        --
        -- "tmux's prefix table" means what `tmux list-keys -T prefix` prints,
        -- not what tmux.nix writes. tmux.nix writes 18 bindings; tmux binds 99.
        -- The first cut of this table mirrored the file and so silently dropped
        -- every default -- c, n, p, w, z and the rest -- which are exactly the
        -- ones fingers reach for without thinking. Port from the running
        -- keymap, never from the config.
        { key = '-', mods = 'LEADER', action = wezterm.action.SplitPane { direction = 'Down' } },
        { key = '\\', mods = 'LEADER', action = wezterm.action.SplitPane { direction = 'Right' } },
        { key = 'a', mods = 'LEADER|CTRL', action = wezterm.action.ActivateLastTab },
        -- The send-prefix escape, mirroring tmux.nix's `bind-key a send-prefix`.
        -- The only way to reach a nested tmux's prefix, since wezterm takes C-a
        -- unconditionally; without it an inner tmux would be undrivable.
        { key = 'a', mods = 'LEADER', action = wezterm.action.SendKey { key = 'a', mods = 'CTRL' } },
        { key = 'x', mods = 'LEADER', action = wezterm.action.CloseCurrentPane { confirm = true } },

        -- tmux prefix defaults. Nothing below appears in tmux.nix because tmux
        -- ships them; they still have to be written out here, because wezterm
        -- ships a different set.
        { key = 'c', mods = 'LEADER', action = wezterm.action.SpawnTab 'CurrentPaneDomain' },
        -- prefix+C is prefix+c aimed somewhere else: pick a domain, get a tab
        -- there. The fuzzy list covers every host at one binding, and stays
        -- correct when ssh_hosts grows.
        { key = 'C', mods = 'LEADER', action = wezterm.action.ShowLauncherArgs { flags = 'FUZZY|DOMAINS' } },
        { key = 'n', mods = 'LEADER', action = wezterm.action.ActivateTabRelative(1) },
        { key = 'p', mods = 'LEADER', action = wezterm.action.ActivateTabRelative(-1) },
        { key = 'w', mods = 'LEADER', action = wezterm.action.ShowTabNavigator },
        -- tmux's `s` is choose-tree over sessions; a workspace is herd's
        -- session. See workspace_picker for why this is not the built-in one.
        { key = 's', mods = 'LEADER', action = workspace_picker() },
        -- ...and `S` is the one tmux never had a binding for: make a session.
        -- tmux filled that from the shell (tmac, tmux-session in zsh.nix) and
        -- nothing filled it here, so LEADER s could only ever reach a workspace
        -- herd had already created. `A` is tmux-session -a: same workspace,
        -- plus herd's agent tab.
        {
          key = 'S',
          mods = 'LEADER',
          action = wezterm.action.PromptInputLine {
            description = 'workspace path',
            action = wezterm.action_callback(function(window, pane, line)
              switch_to_path(window, pane, resolve_path(pane, line), false)
            end),
          },
        },
        {
          key = 'A',
          mods = 'LEADER',
          action = wezterm.action.PromptInputLine {
            description = 'workspace path (with agent)',
            action = wezterm.action_callback(function(window, pane, line)
              switch_to_path(window, pane, resolve_path(pane, line), true)
            end),
          },
        },
        -- tmux's prefix+L, switch-client -l. Nothing to do on the first switch
        -- of a window's life, when there is no previous workspace yet.
        {
          key = 'L',
          mods = 'LEADER',
          action = wezterm.action_callback(function(window, pane)
            local prev = workspace_prev[window:window_id()]
            if prev then
              window:perform_action(wezterm.action.SwitchToWorkspace { name = prev }, pane)
            end
          end),
        },
        { key = '&', mods = 'LEADER', action = wezterm.action.CloseCurrentTab { confirm = true } },
        { key = 'z', mods = 'LEADER', action = wezterm.action.TogglePaneZoomState },
        { key = 'q', mods = 'LEADER', action = wezterm.action.PaneSelect },
        { key = '[', mods = 'LEADER', action = wezterm.action.ActivateCopyMode },
        { key = ']', mods = 'LEADER', action = wezterm.action.PasteFrom 'Clipboard' },
        -- tmux binds break-pane on both Enter and `!`.
        {
          key = '!',
          mods = 'LEADER',
          action = wezterm.action_callback(function(_, pane)
            pane:move_to_new_tab()
          end),
        },
        -- rename-window. Setting a title explicitly is what stops
        -- format-tab-title overwriting it, the same way an explicit
        -- rename-window switches tmux's automatic-rename off for that window.
        {
          key = ',',
          mods = 'LEADER',
          action = wezterm.action.PromptInputLine {
            description = 'Rename tab',
            action = wezterm.action_callback(function(window, _, line)
              if line and line ~= "" then
                window:active_tab():set_title(line)
              end
            end),
          },
        },
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
        --
        -- The rest of tmux's prefix table that has no counterpart, listed so the
        -- next person does not have to rediscover it: `d` (detach-client) --
        -- wezterm's GUI is the client and there is nothing to detach from;
        -- `Space` (next-layout) -- no layout engine, as above; `t` (clock-mode);
        -- `;` (last-pane) -- wezterm tracks no last-used pane, only tree order,
        -- and `q` is the honest substitute. Unbound on purpose, not forgotten.
        { key = 'o', mods = 'LEADER', action = wezterm.action.PaneSelect { mode = 'SwapWithActive' } },
        { key = 'r', mods = 'LEADER|ALT', action = wezterm.action.RotatePanes 'Clockwise' },

        -- herd. prefix+f is the dashboard, prefix+j the no-UI jump.
        {
          key = 'f',
          mods = 'LEADER',
          action = wezterm.action_callback(function(window, pane)
            if not herd_monitor_focus(window) then
              window:perform_action(herd_split(60, { 'herd', 'monitor', '--jump-exits' }), pane)
            end
          end),
        },
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

      if not passthrough then
        for _, key in ipairs(tmux_keys) do
          table.insert(config.keys, key)
        end
      end

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
      -- LEADER+digit selects a tab, as tmux's prefix+digit selects a window.
      -- baseIndex is 1 in tmux.nix, so the digit and the tab label agree and
      -- both are one off from wezterm's zero-based ActivateTab.
      if not passthrough then
        for i = 1, 9 do
          table.insert(config.keys, {
            key = tostring(i),
            mods = 'LEADER',
            action = wezterm.action.ActivateTab(i - 1),
          })
        end
      end

      -- tmux's prefix is C-a and its own ALT bindings are M--, M-| and M-r, so
      -- nothing here is swallowed on the way through.
      -- ALT digits go too: a passthrough window has no local tabs worth
      -- jumping to, and the remote side may well want the key.
      if not passthrough then
        for i = 1, 8 do
          table.insert(config.keys, {
            key = tostring(i),
            mods = 'ALT',
            action = wezterm.action.ActivateTab(i - 1),
          })
        end
      end

      -- One binding per remote host for the hosts reached often enough that
      -- the launcher's extra keystroke grates: prefix+M-<initial>. Generated
      -- from ssh_hosts, so a host added above gets its key for free. LEADER|ALT
      -- is otherwise used only by M-r (rotate-panes), which no hostname starts
      -- with.
      if not passthrough then
        for _, h in ipairs(ssh_hosts) do
          if h.host ~= this_host then
            table.insert(config.keys, {
              key = h.key,
              mods = 'LEADER|ALT',
              action = wezterm.action.SpawnTab { DomainName = h.host },
            })
          end
        end
      end

      -- Tab title = `host:command` -- which machine that tab's shell is on, and
      -- what is running on it. The host comes over the title string, which is
      -- the transport (see tmux.nix and zsh.nix); wezterm knows nothing about
      -- ssh or mosh and does not need to. The command comes from wezterm's own
      -- view of the pane's foreground process, so the two halves arrive by
      -- completely different routes and either can be missing on its own.
      local host_by_tab = {}
      wezterm.on('format-tab-title', function(tab)
        -- Accept only a bare hostname, so a program that sets its own title
        -- (nvim, less, a build) cannot leak into the tab bar. Remembering the
        -- last good value per tab beats falling back to the local hostname,
        -- which would mislabel a remote tab as this machine.
        -- An explicit LEADER+, rename wins outright: set_title is the signal
        -- that the user wants this tab called something, and overwriting it
        -- with a hostname would make the rename look broken.
        local name
        if tab.tab_title and tab.tab_title ~= "" then
          name = tab.tab_title
        else
          local host = (tab.active_pane.title or ""):match('^%s*([%w._-]+)%s*$')
          if host then
            host_by_tab[tab.tab_id] = host
          end
          name = host_by_tab[tab.tab_id] or wezterm.hostname():match('^[^.]+')

          -- The command half. foreground_process_name is an absolute path
          -- (/nix/store/.../bin/zsh), so only the basename is worth showing.
          -- An idle tab says `zsh` rather than hiding the shell: no special
          -- case, and it matches what tmux's automatic-rename shows.
          --
          -- A pane on a remote domain may report nothing at all -- the mux
          -- protocol carries the process name, but a pane proxied from another
          -- machine does not always have one to carry. Then the tab is just the
          -- host, which is what it said before this existed.
          local proc = tab.active_pane.foreground_process_name or ""
          local cmd = proc:match('([^/]+)$')
          if cmd and cmd ~= "" then
            name = name .. ':' .. cmd
          end
        end

        -- tmux's window list, in tmux's order: index, name, flags. A hostname
        -- alone could not tell two tabs on the same machine apart, and left
        -- LEADER+digit undiscoverable. tab_index + 1 so the digit shown is the
        -- digit that selects it, matching baseIndex = 1 in tmux.nix.
        --
        -- Z is tmux's zoom flag. The dot is monitor-activity, and only means
        -- anything on a tab that is not on screen -- the active tab's output is
        -- seen by definition, and wezterm keeps reporting it unseen for a beat
        -- after a switch, which would leave a dot on the tab you are reading.
        local label = ' ' .. tostring(tab.tab_index + 1) .. ' ' .. name
        if tab.active_pane.is_zoomed then
          label = label .. ' Z'
        end
        if not tab.is_active and tab.active_pane.has_unseen_output then
          label = label .. ' ●'
        end
        label = label .. ' '

        -- use_fancy_tab_bar is off, so formatting the label here is the whole
        -- of a tab's appearance; there is no colors.tab_bar to keep in step
        -- with it. Bold-and-blue for the active tab is the same emphasis
        -- tmux's default window-status-current-style gives.
        if tab.is_active then
          return {
            { Attribute = { Intensity = 'Bold' } },
            { Foreground = { AnsiColor = 'Blue' } },
            { Text = label },
          }
        end
        return {
          { Foreground = { AnsiColor = 'Silver' } },
          { Text = label },
        }
      end)

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
        elseif name == 'wz_workspace_cwd' then
          -- `wzs` from a shell (modules/zsh.nix). It sends a path and nothing
          -- else; the name comes from workspace_name_for here, so the naming
          -- rules live in one place. Deliberately not carried on herd's
          -- herd_workspace var: that one is herd's contract and switches
          -- without a cwd, so reusing it would silently drop the directory.
          switch_to_path(window, pane, value, false)
        end
      end)

      -- Stand-in for tmux's status-right, which a wezterm session does not get:
      -- workspace, time, date. tmux also shells out to `acpi` for battery, but
      -- acpi is in no feature's home.packages, so that segment has always
      -- rendered empty -- wezterm.battery_info() is the replacement if this rig
      -- ever runs on a laptop.
      --
      -- The left half is not tmux's status-left. That was the pane title, which
      -- the tab bar now carries; the slot is better spent on the two things
      -- tmux never had to show. Whether the prefix is armed: wezterm re-fires
      -- update-status on leader press, and 2000ms is long enough to forget you
      -- opened the window. And which machine the active pane is on, when that
      -- is not this one -- true the moment a tab is spawned on a domain,
      -- whereas the tab's own hostname label waits on the remote shell's first
      -- prompt to set a title.
      wezterm.on('update-status', function(window, pane)
        note_workspace(window)

        local left = {}
        if window:leader_is_active() then
          table.insert(left, { Foreground = { AnsiColor = 'Yellow' } })
          table.insert(left, { Text = ' ^A ' })
        end
        -- The handle can outlive the pane -- a split closing races the status
        -- tick -- and get_domain_name *raises* for a pane the mux has already
        -- dropped rather than returning nil, so `pane and` is not enough of a
        -- guard. It threw once an hour at the old 1000ms interval; at 100ms it
        -- would be a steady trickle of backtraces into the gui log.
        local ok, domain = pcall(function() return pane and pane:get_domain_name() end)
        if ok and domain and domain ~= this_host then
          table.insert(left, { Foreground = { AnsiColor = 'Teal' } })
          table.insert(left, { Text = ' ' .. domain .. ' ' })
        end
        window:set_left_status(wezterm.format(left))

        local now = wezterm.time.now()
        window:set_right_status(wezterm.format {
          -- A passthrough window looks identical otherwise, and "why did my
          -- prefix stop working" is a bad way to find out which one this is.
          { Foreground = { AnsiColor = 'Olive' } },
          { Text = passthrough and 'passthrough  ' or "" },
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
