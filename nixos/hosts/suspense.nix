{ config, pkgs, pkgs-ollama, lib, ... }:

{
  networking.hostName = "suspense";
  system.stateVersion = "23.11";

  services.sunshine = {
    enable = true;
    autoStart = true;
    capSysAdmin = true;
    openFirewall = true;
  };

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 42420 ]; # vintagestory
    allowedTCPPortRanges = [
      { from = 1714; to = 1764; } # KDE Connect
    ];
    allowedUDPPortRanges = [
      { from = 1714; to = 1764; } # KDE Connect
    ];
  };

  # Removable media
  services.devmon.enable = true;
  services.gvfs.enable = true;
  services.udisks2.enable = true;

  # GPU: GeForce GTX 1060 6GB (Pascal).
  hardware.graphics.enable = true;
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia = {
    modesetting.enable = true;

    # Saves all of VRAM across suspend rather than the bare essentials, which
    # avoids graphical corruption and app crashes on resume.
    powerManagement.enable = true;
    # Turing or newer only.
    powerManagement.finegrained = false;

    # The open kernel module supports Turing and newer; Pascal needs the
    # proprietary one.
    open = false;

    nvidiaSettings = true;

    # NVIDIA dropped Pascal in the 595.x branch, so `stable` (595.71.05 as of
    # nixpkgs 26.05) probes the card and ignores it, leaving X with "no screens
    # found". 580 is the legacy branch Pascal is supported through.
    package = config.boot.kernelPackages.nvidiaPackages.legacy_580;
  };

  # NVIDIA on Wayland is flaky — stay on X11
  services.displayManager.defaultSession = "plasmax11";
  services.displayManager.sddm.wayland.enable = false;

  # udev hidraw rule (dlangevi is in group "console" historically)
  services.udev.extraRules = ''
      SUBSYSTEMS=="hidraw", ACTION=="add", MODE="0660", GROUP="console"
  '';

  users.groups.console = { };
  users.users.dlangevi = {
    isNormalUser = true;
    shell = pkgs.zsh;
    description = "david";
    extraGroups = [ "networkmanager" "wheel" "console" ];
    packages = with pkgs; [ kdePackages.kate ];
  };

  # Run non-Nix binaries
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [ stdenv.cc.cc ];

  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
    localNetworkGameTransfers.openFirewall = true;
    gamescopeSession.enable = true;
  };

  fonts.packages = with pkgs; [
    nerd-fonts.agave
    noto-fonts
    noto-fonts-cjk-sans
  ];

  # Suppress IM modules that break some Qt/GTK apps here
  environment.variables.GTK_IM_MODULE = lib.mkForce "";
  environment.variables.QT_IM_MODULE = lib.mkForce "";

  environment.systemPackages = with pkgs; [
    # GTX 1060 is Pascal (sm_61); nixpkgs default cudaArches starts at
    # sm_75, so the cached binary panics with "no kernel image is
    # available for execution on the device". Force a local rebuild
    # that includes Pascal.
    (pkgs-ollama.ollama.override {
      acceleration = "cuda";
      cudaArches = [ "sm_61" ] ++ pkgs-ollama.cudaPackages.flags.realArches;
    })
    steam-run
    kdePackages.partitionmanager
    gparted
    piper
  ];

  services.ratbagd.enable = true;

  # libratbag doesn't ship a device entry for the Kone Pure Ultra (usb:1e7d:2dd2).
  # The Ultra uses the same protocol family as the original Kone Pure, so point
  # it at the existing roccat-kone-pure driver via a local .device override.
  environment.etc."libratbag/devices/roccat-kone-pure-ultra.device".text = ''
    [Device]
    Name=Roccat Kone Pure Ultra
    DeviceMatch=usb:1e7d:2dd2
    Driver=roccat-kone-pure
    DeviceType=mouse
  '';
}
