{ ... }:

{
  home.sessionVariables = {
    EDITOR = "nvim";
  };

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

  home.file.".local/bin/aoe2url" = {
    source = ../scripts/aoe2url;
    executable = true;
  };

  home.file.".local/bin/captureage" = {
    source = ../scripts/captureage;
    executable = true;
  };
}
