{ pkgs, lib, hostname, ... }:

let
  # The fleet, minus this machine -- sshing to yourself to get a nested tmux is
  # pure downside. See hosts.nix; `hostname` comes from flake.nix.
  hosts = import ../hosts.nix;
  remotes = lib.filterAttrs (h: _: h != hostname) hosts;

  # Cross-platform clipboard copy: reads stdin, writes to system clipboard.
  # Picks the right backend based on session env (Wayland / X11 / WSL).
  clipboardCopy = pkgs.writeShellApplication {
    name = "clipboard-copy";
    runtimeInputs = with pkgs; [ wl-clipboard xsel ];
    text = ''
      if [ -n "''${WAYLAND_DISPLAY:-}" ]; then
        wl-copy
      elif [ -n "''${DISPLAY:-}" ]; then
        xsel -i --clipboard
      else
        cat >/dev/null
        echo "clipboard-copy: no clipboard backend available" >&2
        exit 1
      fi
    '';
  };

  # Pane resize with acceleration: a fresh press nudges by 1, presses that land
  # inside the repeat window (same direction) jump by 3. State lives in tmux
  # user options so the script stays stateless between invocations.
  resizeAccel = pkgs.writeShellApplication {
    name = "tmux-resize-accel";
    runtimeInputs = with pkgs; [ tmux coreutils ];
    text = ''
      dir="$1"
      pane="$2"
      now=$(date +%s%3N)
      window=$(tmux show -gv repeat-time)
      last_dir=$(tmux show -gqv @resize_dir)
      last_ms=$(tmux show -gqv @resize_ms)
      step=1
      if [ "$dir" = "$last_dir" ] && [ -n "$last_ms" ] && [ $((now - last_ms)) -lt "$window" ]; then
        step=3
      fi
      tmux set -g @resize_dir "$dir"
      tmux set -g @resize_ms "$now"
      tmux resize-pane -t "$pane" "-$dir" "$step"
    '';
  };

  # prefix+f handler. The herd layout puts a monitor in the window's second
  # pane, so when one is already on screen a popup would just duplicate it --
  # focus that pane instead. Exit status is the signal back to tmux: 0 means
  # "no monitor here", which fires the if-shell branch that opens the popup.
  # `agent-session` is herd's former name; panes started before the rename are
  # still running under it, so match both until they cycle out.
  monitorFocus = pkgs.writeShellApplication {
    name = "tmux-monitor-focus";
    runtimeInputs = with pkgs; [ tmux gawk ];
    text = ''
      window="$1"
      target=$(tmux list-panes -t "$window" -F '#{pane_id} #{pane_current_command}' |
        awk '$2 == "herd" || $2 == "agent-session" { print $1; exit }')
      if [ -n "$target" ]; then
        tmux select-pane -t "$target"
        exit 1
      fi
      exit 0
    '';
  };
  # Attach a tmux window to another host, wezterm-ssh-domain style: the window
  # IS the remote machine. The remote session persists (reconnecting reattaches
  # it) but deliberately does not look nested -- `status off` kills the second
  # status bar, and `prefix C-b` keeps C-a arriving here, at the outer server,
  # so there is no prefix dance.
  #
  # Nothing here sets the remote session's prefix: it keeps the C-a its own
  # config gives it, and C-S-a reaches it via the root binding above. So C-a
  # drives this server, C-S-a drives the remote one, and neither has to be
  # escaped through the other.
  #
  # That matters beyond the keystroke, because the remote's prefix is also the
  # only way to read its scrollback -- the inner tmux owns the alternate
  # screen, so this pane's own history stays empty, and `C-S-a [` is the way
  # into the copy-mode that does have it.
  #
  # detach-on-destroy on is not optional. The remote runs this same config,
  # which sets it off globally; without the override, exiting the remote shell
  # drops the client into some other session on that host -- one with no status
  # bar and a foreign prefix, and no clue how it got there.
  #
  # Three shell-joined tmux calls rather than one `\;` command list: `\;` has to
  # survive the local shell, the remote shell and tmux's own command splitter,
  # and fails silently when one of them disagrees. `-A -d` also lets the options
  # land before any client attaches, so the remote status bar never flashes.
  #
  # mosh rather than ssh, so a suspended laptop or a changed network does not
  # take the window with it -- mosh roams instead of dropping, which is the
  # layer the persistent session cannot cover by itself. It needs `sh -c`
  # because mosh hands the command to the far end as argv without a shell to
  # parse it, so the && chain would otherwise arrive as literal arguments.
  # UDP 60000-61000 is already open fleet-wide (nixos/common.nix), and mosh
  # still bootstraps over ssh, which is where the connect timeout applies.
  domainConnect = pkgs.writeShellApplication {
    name = "tmux-domain";
    runtimeInputs = with pkgs; [ mosh openssh tmux ];
    text = ''
      dest="$1"   # user@host
      label="$2"  # this machine's hostname, baked in by nix

      # One remote session per local session, not per pane: a pane id would
      # change if the local server restarted (silently adopting a stale remote
      # session), while the local session name is stable and meaningful. Two
      # local sessions therefore get two independent remote sessions rather
      # than two clients mirroring one.
      sess=$(tmux display-message -p '#S' 2>/dev/null || echo default)
      name="dom-''${label}-''${sess}"
      name="''${name//[^A-Za-z0-9-]/-}"

      # console is on the tailnet but powered off most of the day: without an
      # explicit timeout that is a two-minute hang on a dead SYN, with nothing
      # on screen to say so.
      # Setting up the session and attaching to it are reported separately,
      # because their failures are not the same event and tmux gives them the
      # same exit status. Setup problems answer with 97; once the session
      # exists, the attach always reports 0, since by then every way out --
      # detaching with C-b d, or `exit` destroying the session -- is a normal
      # end to the window and not something to complain about.
      #
      # That last case is the one worth naming: exiting the remote shell
      # destroys the session, and if it was the only one on that host the
      # remote *server* shuts down too, so `tmux attach` returns 1 having
      # printed "no server running". Treating that as an error would leave a
      # "press any key" prompt behind every ordinary exit.
      remote="tmux new-session -A -d -s '$name' \
        && tmux set -t '$name' status off \
        && tmux set -t '$name' detach-on-destroy on \
        || exit 97
      tmux attach -t '$name'
      exit 0"

      # --predict=never: these hosts are a LAN and a tailnet, where the round
      # trip is short enough that predictive echo only shows up as underlined
      # guesses being corrected. Roaming is what mosh is here for, not latency
      # hiding.
      status=0
      mosh \
        --predict=never \
        --ssh="ssh -o ConnectTimeout=5" \
        "$dest" \
        -- sh -c "$remote" || status=$?

      # Hold the window open on failure. Without this an unreachable host just
      # flashes the window closed, taking ssh's diagnostic with it. 255 is
      # ssh's own "I could not do this" status, which covers both a host that
      # is off and a link that died mid-session.
      if [ "$status" -ne 0 ]; then
        case "$status" in
          97)  reason="remote tmux would not start or configure the session" ;;
          255) reason="could not reach the host (mosh bootstraps over ssh)" ;;
          *)   reason="exited $status" ;;
        esac
        echo >&2
        echo "tmux-domain: $dest ($name): $reason." >&2
        echo "Press any key to close this window." >&2
        read -r -n 1 -s
      fi
      exit "$status"
    '';
  };

  # prefix+C menu rows and the prefix+M-<key> shortcuts, both generated from
  # hosts.nix so a host added there gets all of it for free. -S means a second
  # press selects the existing window for that host instead of opening a
  # duplicate; -n names the window after the machine, which also pins it
  # against automatic-rename (which would otherwise call every one of them
  # "ssh").
  domainSpawn = h: v:
    "new-window -S -n ${h} '${domainConnect}/bin/tmux-domain ${v.user}@${h} ${hostname}'";

  domainMenu = lib.concatStringsSep " "
    (lib.mapAttrsToList (h: v: "\"${h}\" ${v.key} \"${domainSpawn h v}\"") remotes);

  domainKeys = lib.concatStringsSep "\n"
    (lib.mapAttrsToList (h: v: "bind-key M-${v.key} ${domainSpawn h v}") remotes);
