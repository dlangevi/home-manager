{ config, pkgs, pkgs-ollama, lib, ... }:

let
  # GTX 1060 is Pascal (sm_61); nixpkgs default cudaArches starts at sm_75, so
  # the cached binary panics with "no kernel image is available for execution
  # on the device". Force a local rebuild that includes Pascal.
  ollama-cuda = pkgs-ollama.ollama.override {
    acceleration = "cuda";
    cudaArches = [ "sm_61" ] ++ pkgs-ollama.cudaPackages.flags.realArches;
  };
in
{
  networking.hostName = "suspense";
  system.stateVersion = "23.11";

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

  # agent-session's `refresh-task` asks this endpoint for session labels; when
  # nothing is listening the label silently stays empty, so the server has to be
  # a managed service rather than a package someone starts by hand.
  services.ollama = {
    enable = true;
    package = ollama-cuda;
    # The service runs under a DynamicUser with its own /var/lib/ollama store,
    # so the model refresh-task asks for has to be declared rather than
    # inherited from whatever happens to sit in ~/.ollama.
    loadModels = [ "qwen2.5:3b" ];
  };

  environment.systemPackages = with pkgs; [
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
