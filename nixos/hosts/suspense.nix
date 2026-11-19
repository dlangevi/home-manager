{ config, pkgs, lib, pkgs-unstable, ... }:

{
  imports = [
    ../modules/dance-storage.nix
    ../modules/stable-diffusion.nix
  ];

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

  # Arm the NIC to keep listening in S5. The board half is a BIOS setting
  # (Advanced -> ACPI Configuration: "PCIE Devices Power On" enabled, "Deep
  # Sleep" disabled); this is the adapter half, which the r8169 driver
  # otherwise leaves off. The default policy is already [ "magic" ].
  #
  # Getting the packet here from off-LAN is a third thing again -- see
  # ../modules/wol-relay.nix on dance.
  networking.interfaces.enp5s0.wakeOnLan.enable = true;

  services.sunshine = {
    enable = true;
    autoStart = true;
    openFirewall = true;

    # Pinned to nixpkgs-unstable rather than the nixos-26.05 pin (2026.516 vs
    # 2026.914 as of this writing) -- Sunshine ships stable releases far more
    # often than this channel branches, so the channel pin runs stale for
    # months at a time otherwise.
    #
    # Needs libcuda.so.1 (at the driver's `/run/opengl-driver/lib`, outside
    # the Nix store) for NVENC, which it dlopens at runtime rather than
    # linking -- so nixpkgs' normal dependency-closure RPATH never includes
    # it, and without this override NVENC silently falls back to Vulkan
    # Video encode (visible strobing artifacts on this NVIDIA/KWin combo).
    # Confirmed live 2026-11-09 via `journalctl --user -u sunshine`:
    # "Attempting to use NVENC without CUDA support" -> "[CUDA] Cannot load
    # libcuda.so.1" -> "Failed to create a CUDA device: Operation not
    # permitted".
    #
    # `autoAddDriverRunpath` is nixpkgs' own hook for exactly this case
    # (dlopen'd driver libs); the package already uses it when built with
    # `cudaSupport`, just not in the nixpkgs binary cache's default build.
    # A hand-rolled `patchelf --add-rpath` in `postFixup` does NOT work here:
    # `autoPatchelfHook` (already in this package's nativeBuildInputs) runs
    # after `postFixup` and recomputes the RPATH from the binary's actual
    # linked (DT_NEEDED) dependencies, silently dropping any manual addition
    # for a dlopen'd lib it doesn't know about -- confirmed via `patchelf
    # --print-rpath` on an overridden build. `autoAddDriverRunpath` is built
    # to survive that pass; a manual patchelf call is not.
    package = pkgs-unstable.sunshine.overrideAttrs (old: {
      nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs-unstable.autoAddDriverRunpath ];
    });

    # Back to false (2026-11-11): the Wayland cutover below was reverted --
    # XWayland games under Plasma Wayland hit a known, widely-reported
    # NVIDIA/KWin flicker/tearing-artifact class (short horizontal white
    # lines; see docs/superpowers/specs/2026-11-09-wayland-sunshine-capture-
    # design.md for the attempt and its findings) that outweighed the
    # original X11 capture-race problem this migration was trying to fix.
    # true was only ever needed for Wayland's KMS/portal capture backend; it
    # buys nothing under X11 capture, and false keeps the simpler wrapper-
    # free unit. The CUDA/AT_SECURE conflict this used to reintroduce is
    # fixed unconditionally via the RPATH override above now, so it is not a
    # reason to leave this true either way.
    capSysAdmin = false;
    settings = {
      # Restrict capture to the 1440p monitor; the second display confuses
      # single-screen Moonlight clients.
      #
      # Connector name, not the numeric index this used to be set to. The
      # numeric index ("5", matching the "(id: 5)" XRandR prints next to
      # DP-4 in `journalctl --user -u sunshine | grep "Detected display"`)
      # builds and starts fine but silently streams DP-0 instead -- Sunshine's
      # logged enumeration order and its actual output_name index lookup are
      # two different code paths that only happen to agree sometimes
      # (upstream: LizardByte/Sunshine#221).
      #
      # The earlier attempt at a connector-name value ("DP-2") failed with
      # "Could not stream display number [23172], there are only [7]
      # displays" -- but that was the wrong name (DP-2 is the old GPU's KMS
      # name, surviving stale into the 2070 SUPER's X11 driver naming, where
      # it's now a disconnected output) on a Sunshine build that predates
      # upstream PR #5423 (closed 2026-07-22), which is what made connector
      # names a real, index-independent alternative to begin with. The
      # running build here (2026.914.233613) postdates that fix.
      #
      # "DP-4" above is the X11 xrandr name for the 1440p panel. Plasma
      # Wayland switches Sunshine's capture backend from X11 to KMS, and KMS
      # enumerates the same physical monitors under different connector
      # names entirely -- confirmed live while briefly testing Wayland as
      # the logged-in session (2026-11-09): with output_name left at "DP-4",
      # Sunshine logged "Couldn't map 'DP-4' to a monitor index. Falling
      # back to first monitor in list", which silently streamed the wrong
      # (1080p) panel instead of erroring. Its own "Start of KMS monitor
      # list" log named the 1440p panel (AUS VG32VQ1B) "DP-3" there.
      #
      # Sunshine picks its capture backend from the session actually logged
      # in, not from this module's defaultSession setting below -- so a
      # manual Wayland login while plasmax11 stays the configured default
      # would still need "DP-3" here, and this conditional would guess wrong
      # for exactly that case. It is only meant to track the common case
      # (whichever session is actually the default), not override it.
      # Re-derive either name after any GPU/cable change via
      # `journalctl --user -u sunshine | grep -A2 "KMS monitor list"` (KMS)
      # or `| grep "Detected display"` (X11) -- the two backends' naming
      # don't relate to each other at all.
      output_name =
        if config.services.displayManager.defaultSession == "plasmax11"
        then "DP-4"
        else "DP-3";

      # `resolutions` and `fps` used to be set here. They are not Sunshine
      # options and never were on this version -- it logs
      #
      #   Warning: Unrecognized configurable option [resolutions]
      #   Warning: Unrecognized configurable option [fps]
      #
      # on every start and ignores them. Resolution and frame rate are
      # negotiated by the Moonlight client, not declared by the host, so
      # there is nothing to replace them with. Removed rather than fixed.

      # Encoder settings below are sized for the RTX 2070 SUPER (TU104,
      # 7th-gen NVENC). They were written for the GTX 1060 that preceded it
      # and never revisited, so they were leaving quality on the table.
      #
      # Pin the encoder instead of letting Sunshine auto-select. Auto-select
      # silently falls back to software x264 if NVENC probing fails -- the
      # stream still works, so the regression is easy to miss for weeks.
      # Failing loudly is better than streaming off the CPU by accident.
      encoder = "nvenc";

      # Measured on this card, hevc_nvenc at 2560x1440, encoding 300 raw
      # frames fed from tmpfs so neither NVDEC nor disk is in the loop
      # (pipeline ceiling with encode disabled: 763 fps):
      #
      #   preset  twopass       spatial_aq   fps
      #   p1      quarter_res   on           212
      #   p4      quarter_res   on           138
      #   p4      full_res      on           137
      #   p5      full_res      on           119   <- misses 120
      #   p7      full_res      on            60
      #
      # p4 is the best preset that still clears 120 fps with margin; p5 does
      # not, and p7 is not close. 120 is the ceiling a Moonlight client asks
      # for on this 1440p panel, so that is the number to beat.
      #
      # Higher presets buy compression at a fixed bitrate, and bitrate is
      # measurably the scarce resource here, not GPU time -- an observed
      # session negotiated only 7.3 Mbps for 1440p ("Streaming bitrate is
      # 7308000"), which is far below what this resolution wants.
      nvenc_preset = 4;

      # full_res measured 137 fps against quarter_res 138 at p4 -- a ~1%
      # throughput cost, so effectively free, and both clear 120.
      #
      # Worth taking despite the thin margin because the second pass is what
      # holds the encoder to the requested bitrate. Overshooting a frame
      # budget shows up as a burst the network drops, and dropped packets in
      # a frame are exactly the corrupt-band artifact seen on this stream.
      # At the low bitrates actually being negotiated that risk is real.
      nvenc_twopass = "full_res";

      # Essentially free on Turing (138 fps with it, 144 without, both over
      # target) and it is the knob that helps most at the lower bitrates a
      # remote tailnet client negotiates.
      nvenc_spatial_aq = true;

      # Deliberately not set:
      #   av1_mode        -- Turing has no AV1 encoder; the default already
      #                      advertises by capability, so forcing it does
      #                      nothing but risk advertising a codec we lack.
      #   hevc_mode       -- default auto already picks up Turing's much
      #                      better HEVC (Pascal lacked HEVC B-frames).
      #   nvenc_split_encode -- needs 2+ NVENC units and 4K+. TU104 has one
      #                      unit, so this is inert on this card.
      #   nvenc_realtime_hags -- Windows-only (HAGS); no effect on Linux.
    };
  };

  # Wolf (games-on-whales): lets the "console" device log into suspense over
  # Moonlight into an isolated game-picker session instead of mirroring this
  # desktop, with per-kid save-game isolation. Wolf ships only as a
  # container image, so Docker is required regardless of what the apps
  # inside it turn out to be; nvidia-container-toolkit gives those
  # containers CDI-based access to the same card Sunshine already drives.
  #
  # Deliberately NOT declared here: Wolf's own config.toml/apps.toml,
  # per-kid profiles, and the Hookshot save-swap scripts. All of that lives
  # under ~/auto/gaming (see PROJECT.md there), which is not a GitHub repo,
  # because it names the kids and the game library. This block only wires
  # up the generic container/GPU infrastructure and the ports.
  virtualisation.docker.enable = true;

  # Requires the nvidia driver, already selected via
  # services.xserver.videoDrivers above.
  hardware.nvidia-container-toolkit.enable = true;

  virtualisation.oci-containers.containers.wolf = {
    image = "ghcr.io/games-on-whales/wolf:stable";
    autoStart = true;
    volumes = [
      # Wolf's state dir (config.toml, apps.toml, per-profile save data).
      # Lives under auto/gaming, not in this repo or in /etc -- see the
      # comment above.
      "/home/dlangevi/auto/gaming/wolf-state:/etc/wolf:rw"
      # Wolf spawns its own per-app Docker containers (Wolf UI, any
      # Docker-runner apps), so it needs to talk to the host's Docker
      # daemon itself -- this is upstream's documented design, not an
      # accidental privilege escalation.
      "/var/run/docker.sock:/var/run/docker.sock:rw"
      "/dev/:/dev/:rw"
      "/run/udev:/run/udev:rw"
    ];
    extraOptions = [
      "--network=host"
      # NVIDIA_VISIBLE_DEVICES/NVIDIA_DRIVER_CAPABILITIES (the nvidia-docker1
      # mechanism) only take effect if the container runtime itself is
      # swapped to nvidia-container-runtime -- which is what
      # virtualisation.docker.enableNvidia does, but the oci-containers
      # backend here defaulted to podman regardless of
      # virtualisation.docker.enable, and this is on the newer CDI path
      # (hardware.nvidia-container-toolkit.enable) anyway. Request the GPU
      # as a CDI device instead -- confirmed live against the generated
      # spec at /var/run/cdi/nvidia-container-toolkit.json, which names its
      # one GPU device "nvidia.com/gpu=all". Without this, Wolf starts but
      # its GStreamer pipeline logs "Could not open library libcuda.so.1"
      # and has no hardware encode.
      "--device=nvidia.com/gpu=all"
      "--device=/dev/dri/"
      # Virtual controller emulation: uinput for Xbox-style pads, uhid for
      # DualSense. Same two devices Sunshine's gamepad emulation above
      # already relies on.
      "--device=/dev/uinput"
      "--device=/dev/uhid"
      "--device-cgroup-rule=c 13:* rmw"
    ];
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
      47984 # Wolf (GameStream/Moonlight) HTTPS
      47989 # Wolf (GameStream/Moonlight) HTTP
      48010 # Wolf RTSP setup
    ];
    allowedUDPPorts = [
      47999 # Wolf control
      48100 # Wolf video
      48200 # Wolf audio
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
    # No After= on systemd-modules-load: nvidia needs nothing that unit loads.
    # Worth only ~144ms though (start moved 1.094s -> 0.950s), not the ~0.8s
    # first guessed -- that guess assumed a unit could start at ~0.3s, and
    # none can. Every early unit on this box starts within 60ms of the same
    # instant: nvidia-modules at 5771ms monotonic, journald 5774, modules-load
    # 5776, udevd 5832. nvidia-modules is now literally the first unit systemd
    # starts. The ~950ms before that is PID 1's own generator and unit-loading
    # phase, which is the floor.
    #
    # So userspace is now 0.95s systemd init + 3.9s nvidia + 0.03s
    # display-manager, and there is nothing left to reorder. The only
    # remaining lever is making the driver itself initialise faster -- the
    # untested idea is NVreg_EnableGpuFirmware=0 via boot.extraModprobeConfig,
    # since most of nvidia.ko's ~3s is the GSP firmware upload and Turing can
    # run without it.
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

    # Pinned to 620.70.06 (2026-11-13): testing NVIDIA bug 7014466, a Turing
    # shader-compiler SIGILL ("Unsupported: extractelement <8 x i4>") that
    # crashes Cyberpunk 2077 patch 3.0.88 at startup -- see
    # github.com/HansKristian-Work/vkd3d-proton/issues/3405. NVIDIA confirmed
    # a driver-side fix on 2026-11-02; 620.70.06 shipped two days later but
    # inclusion is unconfirmed. nixpkgs here (locked ~2026-05) only packages
    # 595.71.05, so this is built directly via mkDriver rather than from the
    # nixpkgs nvidiaPackages set. Revert to no `package` pin (ride the module
    # default) if this doesn't fix the crash, to avoid carrying a stale
    # out-of-band pin once nixpkgs itself catches up.
    package = config.boot.kernelPackages.nvidiaPackages.mkDriver {
      version = "620.70.06";
      sha256_64bit = "sha256-KRGOOr0IwHVZvMo9nHYjjQOUkK8DYqLlvPy+cgSv1LE=";
      openSha256 = lib.fakeHash;
      settingsSha256 = "sha256-CFBRmXFJ9eAf5BRlHMBolahz1Pshr9giI7zcZC29oZ8=";
      persistencedSha256 = lib.fakeHash;
    };
  };

  # Reverted back to plasmax11 (2026-11-11): the Wayland cutover (see
  # docs/superpowers/specs/2026-11-09-wayland-sunshine-capture-design.md and
  # its plan) was briefly completed and tested end to end over a live
  # Moonlight stream -- it fixed the original X11 capture-race problem, but
  # surfaced a worse one in trade: streaming an XWayland game (Steam/Proton)
  # under Plasma Wayland produced short horizontal white-line artifacting, a
  # known and still-unresolved class of NVIDIA/KWin/XWayland bug (reports
  # span NVIDIA driver forums and KDE bugzilla, not specific to this host --
  # see that spec for the links gathered 2026-11-11) rather than anything
  # fixable here. Wayland stays selectable at the SDDM login screen (below)
  # for whenever upstream moves on this, but is no longer the default.
  #
  # This also flips the `output_name` conditional above back to "DP-4" --
  # that conditional keys off this same defaultSession value, which is
  # exactly why it has to move back in lockstep rather than being left at
  # "plasma" while logging into plasmax11 by hand.
  services.displayManager.defaultSession = "plasmax11";
  services.displayManager.sddm.wayland.enable = true;

  # udev hidraw rule (dlangevi is in group "console" historically).
  #
  # uhid carries no ACL by default (crw------- root:root), while uinput gets
  # one via an existing uaccess rule. Sunshine emulates an Xbox One pad over
  # uinput and a DualSense over uhid, so the asymmetry shows up as a DS5-only
  # failure the log reports as a bare permission error:
  #
  #   Gamepad 0 will be DualShock 5 controller (auto-selected by client-reported type)
  #   Unable to create virtual DualShock 5 controller: Permission denied
  #   Gamepad 0 will be Xbox One controller (default)
  #
  # The fallback works, so the only cost is the DualSense touchpad and motion
  # -- which is why this went unnoticed for a week. uaccess rather than a
  # group because the consumer is a user service in the seated session, the
  # same shape the uinput rule already relies on.
  services.udev.extraRules = ''
      KERNEL=="uhid", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uhid"
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
    # docker: lets dlangevi run `docker ps`/`docker logs` on the Wolf
    # container directly, without sudo, for day-to-day debugging.
    extraGroups = [ "networkmanager" "wheel" "console" "cdrom" "docker" ];
    packages = with pkgs; [ kdePackages.kate ];
    # console's admin key (programs.ssh "console" match block on console,
    # ~/.ssh/id_admin there), so console can reach suspense for ad-hoc admin.
    # Same bytes as the console@dance-admin entry in nixos/hosts/dance.nix.
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOW8W08WgSljSKmZKJjkDd8HGQ9a2K+hMjrfr3BCYmtv console@dance-admin"
    ];
  };

  # Run non-Nix binaries
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [ stdenv.cc.cc ];

  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
    localNetworkGameTransfers.openFirewall = true;
    gamescopeSession.enable = true;

    # Steam runs in a buildFHSEnv sandbox, so the Vulkan loader inside it only
    # reliably sees implicit layers from packages listed here. MangoHud in the
    # home-manager profile alone is a silent no-op: the game launches, the
    # layer never loads, no overlay. 64-bit only -- nothing here is a 32-bit
    # title; those would also need extraPackages32.
    extraPackages = with pkgs; [ mangohud ];

    # The module overrides this package with `extraCompatPaths`, so it can
    # actually resolve Proton installs; a protontricks from the home profile
    # cannot, and silently misbehaves inside its bwrap sandbox.
    protontricks.enable = true;

    # Selectable per-game from Steam's compatibility dropdown. Kept here rather
    # than dropped into ~/.steam/root/compatibilitytools.d by hand so the
    # version is pinned by the flake like everything else.
    extraCompatPackages = with pkgs; [ proton-ge-bin ];
  };

  fonts.packages = with pkgs; [
    nerd-fonts.agave
    noto-fonts
    noto-fonts-cjk-sans
  ];

  # Suppress IM modules that break some Qt/GTK apps here
  environment.variables.GTK_IM_MODULE = lib.mkForce "";
  environment.variables.QT_IM_MODULE = lib.mkForce "";

  # Serves the phone chat app in ~/auto/android/chat over the tailnet, and
  # herd's `refresh-task`, which asks this endpoint for session labels and does
  # not error when nothing is listening -- an empty label is the symptom of
  # this being off, not a failed service.
  services.ollama = {
    enable = true;

    # nixpkgs' ollama-cuda is unfree CUDA, so cache.nixos.org never carries
    # it -- llama-cpp compiles locally on every rebuild. The default
    # cudaArches builds nine targets for a one-card machine; sm_75 is the
    # 2070 SUPER and cuts that work by ~9x. Update it if the GPU changes,
    # or ollama dies with "no kernel image is available for execution on
    # the device".
    package = pkgs.ollama-cuda.override { cudaArches = [ "sm_75" ]; };

    # The default binds loopback only, which the phone cannot reach. Exposure
    # is controlled by the firewall rules below, not by binding narrowly:
    # the tailnet address is not known at eval time.
    host = "0.0.0.0";

    # DynamicUser with its own /var/lib/ollama store, so the model has to
    # be declared rather than inherited from whatever sits in ~/.ollama.
    #
    # qwen3.5:9b over the old qwen2.5:3b because ~/auto/research/gpu-llm-upgrade.md
    # benchmarked this card and found it the only model in the 8G class that
    # never spills to CPU -- the 12-14B tier all spill and collapse to 4-10
    # tok/s. Anything herd is configured to ask for must also appear here.
    #
    # The abliterated build is the same 9B at the same ~6.4G, so it is a
    # straight alternative rather than a second thing to fit -- only one is
    # ever resident, and the phone client picks per conversation from
    # /api/tags rather than from this list. Declaring it here is still what
    # makes it survive a rebuild.
    loadModels = [
      "qwen3.5:9b"
      "huihui_ai/qwen3.5-abliterated:9b"
    ];

    environmentVariables = {
      # Measured on this host 2026-10-04, qwen3.5:9b, Plasma resident (577M
      # of VRAM). `ollama ps` for placement, eval_count/eval_duration for
      # rate. Left column is this config; right is the same host before
      # flash attention and the quantized KV cache below:
      #
      #   ctx     with FA + q8_0      plain
      #   4096    47.3  100% GPU      48.5  100% GPU
      #   8192    47.5  100% GPU      34.5  12% CPU
      #   12288   56.0  100% GPU      --
      #   14336   42.1  12% CPU       --
      #   16384   37.4  12% CPU       24.1  19% CPU
      #   32768   24.5  19% CPU       --
      #
      # 12288 is picked as the largest size that stays entirely on the GPU,
      # which also happens to be the fastest configuration measured. Note
      # it beats the old 8192 setting on both axes at once -- more context
      # and more throughput -- so there is no trade being made here.
      #
      # Two corrections to the assumption this file used to encode: 8192 was
      # never spill-free on this card, and spilling costs ~30-50% rather
      # than the ~5x the 12-14B benchmarks show, because those offload
      # 15-19 of 63 layers while this offloads 12-19%.
      #
      # Raising this is a straight trade against throughput, and the step
      # that matters is 12288 -> 14336, where it leaves the GPU. 16384 and
      # 32768 are both usable (37 and 25 tok/s, still above reading speed
      # on the phone client) if a longer window is ever worth more.
      OLLAMA_CONTEXT_LENGTH = "12288";

      # The KV cache is what decides where that boundary sits, so quantize
      # it rather than shrink the context: q8_0 roughly halves cache bytes
      # per token and moved the whole curve a full doubling -- 8192 went
      # from spilling to fully resident, and 12288 became reachable at a
      # rate the old config could not hit at any size.
      #
      # Flash attention is the precondition (llama.cpp will not take a
      # quantized KV cache without it) and is worth something on its own:
      # 4096 is unchanged at ~48 tok/s despite the cache now being quantized,
      # and 12288 is faster than 4096 ever was.
      #
      # q8_0 over q4_0 deliberately, since degraded long-context recall
      # would defeat the purpose. Verified with a needle-in-haystack at
      # 8.4K prompt tokens, needle at 10/50/90% depth: all three recalled
      # exactly. Re-run that check before moving to q4_0.
      #
      # Re-measured 2026-10-04 with ../modules/stable-diffusion.nix running:
      # 24.4 tok/s at 79% GPU for qwen3.5:9b, 22.7 at 77% for the abliterated
      # build. The table above no longer reproduces, and sd-server is only a
      # small part of why -- it holds a 252M CUDA context, which moves
      # placement from 81% to 77-79%. The card was already over budget before
      # it existed, because the desktop's own VRAM use has roughly doubled
      # since that benchmark (577M then, ~900M now) and 12288 was picked as
      # the largest window that *just* fit at the time.
      #
      # Left alone deliberately: 23 tok/s still clears reading speed on the
      # phone client, and the step down to 8192 is the lever if it ever stops
      # doing so.
      OLLAMA_FLASH_ATTENTION = "1";
      OLLAMA_KV_CACHE_TYPE = "q8_0";
    };
  };

  # Deliberately unreachable from the network. ollama (11434) and sd-server
  # (../modules/stable-diffusion.nix, 1234) both have no auth of their own,
  # and were previously opened to the LAN/teleport/tailnet subnets for the
  # phone chat app -- removed as part of a security review (2026-11-18) that
  # flagged unauthenticated internal APIs reachable from a guest-adjacent
  # subnet. Both still bind 0.0.0.0 and run locally; nothing routes to them
  # from off-box any more. Re-add scoped `networking.firewall.extraCommands`
  # rules here (see git history) if remote access to either is wanted again,
  # ideally with auth in front of it this time.

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

      # Wait for the daemon rather than giving up on it. Bailing out here is
      # what re-broke boot DNS once nvidia stopped serialising early boot:
      # NetworkManager now reaches its up / dhcp4-change events ~5s before
      # tailscaled leaves Starting, so the old `|| exit 0` skipped the resync
      # on every boot event and DNS stayed dead until an unrelated DHCP renew
      # tripped it ~57s later.
      #
      # Only wait while tailscaled.service is actually active -- if it is
      # stopped or masked on purpose, give up immediately rather than making
      # every NM event pay the timeout. 20s covers the observed ~5s gap with
      # room to spare.
      for _ in $(${pkgs.coreutils}/bin/seq 40); do
        ${pkgs.systemd}/bin/systemctl is-active --quiet tailscaled.service || exit 0
        "$ts" status --json 2>/dev/null \
          | ${pkgs.gnugrep}/bin/grep -q '"BackendState": *"Running"' && break
        ${pkgs.coreutils}/bin/sleep 0.5
      done
      # Still not Running after the wait -- nothing useful to re-apply.
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
