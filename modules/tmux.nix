{ pkgs, ... }:

let
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
      vim-tmux-navigator
      yank
    ];
    extraConfig = ''
      # Terminal overrides
      set -ag terminal-overrides ",xterm-256color:RGB"

      # Global options
      set-option -g focus-events on
      set-window-option -g xterm-keys on
      set-window-option -g monitor-activity on
      setw -g automatic-rename
      set-option -g repeat-time 2000
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
      set-option -g set-titles on
      set-option -g set-titles-string '#h'

      # Unbindings
      unbind j
      unbind C-b
      unbind '"'
      unbind %

      # Bindings
      bind-key - split-window -v
      bind-key \\ split-window -h
      bind-key Space list-panes
      bind-key Enter break-pane
      bind-key Space command-prompt "joinp -t:%%"
      bind-key -n C-up prev
      bind-key -n C-left prev
      bind-key -n C-right next
      bind-key -n C-down next

      # Pane resizing
      bind-key -r C-h run-shell "${resizeAccel}/bin/tmux-resize-accel L #{pane_id}"
      bind-key -r C-j run-shell "${resizeAccel}/bin/tmux-resize-accel D #{pane_id}"
      bind-key -r C-k run-shell "${resizeAccel}/bin/tmux-resize-accel U #{pane_id}"
      bind-key -r C-l run-shell "${resizeAccel}/bin/tmux-resize-accel R #{pane_id}"

      # Claude sessions: prefix+f opens the dashboard in a popup (it quits once a
      # jump lands, so it never covers the window you asked for); prefix+F is the
      # no-UI fzf jump straight to whatever wants attention.
      bind-key f display-popup -E -w 70% -h 70% "agent-session monitor --jump-exits"
      bind-key F run-shell "agent-session jump"

      # Layouts
      # prefix+R snaps an agent-session workspace back to 70/30 after a terminal
      # resize has skewed it; the geometry lives in agent-session, not here.
      bind-key R run-shell "agent-session relayout"
      bind o select-layout "active-only"
      bind M-- select-layout "even-vertical"
      bind M-| select-layout "even-horizontal"
      bind M-r rotate-window
    '';
  };
}