in
{
  home.packages = [ clipboardCopy ];

  programs.tmux = {
    enable = true;
    prefix = "C-a";
    baseIndex = 1;
    historyLimit = 10000;
    keyMode = "vi";
    escapeTime = 10;
    terminal = "tmux-256color";
    plugins = with pkgs.tmuxPlugins; [
      {
        # The navigator binds C-h/j/k/l in the *root* table, guarded by a
        # `ps -o comm=` check on the pane's tty, and forwards the key only when
        # that command looks like vim. In a domain window the pane's command is
        # `mosh-client`, so without it in the pattern the outer server would swallow
        # C-h/j/k/l and run select-pane -- meaning nvim on the far end never
        # receives them, which on a fleet where nvim is the editor is the whole
        # point of the window gone.
        #
        # Adding it makes the outer server forward instead, and the remote's
        # own copy of this plugin then makes the real decision against the real
        # tty. `ssh` is listed too, so plain ssh panes behave the same way:
        # those keys now go to the far end rather than moving local panes,
        # which is the consistent reading of "the keys belong to what is on
        # screen".
        plugin = vim-tmux-navigator;
        extraConfig = "set -g @vim_navigator_pattern '(\\S+/)?g?\\.?(view|l?n?vim?x?|fzf|ssh|mosh-client)(diff)?(-wrapped)?'";
      }
      yank
    ];
    extraConfig = ''
      # Terminal overrides
      set -ag terminal-overrides ",xterm-256color:RGB"

      # C-S-a is "the prefix, but for the far end". It is needed at all because
      # a domain window has two tmux servers listening to one keyboard, and
      # both answer to C-a.
      #
      # The asymmetry worth understanding: only *this* server needs to tell the
      # two keys apart. A terminal sends byte 0x01 for both C-a and C-S-a, so
      # without extended keys (xterm's modifyOtherKeys) this server would match
      # its own prefix and eat the keystroke -- the remote would never see it,
      # which is why "let them both be C-a" cannot work. Hence extkeys, which
      # tmux does not infer from TERM=xterm-*, so it has to be declared.
      #
      # What it then sends onward is a plain C-a byte, not an extended
      # sequence. So the far end needs no configuration whatsoever: its tmux
      # sees an ordinary C-a and matches the prefix it already had. That keeps
      # the remote session a completely normal session -- attach to it directly
      # from that machine and it behaves like any other -- and keeps this
      # feature working against hosts that have not been rolled out to yet.
      #
      # Root table, so it needs no prefix of its own. In a local pane it just
      # sends C-a to whatever is running there.
      set -s extended-keys on
      set -as terminal-features ",xterm*:extkeys"
      bind-key -n C-S-a send-keys C-a

      # Global options
      set-option -g focus-events on
      set-window-option -g xterm-keys on
      set-window-option -g monitor-activity on
      setw -g automatic-rename
      set-option -g repeat-time 2000

      # Killing the last pane of a session destroys the session; switch the
      # client to the most recently active remaining session instead of exiting.
      set-option -g detach-on-destroy off
      setw -g aggressive-resize on

      # Mouse selection -> tmux buffer with notification
      set -g mouse on
      bind -T copy-mode-vi MouseDragEnd1Pane send -X copy-pipe-no-clear "${clipboardCopy}/bin/clipboard-copy; tmux display-message 'Copied to clipboard + tmux buffer'"
      bind -T copy-mode    MouseDragEnd1Pane send -X copy-pipe-no-clear "${clipboardCopy}/bin/clipboard-copy; tmux display-message 'Copied to clipboard + tmux buffer'"

      # Copy mode
      bind -T copy-mode-vi y send -X copy-pipe-no-clear "${clipboardCopy}/bin/clipboard-copy"

      # Prefix double-tap for last window
      bind-key a send-prefix
      bind-key C-a last-window

      # Status bar
      set-option -g status-justify left
      set-option -g status-bg black
      set-option -g status-fg cyan
      set-option -g status-interval 5
      set-option -g status-left-length 30
      set-option -g status-left '#[fg=magenta]» #[fg=blue,bold]#T#[default]  '
      set-option -g status-right '#[fg=red,bold] #[fg=cyan]»» #[fg=blue,bold]###S #[fg=magenta]%R %m-%d#(acpi | cut -d ',' -f 2)#[default]'
      set-option -g visual-activity on

      # Titles. wezterm shows the tab title, and this is the only channel that
      # survives the whole stack: tmux overwrites whatever the pane sets, and
      # OSC 2 rides an ssh or mosh connection like any other output. #h is the
      # short hostname of the machine running *this server*, so a tab attached
      # to a remote session names the far end with no wezterm-side plumbing.
      # #W is the window name -- automatic-rename makes that the running
      # command -- giving wezterm the same `<host>:<command>` string zsh emits
      # directly when tmux is not in the loop.
      set-option -g set-titles on
      set-option -g set-titles-string '#h:#W'

      # Unbindings
      unbind C-b
      unbind '"'
      unbind %

      # Bindings. These are one half of a keymap that exists twice: wezterm
      # multiplexes too now and its leader table in wezterm.nix mirrors this
      # one key for key. Nothing generates one from the other, so a binding
      # added here has to be added there by hand or the two drift apart.
      #
      # Nested, this server wins. wezterm's bindings are per-pane: a pane whose
      # foreground process is tmux (or ssh/mosh) has every key forwarded to it,
      # C-a included, so inside a session these bindings are simply the live
      # ones and wezterm's copy is unreachable. It answers in a pane at a bare
      # shell, which is the case tmux is not in.
      #
      # So the mirror is not decoration, but it is also never consulted here:
      # `bind-key a send-prefix` above now matters for tmux-in-tmux rather than
      # for tmux-in-wezterm.
      #
      # prefix+C is a deliberate exception to the key-for-key mirroring, and
      # should not be "fixed" into one: wezterm's prefix+C is ShowLauncherArgs
      # over its own ssh_domains, this one is a display-menu that opens an ssh
      # window. Same key, same intent, different mechanism -- and with
      # mux_mode false wezterm's has no domains to offer. The host list is
      # the one part that cannot drift, because both sides now read hosts.nix.
      bind-key - split-window -v
      bind-key \\ split-window -h
      bind-key Enter break-pane
      bind-key -n C-up prev
      bind-key -n C-left prev
      bind-key -n C-right next
      bind-key -n C-down next

      # Pane resizing
      bind-key -r C-h run-shell "${resizeAccel}/bin/tmux-resize-accel L #{pane_id}"
      bind-key -r C-j run-shell "${resizeAccel}/bin/tmux-resize-accel D #{pane_id}"
      bind-key -r C-k run-shell "${resizeAccel}/bin/tmux-resize-accel U #{pane_id}"
      bind-key -r C-l run-shell "${resizeAccel}/bin/tmux-resize-accel R #{pane_id}"

      # Claude sessions: prefix+f shows the dashboard -- it focuses this window's
      # monitor pane when the herd layout already has one, and only falls back to
      # a popup (which quits once a jump lands, so it never covers the window you
      # asked for) when the window has none. prefix+j is the no-UI fzf jump
      # straight to whatever wants attention.
      unbind F
      bind-key f if-shell "${monitorFocus}/bin/tmux-monitor-focus #{window_id}" "display-popup -E -w 70% -h 70% 'herd monitor --jump-exits'"
      bind-key j run-shell "herd jump"

      # Layouts
      # prefix+R snaps a herd workspace back to 70/30 after a terminal resize
      # has skewed it; the geometry lives in herd, not here.
      # Domains. prefix+c stays tmux's own local new-window; prefix+C is
      # prefix+c aimed somewhere else -- pick a host, get a window that IS that
      # host. These are the wezterm ssh-domain semantics, restored on the side
      # that owns sessions now that wezterm is not the multiplexer.
      #
      # The menu, its mnemonics and the per-host prefix+M-<key> shortcuts are
      # all generated from hosts.nix, and this machine is filtered out of its
      # own menu. M-r (rotate-window, below) is the only other M-<letter>, and
      # no hostname starts with r -- the same invariant wezterm's table relies
      # on.
      bind-key C display-menu -T "#[align=centre] domains " -x C -y C ${domainMenu}
      ${domainKeys}

      bind-key R run-shell "herd relayout"
      bind o select-layout "active-only"
      bind M-- select-layout "even-vertical"
      bind M-| select-layout "even-horizontal"
      bind M-r rotate-window

      # prefix+r re-sources the config after an `hms`. One tmux server means
      # this reaches every session at once. Note it is additive: a binding or
      # option deleted from this file stays live until the server restarts,
      # unless an explicit unbind elsewhere in this file removes it.
      bind-key r source-file ~/.config/tmux/tmux.conf \; display-message "tmux.conf reloaded"
    '';
  };
}
