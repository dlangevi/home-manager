{ config, ... }:

{
  services.syncthing = {
    enable = true;
    overrideDevices = false;
    # Temporarily true to migrate the folder path from ~/Sync/keepassxc to
    # ~/Sync. Flip back to false after all three machines have applied.
    overrideFolders = true;
    # Folder id kept as `keepassxc-db` to avoid re-pairing across machines;
    # it now hosts arbitrary synced content, not just the KeePassXC DB.
    settings.folders."keepassxc-db" = {
      path = "${config.home.homeDirectory}/Sync";
      devices = [ ];
    };
  };
}
