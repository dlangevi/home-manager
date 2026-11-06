{ pkgs, ... }:

{
  networking.hostName = "blur";
  system.stateVersion = "25.05";

  users.users.dlangevi = {
    isNormalUser = true;
    shell = pkgs.zsh;
    description = "david";
    extraGroups = [ "networkmanager" "wheel" ];
    packages = with pkgs; [ kdePackages.kate ];
  };

  # Remote access.
  services.tailscale = {
    enable = true;
    # Without this the daemon cannot accept inbound UDP on 41641, so peers
    # fall back to DERP relays -- which works, but adds latency.
    openFirewall = true;
  };

  # Fast and low-overhead over user-friendly: this is the underpowered
  # laptop, so it gets Sway instead of Plasma -- no compositor eye candy, no
  # DE daemons idling in the background, keyboard-driven to begin with.
  # Losing on purpose: an integrated battery/network applet, screen locker,
  # and notification daemon -- those become separate small pieces (waybar,
  # mako, swaylock/swayidle) to wire up later, not included yet.
  programs.sway.enable = true;
  # swaybar decodes tray icons through gdk-pixbuf, which only handles SVG when
  # librsvg's loader is on GDK_PIXBUF_MODULE_FILE. Modern icon themes ship
  # SVG only, so without this every tray item renders as swaybar's red
  # frowning-face placeholder. The gtk wrapper is what sets that variable.
  programs.sway.wrapperFeatures.gtk = true;
  services.displayManager.defaultSession = "sway";

  # Power management: underpowered laptop, tired battery.
  #
  # TLP and power-profiles-daemon both want to own CPU/USB/PCIe power
  # states -- running both fights over the same knobs, so the Plasma-pulled-in
  # power-profiles-daemon has to go. TLP's stock battery-tuned defaults
  # (powersave governor, USB autosuspend, WiFi power saving, PCIe ASPM) are
  # not overridden here; revisit with `tlp-stat` if a specific device turns
  # out to need an exception.
  services.power-profiles-daemon.enable = false;
  services.tlp.enable = true;

  # Intel-specific: backs off clocks proactively to avoid thermal
  # throttling, which otherwise forces sustained high power draw while the
  # CPU oscillates around its thermal limit.
  services.thermald.enable = true;

  # Periodic trim instead of mount-time `discard` -- continuous discard has
  # its own write-amplification/power cost; weekly batched trim is cheaper.
  services.fstrim.enable = true;

  # This machine has zero swap (nixos/hardware/blur.nix: swapDevices = [ ]),
  # so a RAM spike has nowhere to go but the OOM killer -- confirmed
  # 2026-11-05 when a `nix build` run from wezterm got killed outright under
  # memory pressure. zram gives the kernel compressed in-RAM swap to reclaim
  # into first: no disk I/O, cheap zstd CPU cost, no SSD wear or battery hit
  # -- unlike a disk-backed swapfile, which would also work here but isn't
  # free the way this is.
  zramSwap = {
    enable = true;
    memoryPercent = 50; # ~4G compressed swap on this 7.7G box
  };

  # NOTE: lid-close still only suspends, not suspend-then-hibernate. This
  # machine has no swap (nixos/hardware/blur.nix: swapDevices = [ ]), and
  # hibernate needs a swapfile plus a resume_offset that can only be
  # computed after that file exists on disk -- a two-step, host-specific
  # setup rather than a pure Nix change. Worth doing as a deliberate
  # follow-up if plain suspend doesn't hold battery well enough overnight.
}
