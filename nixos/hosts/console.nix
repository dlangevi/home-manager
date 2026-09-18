{ config, pkgs, ... }:

{
  networking.hostName = "console";
  system.stateVersion = "23.11";

  # Extended Bluetooth policy for HID console use
  hardware.bluetooth.settings = {
    General = {
      Experimental = true;
      FastConnectable = false;
    };
    Policy = {
      AutoEnable = false;
    };
  };

  services.displayManager.autoLogin = {
    enable = true;
    user = "console";
  };

  # udev hidraw rule
  services.udev.extraRules = ''
      SUBSYSTEMS=="hidraw", ACTION=="add", MODE="0660", GROUP="console"
  '';

  # User
  users.groups.console = { };
  users.users.console = {
    isNormalUser = true;
    shell = pkgs.zsh;
    description = "console";
    extraGroups = [ "networkmanager" "wheel" "console" ];
    packages = with pkgs; [ kdePackages.kate ];
  };

  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
    localNetworkGameTransfers.openFirewall = true;
    protontricks.enable = true;
    extraCompatPackages = [ pkgs.proton-ge-bin ];
  };

  # CPU freq cap for Ryzen 5 3550H thermal
  powerManagement.cpuFreqGovernor = "schedutil";
  powerManagement.resumeCommands = ''
    ${config.boot.kernelPackages.cpupower}/bin/cpupower frequency-set -u 2100MHz
  '';
  systemd.services.cap-cpu-freq = {
    description = "Cap CPU max frequency (disable turbo on Ryzen 5 3550H)";
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${config.boot.kernelPackages.cpupower}/bin/cpupower frequency-set -u 2100MHz";
    };
  };

  fonts.packages = with pkgs; [ noto-fonts-cjk-sans ];

  environment.systemPackages = with pkgs; [
    cmake
    gnumake
    nodejs_22
    python3
    gparted
    config.boot.kernelPackages.cpupower
  ];

  # Deliberately disabled, same as dance: this pulled the public repo weekly
  # and applied it as root unattended, so a compromise of the GitHub account
  # would have become root on this box within the week.
  #
  # Until console joins the tailnet and gets an entry in dlsys's
  # ssh_target map, it is upgraded by hand at the machine.
  system.autoUpgrade.enable = false;
}
