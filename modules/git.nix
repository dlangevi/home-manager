{ ... }:

{
  programs.git = {
    enable = true;
    settings.user.name = "David Langevin";
    settings.user.email = "dlangevi@uwaterloo.ca";
  };

  programs.delta = {
    enable = true;
    options = {
      navigate = true;
      side-by-side = false;
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
