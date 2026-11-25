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

  # Hibernate on lid close, resolved entirely by systemd rather than by
  # kernel parameters.
  #
  # The kernel reads the hibernation image before any filesystem is mounted
  # -- it has to, since mounting would replay the journal over state the
  # image is about to restore -- so it cannot resolve the path "/swapfile".
  # It needs raw coordinates: a block device plus the file's first physical
  # block. The classic fix hardcodes both as `boot.resumeDevice` plus a
  # `resume_offset=` kernel param, but the offset is wherever ext4 happened
  # to allocate the file, so recreating the swapfile (notably: changing the
  # size below, which makes NixOS rebuild it) silently desyncs it and resume
  # degrades to a cold boot with no error -- a wrong offset and no image at
  # all are indistinguishable from one page of non-matching bytes.
  #
  # systemd >= 255 avoids the hardcoding: `systemctl hibernate` FIEMAPs the
  # live file and records device + offset in the EFI variable
  # HibernateLocation, and systemd-hibernate-resume-generator in the initrd
  # reads it back on the next boot, then clears it. The offset is therefore
  # recomputed from the real file every hibernate and cannot go stale.
  # Requires a systemd stage 1 (the default here) and writable efivars; the
  # generator and systemd-hibernate-resume.service are in the initrd
  # unconditionally, independent of boot.resumeDevice.
  #
  # Nothing is pinned here on purpose -- `boot.resumeDevice` would only
  # re-add the brittle half.
  #
  # Verified 2026-11-07 on this host, not assumed: with /proc/cmdline
  # carrying neither resume= nor resume_offset=, `systemctl hibernate`
  # powered off and resumed into the live session -- 46s of wall clock
  # across a ~3s monotonic gap, which only a real power-off produces, and
  # the journal shows efivarfs dropping HibernateLocation on wake. Note
  # systemd-hibernate-resume.service logs nothing in the resumed journal:
  # it runs in the resume kernel's initrd, which is discarded when it jumps
  # into the restored image. Absence there is not evidence of failure.
  #
  # The lid-close path itself (not just `systemctl hibernate`) confirmed in
  # flight the same day: shut, carried, reopened with no measurable battery
  # loss -- which was the whole point over S3.
  swapDevices = [{
    device = "/swapfile";
    size = 8 * 1024; # MiB -- covers 7.7G of RAM with headroom
  }];

  # Plain hibernate rather than suspend-then-hibernate: with a battery this
  # tired the point is to not drain at all while the lid is shut, and S3 on
  # this box still costs a few percent an hour. Switch to
  # "suspend-then-hibernate" if waking from a short close is too slow.
  services.logind.lidSwitch = "hibernate";

  # Kindle Scribe over MTP, for calibre.
  #
  # Calibre's MTP driver is libmtp, which talks to the raw USB device
  # through libusb -- it does not go through gvfs or a filesystem mount, so
  # it needs write access to /dev/bus/usb/<bus>/<dev> itself. Those nodes
  # default to root:root 0664, so libusb_open() returns EACCES and calibre
  # reports `Unable to open MTP device`. Observed 2026-11-15: node
  # /dev/bus/usb/001/016 for 1949:9981 was crw-rw-r-- root root.
  #
  # Nothing on this host ships libmtp's own rules -- its 69-libmtp.rules
  # only reaches udev's search path via services.udev.packages -- and the
  # Scribe is recent enough that being listed there is not something to
  # rely on. One explicit rule for the device actually in hand is the
  # smaller thing to carry.
  #
  # GROUP/MODE rather than TAG+="uaccess": extraRules are written to
  # 99-local.rules, which runs after systemd's 73-seat-late.rules where the
  # uaccess builtin is invoked, so the tag would be set too late to do
  # anything. GROUP and MODE are assignments collected across all rules and
  # applied when the node is created, so ordering does not matter for them.
  # dlangevi's primary group here is "users".
  services.udev.extraRules = ''
    SUBSYSTEM=="usb", ATTR{idVendor}=="1949", ATTR{idProduct}=="9981", GROUP="users", MODE="0660"
  '';
}
