{ config, pkgs, lib, ... }:

{
  # Boot
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # The stock 5s menu is 5s of nothing on machines that boot one OS. Measured
  # on suspense as 3.771s of the 30.8s cold boot -- the second-largest single
  # item after firmware POST, and the only one that is pure dead wait.
  #
  # 0 does not remove the menu, it removes the *countdown*: systemd-boot still
  # opens it if a key is held during the loader window (Space is the
  # conventional one), so rolling back to an older generation still works.
  boot.loader.timeout = 0;

  # /boot had 7 entries. Every one is a file the loader enumerates and a
  # kernel+initrd pair occupying the 512M ESP; 5 is still several weeks of
  # rollback depth.
  boot.loader.systemd-boot.configurationLimit = lib.mkDefault 5;

  # Nix
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.auto-optimise-store = true;
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nixpkgs.config.allowUnfree = true;

  # Networking (per-host hostname is set in hosts/<name>.nix)
  networking.networkmanager.enable = true;
  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;

  # Locale
  time.timeZone = "America/Los_Angeles";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };

  # Desktop
  services.xserver.enable = true;
  services.desktopManager.plasma6.enable = true;
  services.xserver.xkb.layout = "us";
  services.xserver.xkb.variant = "";

  services.displayManager.sddm.enable = true;
  services.displayManager.sddm.wayland.enable = lib.mkDefault true;
  services.displayManager.defaultSession = lib.mkDefault "plasma";

  # Printing + SSH
  services.printing.enable = true;
  services.openssh.enable = true;

  # mosh. The client ships with home-manager's `base` feature, but incoming
  # sessions also need UDP 60000-61000 reachable. programs.mosh.enable would
  # open that on every interface; scope it the same way the media services are
  # scoped instead. mosh-server is spawned over SSH, hence openssh above.
  networking.firewall.extraCommands =
    let
      lanSubnet = "10.0.70.0/24";
      # Tailscale hands out addresses from the CGNAT range.
      tailnet = "100.64.0.0/10";
      allow = subnet:
        "iptables -A nixos-fw -p udp -s ${subnet} --dport 60000:61000 -j nixos-fw-accept";
    in ''
      ${allow lanSubnet}
      ${allow tailnet}
    '';

  # Audio (pipewire; old-name pulseaudio option renamed to services.pulseaudio)
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # User-facing programs
  programs.firefox.enable = true;
  programs.zsh.enable = true;

  environment.systemPackages = with pkgs; [
    vim
    libgcc
  ];
}
