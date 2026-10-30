{ pkgs, ... }:

{
  networking.hostName = "nixos";
  system.stateVersion = "25.05";

  users.users.dlangevi = {
    isNormalUser = true;
    shell = pkgs.zsh;
    description = "david";
    extraGroups = [ "networkmanager" "wheel" ];
    packages = with pkgs; [ kdePackages.kate ];
  };
}
