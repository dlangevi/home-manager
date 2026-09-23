{ ... }:

{
  home.sessionPath = [ "$HOME/.local/bin" ];
  home.sessionVariables = {
    EDITOR = "nvim";
    DIRENV_LOG_FORMAT = "";
    # mosh-client otherwise rewrites the window title as "[mosh] <remote>".
    # The tab bar only accepts a bare hostname (modules/wezterm.nix), so the
    # prefixed form is discarded and the tab falls back to the local host --
    # a remote tab labelled with the name of the machine you left. This is
    # mosh's own opt-out; it is the only knob it offers.
    MOSH_TITLE_NOPREFIX = "1";
  };

  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
  };
  programs.zsh = {
    enable = true;
    oh-my-zsh = {
      enable = true;
      plugins = [ "git" "sudo" "ssh-agent" ];
      theme = "robbyrussell";
      extraConfig = ''
        zstyle :omz:plugins:ssh-agent quiet yes
        zstyle :omz:plugins:ssh-agent identities id_github id_bitbucket id_digitalocean id_aws.pem
      '';
    };
    shellAliases = {
      tmac = "tmux new -A -s";
      # Applying config: hm layer, nixos layer, both. dlsys itself is on PATH
      # via ~/.local/bin (see base.nix), so these work from any directory.
      # Renaming one means updating usage() in dlsys and the table in CLAUDE.md.
      hms  = "dlsys switch hm";
      nrs  = "dlsys switch nixos";
      alls = "dlsys switch all";
      herd-deploy = "~/auto/dl-herd/scripts/herd-deploy";
    };
    initContent = ''
      [[ -f ~/.zshenv.local ]] && source ~/.zshenv.local

      BAR=$(echo 🍏🍎🍐🍊🍋🍌🍉🍇🍓🫐🍈🍒🍑🥭🍍🥥🥝 | grep -o . | shuf -n1)
      PROMPT="$BAR $PROMPT"

      # Show the hostname only when this shell is on the far end of an ssh or
      # mosh connection. mosh-server drops SSH_*, so walk the process ancestry
      # too (tmux hides the parent, so the env check alone is not enough).
      # /proc rather than ps: same walk costs 0.4ms instead of 80ms of forks.
      _is_remote_session() {
        [[ -n $SSH_CONNECTION || -n $SSH_TTY || -n $SSH_CLIENT ]] && return 0
        local pid=$PPID stat comm
        repeat 10; do
          [[ -r /proc/$pid/stat ]] || return 1
          stat=$(</proc/$pid/stat)
          comm=''${''${stat%\) *}#*\(}
          [[ $comm == (mosh-server|sshd) ]] && return 0
          pid=''${''${(z)''${stat##*\) }}[2]}
          [[ $pid == 0 || $pid == 1 ]] && return 1
        done
        return 1
      }
      if _is_remote_session; then
        PROMPT="%F{yellow}%m%f $PROMPT"
      fi
      unset -f _is_remote_session

      # Title = "<host>:<command>". The host half is what makes a remote tab
      # readable (tmux's set-titles-string '#h'); the command half is what tmux's
      # automatic-rename used to show. wezterm parses both out of this one string
      # (see format-tab-title in wezterm.nix) -- it cannot get the command itself
      # for a pane proxied from another machine, so the shell has to say it.
      # oh-my-zsh's own title handling would otherwise put the cwd here, and it
      # checks this flag at runtime so setting it here is enough.
      DISABLE_AUTO_TITLE="true"
      _dl_title() { print -Pn "\e]2;%m:$1\a" }
      # At the prompt nothing is running, so the shell names itself, matching
      # what tmux's automatic-rename showed for an idle window.
      _host_title() { _dl_title zsh }
      precmd_functions+=(_host_title)
      # preexec gets the raw command line; first word, basename only, so
      # `/nix/store/.../bin/btop -t` reads as `btop`.
      _cmd_title() { _dl_title "''${''${1%% *}:t}" }
      preexec_functions+=(_cmd_title)

      # Name this pane in a way that survives leaving the machine.
      #
      # herd's dashboard aggregates sessions from every host, and jumping to one
      # means asking wezterm to focus a pane it is proxying from another
      # machine. Nothing else identifies that pane: wezterm reports a null tty
      # for it, having no local pty, and renumbers its pane id, because ids
      # belong to the mux that owns them. A user var crosses, and the pane's own
      # shell is the only thing in a position to set one.
      #
      # Computed once and re-emitted per prompt: the value cannot change for the
      # life of a pane, so a base64 fork on every prompt would be real cost for
      # a string that is always the same. Guarded on WEZTERM_PANE so this never
      # sprays OSC 1337 into a tmux pane, where passthrough is off and some
      # terminals would print it instead.
      #
      # The hostname comes from /proc rather than `hostname -s` because the far
      # end of this agreement -- herd's own `feed::hostname` -- reads exactly
      # that file. Two spellings of "this machine" that differ by a domain
      # suffix would make every jump to this host miss.
      if [[ -n "$WEZTERM_PANE" ]]; then
        typeset -g _herd_pane_var="$(printf '\e]1337;SetUserVar=herd_pane=%s\a' \
          "$(printf '%s:%s' "$(cat /proc/sys/kernel/hostname)" "$(tty)" | base64 -w0)")"
        _herd_pane_stamp() { print -n "$_herd_pane_var" }
        precmd_functions+=(_herd_pane_stamp)
      fi

      # mosh <[user@]host>: mosh's client/server vt emulation doesn't reliably
      # forward OSC 2 title updates once tmux is in the loop (mobile-shell/
      # mosh#477, #992), so the tab title is set here, locally, before any
      # bytes have to survive the mosh round-trip. It also covers the gap
      # before the remote shell's first prompt, when mosh has a title of its
      # own and nothing from the far end to put in it yet.
      smosh() {
        local host=''${1#*@}
        print -n "\e]2;''${host%%.*}\a"
        mosh "$@"
      }

      tmux-session() {
        local target name agent=0
        if [[ "$1" == "-a" || "$1" == "--agent" ]]; then
          agent=1
          shift
        fi
        if [ $# -eq 0 ]; then
          if [[ $PWD == $HOME ]]; then
            target=$HOME
            name=home
          elif [[ $PWD == $HOME/* ]]; then
            target=$PWD
            name=''${PWD#$HOME/}
          else
            target=$PWD
            name=$PWD
          fi
        elif [[ $1 == /* ]]; then
          target=$1
          name=$1
        else
          target=$HOME/$1
          name=$1
        fi
        name=''${name//./_}

        if ! tmux has-session -t="$name" &> /dev/null; then
          tmux new-session -s "$name" -n script -d -c "$target"
          if [ $agent -eq 1 ]; then
            tmux new-window -t "$name:" -n agent -c "$target" "herd layout"
          fi
        fi

        if [ -z ''${TMUX+x} ]; then
          tmux attach -t="$name" -c "$target"
        else
          tmux switch-client -t="$name"
        fi
      }
      _tmux-session() { _path_files -/ -W ~ }
      compdef _tmux-session tmux-session

      # `wzs [path]` is tmux-session for wezterm workspaces, and tmux-session
      # stays put beside it -- it still serves a passthrough window driving a
      # remote tmux.
      #
      # It sends the path and nothing else. Deriving the workspace name is
      # wezterm's Lua's job (workspace_name_for in modules/wezterm.nix), so the
      # rules -- $HOME is `home`, dots become underscores -- exist once.
      # modules/tmux.nix and modules/wezterm.nix already carry one pair of
      # hand-maintained parallel definitions between them; this would have made
      # a second, and one that fails quietly by opening a second workspace for
      # a directory that already had one.
      #
      # Guarded on WEZTERM_PANE like the herd_pane stamp above: elsewhere the
      # escape sequence would simply print.
      wzs() {
        if [[ -z "$WEZTERM_PANE" ]]; then
          print -u2 "wzs: not a wezterm pane"
          return 1
        fi
        local target=''${1:-$PWD}
        [[ $target == /* ]] || target=$HOME/$target
        printf '\e]1337;SetUserVar=wz_workspace_cwd=%s\a' \
          "$(printf '%s' "$target" | base64 -w0)"
      }
      _wzs() { _path_files -/ -W ~ }
      compdef _wzs wzs

      # Load per-directory zsh completions exposed via direnv (bin/_*), e.g.
      # music-mgmt/bin/_m completes music-mgmt/bin/m. Autoloading by bare
      # name (via fpath) rather than by path avoids zsh treating the file
      # as needing +x.
      autoload -Uz add-zsh-hook
      _direnv_local_completions() {
        [[ -d ./bin ]] || return
        fpath=($PWD/bin $fpath)
        local f name
        for f in ./bin/_*(N.); do
          name=''${f:t}
          unfunction -- "$name" 2>/dev/null
          autoload -Uz -- "$name"
          compdef -- "$name" "''${name#_}"
        done
      }
      add-zsh-hook chpwd _direnv_local_completions
      _direnv_local_completions
    '';
  };
}
