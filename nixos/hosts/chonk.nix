{ config, pkgs, lib, ... }:

{
  networking.hostName = "chonk";
  system.stateVersion = "26.05";

  # Remote access, and how syncthing.nix's peers (suspense, dance) are
  # actually reachable -- their addresses are tailnet (MagicDNS) names.
  services.tailscale = {
    enable = true;
    # Without this the daemon cannot accept inbound UDP on 41641, so peers
    # fall back to DERP relays -- which works, but adds latency.
    openFirewall = true;
  };

  users.users."david" = {
    isNormalUser = true;
    description = "david";
    extraGroups = [ "networkmanager" "wheel" ];
    packages = with pkgs; [
      kdePackages.kate
    #  thunderbird
    ];
  };
}
