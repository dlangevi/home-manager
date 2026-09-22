{ pkgs, ... }:

{
  imports = [ ../modules/media-audio.nix ../modules/snapcast.nix ../modules/mympd.nix ../modules/freelance-site.nix ../modules/album-requests.nix ../modules/slskd.nix ];

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
      # root@suspense, for the dance-storage sshfs mount (see
      # ../modules/dance-storage.nix). Only the public half lives here --
      # the private key is root's on suspense.
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOnaEZ5iCiungP/aPu0OkEAc5PMRkEvAaGRXGxgKHiuT root@suspense"
    ];
  };

  environment.systemPackages = with pkgs; [ unzip ];

  # Deliberately disabled. This pulled `github:dlangevi/home-manager` weekly
  # and applied it as root with no human in the loop, so a compromise of the
  # GitHub account or the repo would have become root on this box within the
  # week. dance is upgraded from suspense instead, via `./dlsys rollout`.
  system.autoUpgrade.enable = false;
}
