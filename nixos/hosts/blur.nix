{ pkgs, ... }:

{
  networking.hostName = "blur";
  system.stateVersion = "25.05";

  users.users.dlangevi = {
    isNormalUser = true;
    shell = pkgs.zsh;
    description = "david";
    extraGroups = [ "networkmanager" "wheel" ];
    packages = with pkgs; [ kdePackages.kate ];
  };

  # Remote access.
  services.tailscale = {
    enable = true;
    # Without this the daemon cannot accept inbound UDP on 41641, so peers
    # fall back to DERP relays -- which works, but adds latency.
    openFirewall = true;
  };
}
