{ config, ... }:

{
  services.syncthing = {
    enable = true;
    # Extra peers added by hand in the GUI survive a switch.
    overrideDevices = false;
    # The folder's device list is declared here, so it must be authoritative --
    # with this false, a machine that never got the share would silently keep
    # syncing nothing.
    overrideFolders = true;
    settings.options = {
      # Peers reach each other over the tailnet, so there is no reason to
      # publish our addresses to Syncthing's public discovery servers --
      # a device ID is a public key fingerprint, but looking it up there
      # returns the machine's current IP. Keeping announce off is what makes
      # the IDs below safe to check into a public repo.
      globalAnnounceEnabled = false;
    };
    settings.devices = {
      console.id = "DCJHK4Q-NG3VPNY-RMOO6UF-5XL7P57-DF6QWUK-ORST43S-P3NFYXM-5IKBWQ3";
      suspense = {
        id = "GUTYZ4M-4GSE4YW-L7DXJHY-A7QAVVV-JTEGC37-XEVKWKJ-XJGNSEG-6MDA7QZ";
        # MagicDNS name -- with discovery off, this is how the peer is found.
        addresses = [ "tcp://suspense:22000" ];
      };
    };
    settings.folders."sync" = {
      label = "Sync";
      path = "${config.home.homeDirectory}/Sync";
      devices = [ "console" "suspense" ];
    };
  };
}
