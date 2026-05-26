{ pkgs, ... }:

{
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

      # Copy mode
      bind -T copy-mode-vi y send -X copy-pipe-no-clear "xsel -i --clipboard"

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

      # Titles
      set-option -g set-titles on
      set-option -g set-titles-string '#T #W'

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
      bind-key -r C-h resize-pane -L
      bind-key -r C-j resize-pane -D
      bind-key -r C-k resize-pane -U
      bind-key -r C-l resize-pane -R

      # Layouts
      bind o select-layout "active-only"
      bind M-- select-layout "even-vertical"
      bind M-| select-layout "even-horizontal"
      bind M-r rotate-window
    '';
  };
}
