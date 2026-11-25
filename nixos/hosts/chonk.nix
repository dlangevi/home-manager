{ config, pkgs, lib, ... }:

{
  networking.hostName = "chonk";
  system.stateVersion = "26.05";

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
