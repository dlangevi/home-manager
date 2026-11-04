{ pkgs, ... }:

{
  imports = [ ../modules/media-audio.nix ../modules/snapcast.nix ../modules/mympd.nix ../modules/freelance-site.nix ../modules/album-requests.nix ../modules/slskd.nix ../modules/wol-relay.nix ../modules/querying.nix ../modules/frameart-host.nix ../modules/frameart-narrate.nix ];

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
      # console@dance-admin, a dedicated unrestricted key for console. The
      # console@frameart key above (frameart-host.nix) stays rrsync-only
      # for the image sync; this one is a separate keypair so console can
      # get a real shell (dlsys rollout, ad-hoc admin) without loosening
      # that restriction. Only the public half lives here -- the private
      # key is console's, at ~/.ssh/id_ed25519_dance-admin.
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOW8W08WgSljSKmZKJjkDd8HGQ9a2K+hMjrfr3BCYmtv console@dance-admin"
    ];
  };

  # So laughtale can hit this box for a logged-in remote session over
  # Moonlight. Unlike suspense, dance has no NVIDIA/CUDA conflict to work
  # around, so capSysAdmin stays at its module default (true) -- needed for
  # the KMS/portal capture backends under Wayland, which is what
  # autoLogin + plasma6 + sddm.wayland.enable defaults to here.
  services.sunshine = {
    enable = true;
    autoStart = true;
    openFirewall = true;
  };

  environment.systemPackages = with pkgs; [ unzip ];

  # Deliberately disabled. This pulled `github:dlangevi/home-manager` weekly
  # and applied it as root with no human in the loop, so a compromise of the
  # GitHub account or the repo would have become root on this box within the
  # week. dance is upgraded from suspense instead, via `./dlsys rollout`.
  system.autoUpgrade.enable = false;
}
