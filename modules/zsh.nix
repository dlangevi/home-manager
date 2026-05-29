{ ... }:

{
  home.sessionPath = [ "$HOME/.local/bin" ];
  home.sessionVariables.EDITOR = "nvim";

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
      hms = ''nix flake update dldev --flake ~/.config/home-manager 2>/dev/null; home-manager switch --extra-experimental-features "nix-command flakes" --flake ~/.config/home-manager#dev'';
      as-deploy = "~/auto/dldev/scripts/as-deploy";
    };
    initContent = ''
      [[ -f ~/.zshenv.local ]] && source ~/.zshenv.local

      tmux-session() {
        SESSIONNAME=''${1//./_}
        tmux has-session -t=$SESSIONNAME &> /dev/null

        if [ $? != 0 ]
        then
          tmux new-session -s $SESSIONNAME -n script -d -c $HOME/$1
        fi
        if [ -z ''${TMUX+x} ]
        then
          tmux attach -t=$SESSIONNAME -c $HOME/$1
        else
          tmux switch-client -t=$SESSIONNAME
        fi
      }
    '';
  };
}
