{ pkgs, ... }:

{
  imports = [ ../modules/media-audio.nix ];

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
    # suspense pushes the music library here over rsync. Password auth would
    # stall the ~2,400 unattended per-artist invocations on a prompt.
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINsXz3cvNB2Hp9walgAmlqjPNkWgOKVgvtbKis1N0m/O dlangevi@uwaterloo.ca"
    ];
  };

  environment.systemPackages = with pkgs; [ unzip ];

  system.autoUpgrade = {
    enable = true;
    flake = "github:dlangevi/home-manager";
    flags = [ "-L" ];
    dates = "Sun 03:00";
    randomizedDelaySec = "45min";
    allowReboot = false;
  };
}
