{ config, ... }:

{
  services.syncthing = {
    enable = true;
    overrideDevices = false;
    overrideFolders = false;
    settings.folders."keepassxc-db" = {
      path = "${config.home.homeDirectory}/Sync/keepassxc";
      devices = [ ];
    };
  };
}
