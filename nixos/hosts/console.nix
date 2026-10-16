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
      # The external dongle is now the only controller (see the udev rule
      # below), so leaving this off meant a cold boot came up with no
      # Bluetooth at all until something powered the adapter by hand.
      AutoEnable = true;
    };
  };

  services.displayManager.autoLogin = {
    enable = true;
    user = "console";
  };

  # Remote access.
  services.tailscale = {
    enable = true;
    # Without this the daemon cannot accept inbound UDP on 41641, so peers
    # fall back to DERP relays -- which works, but adds latency.
    openFirewall = true;
  };

  # udev hidraw rule, plus: deauthorize the builtin Bluetooth radio, plus:
  # arm USB remote wakeup so a keypress resumes from S3.
  #
  # The Intel 8087:0a2a is the BT half of the M.2 combo card whose WiFi side
  # is wlp1s0 -- it hangs off an internal USB hub, not PCIe. Its antenna is
  # buried in the chassis and the range is poor, so we hard-disable it at
  # enumeration and let the external Realtek RTL8761BU dongle (0bda:8771) be
  # the only controller bluetoothd ever sees. Keyed on idVendor/idProduct
  # rather than the port path (3-2.2) because USB port numbering can shift
  # across reboots; the two radios have distinct IDs, so this is unambiguous.
  #
  # To undo: drop the authorized="0" line and `nrs`.
  #
  # The last two rules are why the box stopped waking on a keypress and had
  # to be woken at the power button. Suspend here is deep/S3, and in that
  # path the kernel only sends SET_FEATURE(DEVICE_REMOTE_WAKEUP) to a device
  # whose power/wakeup is enabled, and xHCI only sets the port wake-enable
  # bits when the root hub's flag is enabled. Both came up disabled -- the
  # K400 Plus receiver (046d:c52b) is wake-capable (bmAttributes a0) but was
  # never armed, so every wake came from PNP0C0C. The flag lives on the
  # usb_device and is re-derived on each enumeration, so it went away when
  # the receiver and the Realtek dongle swapped ports while the external
  # antenna was being fitted. Keyed on IDs, not port paths, for the same
  # reason as above -- it has already moved from 3-1 to 1-2 once.
  # 1d6b is the kernel's own vendor ID for root hubs; all four get it.
  services.udev.extraRules = ''
      SUBSYSTEMS=="hidraw", ACTION=="add", MODE="0660", GROUP="console"
      ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="8087", ATTR{idProduct}=="0a2a", ATTR{authorized}="0"
      ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="1d6b", ATTR{power/wakeup}="enabled"
      ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="046d", ATTR{idProduct}=="c52b", ATTR{power/wakeup}="enabled"
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

  # No Steam here. Gaming on console is Moonlight streaming from suspense
  # (moonlight-qt, desktop-apps feature), so the local 32-bit libs, Proton
  # builds, and Remote Play firewall holes bought nothing but disk and
  # attack surface.

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


  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      2234  # nicotine+ (soulseek listening port; match it in Preferences -> Network)
    ];
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
