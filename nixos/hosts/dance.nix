{ pkgs, ... }:

{
  networking.hostName = "dance";
  system.stateVersion = "24.11";

  services.displayManager.autoLogin = {
    enable = true;
    user = "dance";
  };

  services.udev.extraRules = ''
      SUBSYSTEMS=="hidraw", ACTION=="add", MODE="0660", GROUP="dance"
  '';

  users.groups.dance = { };
  users.users.dance = {
    isNormalUser = true;
    shell = pkgs.zsh;
    description = "dance";
    extraGroups = [ "networkmanager" "wheel" "dance" ];
  };

  environment.systemPackages = with pkgs; [ unzip ];

  system.autoUpgrade = {
    enable = true;
    flake = "github:dlangevi/home-manager";
    flags = [ "--impure" "-L" ];
    dates = "Sun 03:00";
    randomizedDelaySec = "45min";
    allowReboot = false;
  };
}
