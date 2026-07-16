{ ... }:

{
  programs.git = {
    enable = true;
    settings = {
      user.name = "David Langevin";
      user.email = "dlangevi@uwaterloo.ca";
      alias.tree = "log --oneline --graph";
      pull.rebase = true;
      init.defaultBranch = "main";
      oh-my-zsh.hide-dirty = 1;
    };
  };

  programs.delta = {
    enable = true;
    options = {
      navigate = true;
      side-by-side = false;
      features = "decorations";
      keep-plus-minus-markers = false;
      decorations = {
        commit-decoration-style = "blue ol";
        commit-style = "raw";
        file-style = "omit";
        hunk-header-decoration-style = "blue";
        hunk-header-file-style = "bold red";
        hunk-header-line-number-style = "#067a00";
        hunk-header-style = "file line-number syntax";
        merge-conflict-begin-symbol = "~";
        merge-conflict-end-symbol = "~";
        merge-conflict-ours-diff-header-style = "#D08770 bold";
        merge-conflict-ours-diff-header-decoration-style = "#434C5E box";
        merge-conflict-theirs-diff-header-style = "#EBCB8B bold";
        merge-conflict-theirs-diff-header-decoration-style = "#434C5E box";
        blame-palette = "#2E3440 #3B4252 #434C5E #4C566A";
        keep-plus-minus-markers = false;
      };
      interactive = {
        keep-plus-minus-markers = false;
      };
    };
  };

  programs.gh = {
    enable = true;
    settings = {
      git_protocol = "https";
      prompt = "enabled";
      spinner = "enabled";
      aliases = {
        co = "pr checkout";
      };
    };
  };
}
