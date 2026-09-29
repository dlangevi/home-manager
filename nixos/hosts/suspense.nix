{ config, pkgs, lib, ... }:

{
  imports = [ ../modules/dance-storage.nix ];

  networking.hostName = "suspense";
  system.stateVersion = "23.11";

  # The 17G swap partition declared in ../hardware/suspense.nix is an OOM
  # safety valve for build spikes, not a way to pretend there is more RAM than
  # there is -- 32G should be used as 32G. The kernel default of 60 is tuned
  # for machines where paging is routine and will evict a desktop's idle
  # working set (browser tabs, a long-lived editor) to reclaim page cache,
  # which is felt as stutter on the next focus. 10 leaves swap almost entirely
  # to genuine pressure without disabling it outright, as 0 effectively would.
  boot.kernel.sysctl."vm.swappiness" = 10;

  # Remote access. Jellyfin (the reason this was originally enabled) has
  # moved to dance along with the media library, but keep suspense reachable
  # over the tailnet regardless -- e.g. for Sunshine/Moonlight remote play.
  services.tailscale = {
    enable = true;
    # Without this the daemon cannot accept inbound UDP on 41641, so peers
    # fall back to DERP relays -- which works, but adds latency.
    openFirewall = true;
  };

  services.sunshine = {
    enable = true;
    autoStart = true;
    capSysAdmin = true;
    openFirewall = true;
    settings = {
      # Restrict capture to the 1440p monitor; the second display confuses
      # single-screen Moonlight clients.
      output_name = "DP-2";
      resolutions = "[1280x720,1920x1080,2560x1440]";
      fps = "[60,120]";
    };
  };

  # Resilio Sync removed. It was the single loudest thing on this machine:
  # rslsync runs with its debug log mask at FFFFFFFF and wrote 11307 of the
  # 15481 journal lines in a boot -- 73% of the journal, and a standing 2 GB of
  # archived journals -- which is real write contention during startup. The
  # tree it served is copied locally now.
  #
  # Deliberately not cleaned up here: /srv/resilio and /var/lib/resilio-sync
  # still hold the data and the peer identity. Removing the module stops the
  # daemon and drops the rslsync user; it does not touch either path. Delete
  # them by hand once you are sure the local copy is complete.

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      2234  # nicotine+ (soulseek listening port; match it in Preferences -> Network)
      42420 # vintagestory
    ];
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

  # GPU: GeForce RTX 2070 SUPER 8GB (Turing, sm_75).
  hardware.graphics.enable = true;
  services.xserver.videoDrivers = [ "nvidia" ];

  # nvidia's module load is ~4.3s and it used to sit on the critical chain:
  # the nvidia entries land in boot.kernelModules (set by the nvidia module at
  # nixos/modules/hardware/video/nvidia.nix:820), which becomes
  # /etc/modules-load.d/nixos.conf, which systemd-modules-load.service reads --
  # and that unit is Before=sysinit.target, so the firewall, NetworkManager,
  # tailscaled and sddm all queued behind a GPU coming up.
  #
  # Fix: take nvidia out of that file and load it from the unit below, which
  # runs concurrently with the rest of userspace and gates only the display
  # manager, the one thing that actually needs the driver.
  #
  # The filter reads config.boot.kernelModules rather than hardcoding a
  # replacement list -- no recursion, because this defines environment.etc and
  # not boot.kernelModules -- so any module another NixOS module contributes
  # later still flows through. mkForce is needed because kernel.nix already
  # defines this file. The modules themselves stay in the module tree (they
  # come from extraModulePackages), so modprobe still finds them.
  environment.etc."modules-load.d/nixos.conf".source = lib.mkForce (
    pkgs.writeText "nixos.conf" (
      lib.concatStringsSep "\n"
        (lib.filter (m: !(lib.hasPrefix "nvidia" m)) config.boot.kernelModules)
      + "\n"
    )
  );

  systemd.services.nvidia-modules = {
    description = "Load the NVIDIA kernel modules off the sysinit critical path";
    # DefaultDependencies=no is the load-bearing part: it drops the implicit
    # Before=sysinit.target that makes systemd-modules-load a boot barrier.
    # wantedBy sysinit.target still pulls it in at the very start, so it runs
    # alongside everything else rather than in front of it.
    unitConfig.DefaultDependencies = false;
    wantedBy = [ "sysinit.target" ];
    # No After= on systemd-modules-load: nvidia needs nothing that unit loads,
    # and ordering behind it cost 1.09s of pure waiting (measured -- the unit
    # finished at 1.089s and this one started at 1.094s). /nix is mounted in
    # the initrd and the module tree is in place before stage 2 starts, so
    # there is nothing left to wait for. kmod takes its own lock, so racing
    # udev's coldplug is safe.
    before = [ "display-manager.service" "shutdown.target" ];
    conflicts = [ "shutdown.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.kmod}/bin/modprobe -a nvidia nvidia_modeset nvidia_uvm nvidia_drm";
    };
  };

  # Do not put these in boot.initrd.kernelModules. Measured twice: it takes
  # the initrd from 27 MB to 188.6 MiB, and that costs ~3.1s of firmware time
  # and ~1.6s of loader time to save ~3.15s of userspace -- about 3s net worse
  # to reach graphical.target.
  #
  # The firmware penalty is the counterintuitive part and it is real: two runs
  # with a ~190 MiB initrd measured 12.652s and 12.559s of firmware on two
  # *different* physical disks, while two runs with a 27 MB initrd measured
  # 9.444s and 9.521s. The clustering is far tighter than the run-to-run
  # noise, so it tracks initrd size rather than which disk holds the ESP.
  #
  # configurationLimit is likewise back to the common.nix default of 5: the
  # override to 3 only existed because 188.6 MiB generations did not fit.

  hardware.nvidia = {
    modesetting.enable = true;

    # Saves all of VRAM across suspend rather than the bare essentials, which
    # avoids graphical corruption and app crashes on resume.
    powerManagement.enable = true;
    # Turing or newer, *and* only meaningful for PRIME render offload on a
    # hybrid-graphics laptop -- it powers the dGPU down between offloaded
    # clients. This is a desktop with a single discrete card driving the
    # displays, so there is nothing to gate; enabling it just adds an
    # assertion failure for the missing prime.offload config.
    powerManagement.finegrained = false;

    # The open kernel module supports Turing and newer, so the 2070 SUPER is
    # eligible -- but open-module maturity on first-gen Turing GeForce is the
    # least certain part of this move, and flipping it in the same reboot as
    # the driver-branch jump would leave two suspects if X fails to start.
    # Kept proprietary; flip to true as its own change.
    open = false;

    nvidiaSettings = true;

    # No `package` pin. 580 was the last branch carrying Maxwell/Pascal/Volta
    # and had to be pinned for the GTX 1060; Turing is unaffected by that drop
    # and rides the current branch, so the module default (595.71.05 in
    # nixpkgs 26.05) is correct here.
  };

  # NVIDIA on Wayland is flaky — stay on X11
  services.displayManager.defaultSession = "plasmax11";
  services.displayManager.sddm.wayland.enable = false;

  # udev hidraw rule (dlangevi is in group "console" historically)
  services.udev.extraRules = ''
      SUBSYSTEMS=="hidraw", ACTION=="add", MODE="0660", GROUP="console"
      SUBSYSTEM=="sound", ACTION=="add", ATTRS{idVendor}=="8888", ATTRS{idProduct}=="1717", TAG+="systemd", ENV{SYSTEMD_WANTS}+="fosi-mc331-mixer.service"
  '';

  users.groups.console = { };
  users.users.dlangevi = {
    isNormalUser = true;
    shell = pkgs.zsh;
    description = "david";
    # cdrom: the USB optical drive is root:cdrom 0660. The device also
    # carries a uaccess ACL for the seated user, which makes interactive
    # sessions work and non-seated ones fail confusingly.
    extraGroups = [ "networkmanager" "wheel" "console" "cdrom" ];
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

  # Off for now, following the GTX 1060 -> RTX 2070 SUPER swap.
  #
  # Note what this silently costs: herd's `refresh-task` asks this endpoint for
  # session labels and does not error when nothing is listening -- the label
  # just stays empty. That is the symptom to expect, not a failed service.
  #
  # To re-enable, restore:
  #
  #   services.ollama = {
  #     enable = true;
  #     # nixpkgs' ollama-cuda is unfree CUDA, so cache.nixos.org never carries
  #     # it -- llama-cpp compiles locally on every rebuild. The default
  #     # cudaArches builds nine targets for a one-card machine; sm_75 is the
  #     # 2070 SUPER and cuts that work by ~9x. Update it if the GPU changes,
  #     # or ollama dies with "no kernel image is available for execution on
  #     # the device".
  #     package = pkgs.ollama-cuda.override { cudaArches = [ "sm_75" ]; };
  #     # DynamicUser with its own /var/lib/ollama store, so the model has to
  #     # be declared rather than inherited from whatever sits in ~/.ollama.
  #     loadModels = [ "qwen2.5:3b" ];
  #   };
  services.ollama.enable = false;

  environment.systemPackages = with pkgs; [
    # This box has two EFI System Partitions -- the live 1000M one and the
    # 512M original kept as a recovery path -- so which one the firmware
    # actually picks is a question that now comes up. bootctl reports the ESP
    # it booted from but will not show or reorder the NVRAM BootOrder.
    efibootmgr
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

  # The Fosi Audio MC331 reports a bogus USB volume-control range — the kernel
  # logs "Unlikely big volume range (=4096), cval->res is probably wrong" — and
  # the control is effectively unusable: PipeWire's mapping collapses most of
  # the slider to a raw value of 0, i.e. silence. Take the hardware mixer out
  # of the loop entirely and do volume in software.
  #
  # soft-mixer has to be set on the card as well as the node; setting it on the
  # node alone leaves PipeWire still writing the hardware control.
  services.pipewire.wireplumber.extraConfig."51-fosi-mc331-soft-mixer" = {
    "monitor.alsa.rules" = [
      {
        matches = [
          { "device.name" = "~alsa_card.usb-MV-SILICON_Fosi_Audio_MC331.*"; }
          { "node.name" = "~alsa_output.usb-MV-SILICON_Fosi_Audio_MC331.*"; }
        ];
        actions.update-props = {
          "api.alsa.soft-mixer" = true;
        };
      }
    ];
  };

  # With soft-mixer on, nothing drives the hardware control any more, so it sits
  # wherever it was left — which after a replug or a boot is 0. Pin it to max
  # once, whenever the card appears. Card id "MC331" is stable; the numeric
  # index is not.
  systemd.services.fosi-mc331-mixer = {
    description = "Pin the Fosi Audio MC331 hardware mixer to maximum";
    serviceConfig = {
      Type = "oneshot";
      # The card can take a moment to expose its mixer controls after the
      # udev add event, so retry briefly rather than failing the boot.
      ExecStart = pkgs.writeShellScript "fosi-mc331-mixer" ''
        for _ in $(seq 20); do
          if ${pkgs.alsa-utils}/bin/amixer -c MC331 sset PCM 100% >/dev/null 2>&1; then
            exit 0
          fi
          sleep 0.5
        done
        echo "MC331 mixer control never appeared" >&2
        exit 1
      '';
    };
  };


  # Tailscale registers an *exclusive* resolvconf record, so /etc/resolv.conf
  # lists only 100.100.100.100. The tailnet publishes no global resolvers, so
  # tailscaled has to forward "." to the LAN resolver it learns from
  # NetworkManager's resolvconf record.
  #
  # On resume tailscaled re-applies its DNS config within ~5s -- before
  # NetworkManager has rewritten that record from the new DHCP lease -- and so
  # captures an empty upstream list:
  #   dns: Resolvercfg: {Routes:{.:[] ...}}          (broken)
  #   dns: Resolvercfg: {Routes:{.:[10.0.70.1] ...}} (working)
  # Every query then fails with "no upstream resolvers set, returning SERVFAIL"
  # until something makes NM rewrite the record. Link, DHCP lease and default
  # route all recover on their own in ~5s, which is why this presents as "the
  # ethernet is up but there is no internet"; toggling the link by hand was
  # only working because it forced NM to redo DHCP.
  #
  # Re-apply tailscaled's DNS config from NM's dispatcher, which by
  # construction runs after NM has applied both IP and DNS -- so it cannot
  # lose the race. This also covers any other DHCP DNS change, not just
  # resume.
  networking.networkmanager.dispatcherScripts = [{
    type = "basic";
    source = pkgs.writeShellScript "tailscale-dns-resync" ''
      iface="$1"
      action="$2"
      case "$action" in
        up|dhcp4-change|dhcp6-change) ;;
        *) exit 0 ;;
      esac
      # Tailscale's own interface coming up says nothing about LAN DNS.
      [ "$iface" = tailscale0 ] && exit 0

      ts=${config.services.tailscale.package}/bin/tailscale
      # Only meaningful once the daemon is up and actually handling DNS.
      "$ts" status --json 2>/dev/null \
        | ${pkgs.gnugrep}/bin/grep -q '"BackendState": *"Running"' || exit 0
      "$ts" debug prefs 2>/dev/null \
        | ${pkgs.gnugrep}/bin/grep -q '"CorpDNS": *true' || exit 0

      # Drops and re-takes the resolvconf record, which forces a DNS
      # SetConfig against the now-current base resolv.conf and picks up the
      # DHCP resolver as the "." upstream.
      "$ts" set --accept-dns=false && "$ts" set --accept-dns=true
      echo "tailscale-dns-resync: re-applied tailscale DNS after $action on $iface"
    '';
  }];
}
