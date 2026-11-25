{ config, pkgs, lib, ... }:

{
  networking.hostName = "chonk";
  system.stateVersion = "26.05";

  # Remote access, and how syncthing.nix's peers (suspense, dance) are
  # actually reachable -- their addresses are tailnet (MagicDNS) names.
  services.tailscale = {
    enable = true;
    # Without this the daemon cannot accept inbound UDP on 41641, so peers
    # fall back to DERP relays -- which works, but adds latency.
    openFirewall = true;
  };

  # Fast and low-overhead over user-friendly: this is the underpowered
  # laptop, same call as blur.nix (no compositor eye candy, no DE daemons
  # idling in the background) -- and not optional here the way it reads:
  # this host file never had a desktop manager at all (dlsys init's minimal
  # scrape only pulled stateVersion + users.* from the installer), so with
  # no changes at all the next reboot would land on SDDM with no session to
  # offer. This is what that reboot needs to find.
  programs.sway.enable = true;
  # swaybar decodes tray icons through gdk-pixbuf, which only handles SVG when
  # librsvg's loader is on GDK_PIXBUF_MODULE_FILE. Modern icon themes ship
  # SVG only, so without this every tray item renders as swaybar's red
  # frowning-face placeholder. The gtk wrapper is what sets that variable.
  programs.sway.wrapperFeatures.gtk = true;
  services.displayManager.defaultSession = "sway";

  # Power management: underpowered laptop, battery present (BAT0).
  #
  # TLP and power-profiles-daemon both want to own CPU/USB/PCIe power
  # states -- running both fights over the same knobs. Neither was actually
  # enabled here before this, so this is a straight improvement rather than
  # a swap.
  services.power-profiles-daemon.enable = false;
  services.tlp.enable = true;

  # Intel-specific: backs off clocks proactively to avoid thermal
  # throttling, which otherwise forces sustained high power draw while the
  # CPU oscillates around its thermal limit.
  services.thermald.enable = true;

  # Periodic trim instead of mount-time `discard` -- continuous discard has
  # its own write-amplification/power cost; weekly batched trim is cheaper.
  services.fstrim.enable = true;

  # Hibernate on lid close. Unlike blur (zero swap partition, hence its
  # zramSwap + swapfile-for-hibernate dance), chonk already has a real swap
  # *partition* (nixos/hardware/chonk.nix) -- a partition's device+offset
  # doesn't shift the way a file's can, so systemd's own HibernateLocation
  # resume mechanism just uses it as-is, no extra swap config needed here.
  services.logind.lidSwitch = "hibernate";

  users.users."david" = {
    isNormalUser = true;
    shell = pkgs.zsh;
    description = "david";
    extraGroups = [ "networkmanager" "wheel" ];
    packages = with pkgs; [
      kdePackages.kate
    #  thunderbird
    ];
  };
}
