{ ... }:

{
  home.sessionPath = [ "$HOME/.local/bin" ];
  home.sessionVariables = {
    EDITOR = "nvim";
    DIRENV_LOG_FORMAT = "";
  };

  programs.fzf.enableZshIntegration = true;
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
      hms  = ''~/.config/home-manager/bootstrap upgrade hm'';
      nrs  = ''~/.config/home-manager/bootstrap upgrade nixos'';
      alls = ''~/.config/home-manager/bootstrap upgrade all'';
      as-deploy = "~/auto/dldev/scripts/as-deploy";
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

      # Title = hostname, matching tmux's set-titles-string '#h'. This covers
      # bare shells outside a session; oh-my-zsh's own title handling would
      # otherwise put the cwd and last command there, and it checks this flag
      # at runtime so setting it here is enough.
      DISABLE_AUTO_TITLE="true"
      _host_title() { print -Pn "\e]2;%m\a" }
      precmd_functions+=(_host_title)

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
            tmux new-window -t "$name:" -n agent -c "$target" agent-session
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
    '';
  };
}
