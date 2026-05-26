{ config, pkgs, ... }:

{
  home.username = "dlangevi";
  home.homeDirectory = "/home/dlangevi";
  home.stateVersion = "25.05";

  nixpkgs.config.allowUnfree = true;

  home.packages = with pkgs; [
    ripgrep
    fd
    keepassxc
    prismlauncher
    htop
    claude-code

    bat         # Cat with syntax highlighting
    fzf         # Fuzzy finder
    zoxide      # Smarter cd command
    gh

    vintagestory
    spotify

    # User GUI apps
    discord
    signal-desktop
    calibre
    anki-bin
    obs-studio
    gimp
    zoom-us
    teams-for-linux
    smplayer
    kdePackages.kdenlive
    osu-lazer-bin
    filezilla
    mpv
    alacritty
  ];

  xdg.desktopEntries.aoe2url = {
    name = "AOE2 URL Handler";
    exec = "aoe2url %u";
    terminal = false;
    type = "Application";
    mimeType = [ "x-scheme-handler/aoe2de" ];
  };

  xdg.mimeApps.defaultApplications = {
    "x-scheme-handler/aoe2de" = "aoe2url.desktop";
  };

  home.sessionVariables = {
    EDITOR = "nvim";
  };

  programs.home-manager.enable = true;

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
    };
    initContent = ''
      export PATH="$HOME/.local/bin:$PATH"
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

  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    extraPackages = with pkgs; [
      # Language servers
      lua-language-server
      nil
      clang-tools
      rust-analyzer
      pyright
      clang
      nodejs
      # Tools
      ripgrep
      fd
      tree-sitter
    ];
  };
}
