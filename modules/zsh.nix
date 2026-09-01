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
