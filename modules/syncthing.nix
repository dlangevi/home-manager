{ config, ... }:

{
  services.syncthing = {
    enable = true;
    overrideDevices = false;
    # Temporarily true to force the folder id/path onto each machine's
    # Syncthing daemon (replacing the old `keepassxc-db`). Flip back to
    # false after all three have applied.
    overrideFolders = true;
    settings.folders."sync" = {
      label = "Sync";
      path = "${config.home.homeDirectory}/Sync";
      devices = [ ];
    };
  };
}
