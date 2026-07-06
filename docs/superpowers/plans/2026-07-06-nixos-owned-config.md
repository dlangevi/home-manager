# NixOS-owned config migration

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the three machines' `/etc/nixos/configuration.nix` files into this flake as `nixosConfigurations`, with one shared `common.nix` and thin per-host modules.

**Architecture:** New `nixos/` tree with `common.nix` (~80% shared) and `hosts/{console,dance,suspense}.nix` (per-host slices). `flake.nix` adds `nixosConfigurations.<host> = lib.nixosSystem { modules = [ ./nixos/common.nix ./nixos/hosts/<host>.nix /etc/nixos/hardware-configuration.nix ]; }`. `bootstrap upgrade` becomes `sudo nixos-rebuild switch --flake .#$host` followed by `home-manager switch --flake .#$host`, gated by presence of `/etc/nixos/configuration.nix`.

**Tech Stack:** Nix flakes, NixOS modules, home-manager (standalone), bash.

## Global constraints

- Do not commit `hardware-configuration.nix`; reference `/etc/nixos/hardware-configuration.nix` at eval time via `--impure`.
- Preserve current per-host semantics exactly (usernames, autoLogin state, SDDM wayland state, firewall ports, systemd units, package sets). This is a migration, not a re-design.
- Fix three pieces of drift while migrating: (a) `hardware.pulseaudio.enable` → `services.pulseaudio.enable` (rename); (b) add `nix.settings.experimental-features = ["nix-command" "flakes"]` uniformly in `common.nix`; (c) enable `programs.zsh` uniformly in `common.nix` so the login shell works on dance too.
- `nix.gc` block currently lives in `modules/base.nix` (home-manager) AND in console's configuration.nix. Move to `nixos/common.nix` only; remove from `modules/base.nix`.
- Sourcing note: exact bytes for `common.nix` and each host file come from `~/Sync/keepassxc/{console,dance,suspense}-configuration.nix` — quote them verbatim, don't paraphrase.
- Do not add SSH/avahi/authorized_keys wiring in this PR. SSH-between-machines is a follow-up.

## File Structure

```
nixos/
  common.nix              # shared 80% (boot, network, locale, plasma6, pipewire, steam, firefox, nix settings, zsh, openssh, printing)
  hosts/
    console.nix           # user=console, autoLogin, extended BT, Ryzen CPU cap, dev toolchain, protontricks/proton-ge
    dance.nix             # user=dance, autoLogin
    suspense.nix          # user=dlangevi, no autoLogin, plasmax11, firewall, nix-ld, gamescope, ollama-cuda, fonts
flake.nix                 # add nixosConfigurations output
bootstrap                 # do_upgrade: run nixos-rebuild first if /etc/nixos exists
modules/base.nix          # remove nix.gc (moves to nixos/common.nix)
CLAUDE.md                 # document the new nixos/ tree and the split rule remains valid
```

---

### Task 1: Scaffold `nixos/common.nix` and wire into `flake.nix`

**Files:**
- Create: `nixos/common.nix`
- Modify: `flake.nix` (add `nixosConfigurations` output)
- Modify: `modules/base.nix` (remove the `nix.gc` block)

**Interfaces:**
- Produces: `nixosConfigurations.<host>` for host ∈ {console, dance, suspense}. Each is built by `lib.nixosSystem` with `modules = [ ./nixos/common.nix ./nixos/hosts/<host>.nix /etc/nixos/hardware-configuration.nix ]` and `specialArgs = { inherit username; }` where `username` is derived from `machines.nix` in a follow-up — for now hardcode per-host in `hosts/*.nix`.

- [ ] **Step 1: Write `nixos/common.nix`**

```nix
{ config, pkgs, ... }:

{
  # Boot
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

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

  # Printing + SSH
  services.printing.enable = true;
  services.openssh.enable = true;

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
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
    dedicatedServer.openFirewall = true;
    localNetworkGameTransfers.openFirewall = true;
  };

  environment.systemPackages = with pkgs; [
    vim
    libgcc
  ];
}
```

- [ ] **Step 2: Remove `nix.gc` from `modules/base.nix`**

Edit `modules/base.nix` and delete lines 41-45 (the `nix.gc = { ... };` block). Home-manager on non-NixOS machines still gets its own GC via NixOS defaults if applicable; on NixOS the system-level nix.gc from `common.nix` covers it.

- [ ] **Step 3: Add stub host files so flake evaluates**

```bash
mkdir -p nixos/hosts
```

Write minimal stubs so `flake check` succeeds — they'll be filled in later tasks:

`nixos/hosts/console.nix`:
```nix
{ ... }: { networking.hostName = "console"; system.stateVersion = "23.11"; }
```

`nixos/hosts/dance.nix`:
```nix
{ ... }: { networking.hostName = "dance"; system.stateVersion = "24.11"; }
```

`nixos/hosts/suspense.nix`:
```nix
{ ... }: { networking.hostName = "suspense"; system.stateVersion = "23.11"; }
```

- [ ] **Step 4: Wire `nixosConfigurations` into `flake.nix`**

In the `outputs` `let` block, add after `machines = import ./machines.nix;`:

```nix
      mkNixos = host: nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./nixos/common.nix
          ./nixos/hosts/${host}.nix
          /etc/nixos/hardware-configuration.nix
        ];
      };
```

And in the returned attrset, add alongside `homeConfigurations`:

```nix
      nixosConfigurations =
        builtins.mapAttrs (host: _: mkNixos host) machines;
```

- [ ] **Step 5: Verify eval for the current host (suspense)**

Run:
```
nix eval --impure ".#nixosConfigurations.suspense.config.system.stateVersion"
```
Expected: `"23.11"`

This confirms the modules load, the hardware-configuration path resolves, and the merge succeeds. It does NOT prove console/dance would boot — those are validated on-machine in a later manual step.

- [ ] **Step 6: Commit**

```bash
git add nixos/common.nix nixos/hosts/console.nix nixos/hosts/dance.nix nixos/hosts/suspense.nix flake.nix modules/base.nix
git commit -m "feat(nixos): scaffold common.nix and nixosConfigurations wiring"
```

---

### Task 2: Fill in `nixos/hosts/console.nix`

**Files:**
- Modify: `nixos/hosts/console.nix`

**Source:** `~/Sync/keepassxc/console-configuration.nix`. Copy verbatim except for the parts that now live in `common.nix`.

- [ ] **Step 1: Write the full console host module**

Overwrite `nixos/hosts/console.nix` with:

```nix
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

  # Display manager
  services.xserver.displayManager.sddm.enable = true;
  services.xserver.displayManager.defaultSession = "plasma";
  services.xserver.displayManager.sddm.wayland.enable = true;

  # Auto-login as console
  services.xserver.displayManager.autoLogin.enable = true;
  services.xserver.displayManager.autoLogin.user = "console";

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

  # Steam extras
  programs.steam.protontricks.enable = true;
  programs.steam.extraCompatPackages = [ pkgs.proton-ge-bin ];

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

  environment.systemPackages = with pkgs; [
    cmake
    gnumake
    nodejs_22
    python3
    gparted
    noto-fonts-cjk-sans
    config.boot.kernelPackages.cpupower
  ];
}
```

- [ ] **Step 2: Verify eval**

Run:
```
nix eval --impure ".#nixosConfigurations.console.config.networking.hostName"
```
Expected: `"console"`

- [ ] **Step 3: Commit**

```bash
git add nixos/hosts/console.nix
git commit -m "feat(nixos): migrate console configuration into flake"
```

---

### Task 3: Fill in `nixos/hosts/dance.nix`

**Files:**
- Modify: `nixos/hosts/dance.nix`

**Source:** `~/Sync/keepassxc/dance-configuration.nix`.

- [ ] **Step 1: Write the full dance host module**

Overwrite `nixos/hosts/dance.nix`:

```nix
{ pkgs, ... }:

{
  networking.hostName = "dance";
  system.stateVersion = "24.11";

  services.xserver.displayManager.sddm.enable = true;
  services.xserver.displayManager.defaultSession = "plasma";
  services.xserver.displayManager.sddm.wayland.enable = true;

  services.xserver.displayManager.autoLogin.enable = true;
  services.xserver.displayManager.autoLogin.user = "dance";

  services.udev.extraRules = ''
      SUBSYSTEMS=="hidraw", ACTION=="add", MODE="0660", GROUP="dance"
  '';

  users.groups.dance = { };
  users.users.dance = {
    isNormalUser = true;
    shell = pkgs.zsh;
    description = "dance";
    extraGroups = [ "networkmanager" "wheel" "dance" ];
    packages = [ ];
  };

  environment.systemPackages = with pkgs; [ unzip ];
}
```

Note: added `shell = pkgs.zsh` (was missing on dance in the original — drift fix consistent with `programs.zsh.enable` in common).

- [ ] **Step 2: Verify eval**

Run:
```
nix eval --impure ".#nixosConfigurations.dance.config.networking.hostName"
```
Expected: `"dance"`

- [ ] **Step 3: Commit**

```bash
git add nixos/hosts/dance.nix
git commit -m "feat(nixos): migrate dance configuration into flake"
```

---

### Task 4: Fill in `nixos/hosts/suspense.nix`

**Files:**
- Modify: `nixos/hosts/suspense.nix`

**Source:** `~/Sync/keepassxc/suspense-configuration.nix`.

- [ ] **Step 1: Write the full suspense host module**

Overwrite `nixos/hosts/suspense.nix`:

```nix
{ config, pkgs, lib, ... }:

{
  networking.hostName = "suspense";
  system.stateVersion = "23.11";

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

  # NVIDIA on Wayland is flaky — stay on X11 by default
  services.displayManager.defaultSession = "plasmax11";
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = false;
  };
  services.displayManager.autoLogin.enable = false;

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

  # Gaming
  programs.steam.gamescopeSession = {
    enable = true;
    args = [ ];
    steamArgs = [ ];
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
    (pkgs.ollama.override { acceleration = "cuda"; })
    steam-run
    steam
    kdePackages.partitionmanager
    gparted
  ];
}
```

- [ ] **Step 2: Verify eval AND build (this is the current machine)**

Run:
```
nix eval --impure ".#nixosConfigurations.suspense.config.networking.hostName"
```
Expected: `"suspense"`

Then:
```
sudo nixos-rebuild build --flake .#suspense --impure
```
Expected: builds `result` symlink without errors.

- [ ] **Step 3: Compare `result` derivation against currently-running system**

Run:
```
nix store diff-closures /run/current-system ./result | head -50
```
Expected: differences should be limited to added GC/nix-settings from `common.nix` and the drift-fix items. No large unexplained removals of packages or services.

If anything major is missing (e.g., NVIDIA driver, audio, filesystems), STOP and investigate — likely we lost something from `configuration.nix` that wasn't captured.

- [ ] **Step 4: Commit**

```bash
git add nixos/hosts/suspense.nix
git commit -m "feat(nixos): migrate suspense configuration into flake"
```

---

### Task 5: Update `bootstrap upgrade` to run `nixos-rebuild` too

**Files:**
- Modify: `bootstrap` (`do_upgrade` function)

- [ ] **Step 1: Replace `do_upgrade` to run nixos-rebuild first when on NixOS**

Edit `bootstrap`. Replace the current `do_upgrade` body:

```bash
do_upgrade() {
  local do_update=0
  if [[ $# -ge 1 ]]; then
    if [[ "$1" == "--update" ]]; then
      do_update=1
    else
      usage >&2
      exit 2
    fi
  fi
  require_nix
  require_flake_root
  local host
  host=$(get_hostname)
  if ! machine_registered "$host"; then
    echo "$host is not registered. Run './bootstrap init' first." >&2
    exit 1
  fi
  if [[ $do_update -eq 1 ]]; then
    nix flake update
  fi

  # NixOS layer first (only on NixOS hosts — WSL/macOS have no /etc/nixos)
  if [[ -f /etc/nixos/configuration.nix ]] || [[ -e /run/current-system/nixos-version ]]; then
    echo "==> nixos-rebuild switch --flake .#$host"
    sudo nixos-rebuild switch --flake ".#$host" --impure
  fi

  echo "==> home-manager switch --flake .#$host"
  hm switch --impure --flake ".#$host"
}
```

Update the usage help text:

```
  ./bootstrap upgrade             nixos-rebuild + home-manager switch for this machine
```

- [ ] **Step 2: Dry-run the flow (do NOT actually switch)**

Run:
```
./bootstrap upgrade 2>&1 | head -3
```
Should print the `==> nixos-rebuild switch ...` line before actually invoking sudo. Cancel with Ctrl-C at the sudo password prompt if you don't want to switch yet.

- [ ] **Step 3: Commit**

```bash
git add bootstrap
git commit -m "feat(bootstrap): run nixos-rebuild before home-manager on NixOS hosts"
```

---

### Task 6: Update docs

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

- [ ] **Step 1: Update `CLAUDE.md`**

In the "1. NixOS vs home-manager" section, add a note near the top:

```
The flake now owns both NixOS and home-manager layers. NixOS modules live
under `nixos/` (`common.nix` + `hosts/<name>.nix`). Home-manager modules
still live under `modules/`. The split rule below still governs where a
piece of config belongs — only the storage location has changed.
```

In the "Adding a new package — checklist" section, update step 3:

```
3. **Does it need root, a system service, hardware access, or 32-bit
   libs?** If yes, add it to `nixos/common.nix` (if all machines want it)
   or the relevant `nixos/hosts/<name>.nix`. Otherwise it belongs in a
   home-manager feature.
```

- [ ] **Step 2: Update `README.md`**

Add a section describing the new layout (adjacent to the existing "Machine registry" / "Adding a new machine" content — read `README.md` to place it correctly):

```
## NixOS layer

`nixos/common.nix` holds the ~80% of `configuration.nix` shared by all
machines (boot, network, plasma6, pipewire, steam, nix settings, printing,
openssh). Per-host slices live in `nixos/hosts/<name>.nix` — hostname,
user, autologin, firewall, hardware-specific systemd units.

Per-machine `hardware-configuration.nix` stays on the machine at
`/etc/nixos/hardware-configuration.nix` and is imported by path via
`--impure`. It's auto-generated by NixOS and not committed here.

`./bootstrap upgrade` runs `sudo nixos-rebuild switch --flake .#$host`
followed by `home-manager switch --flake .#$host`. On non-NixOS hosts
(WSL, macOS) the nixos-rebuild step is skipped automatically.
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: describe nixos/ tree and updated bootstrap flow"
```

---

### Task 7: Open PR, close #11 with pointer

- [ ] **Step 1: Push branch**

```bash
git push -u origin feat/nixos-owned-config
```

- [ ] **Step 2: Open PR**

```bash
gh pr create --title "feat(nixos): bring configuration.nix into the flake" --body "$(cat <<'EOF'
## Summary
- Migrate `/etc/nixos/configuration.nix` for console, dance, suspense into `nixos/common.nix` + `nixos/hosts/<name>.nix`
- Wire `nixosConfigurations.<host>` into `flake.nix`; `hardware-configuration.nix` stays on-machine
- `bootstrap upgrade` now runs `sudo nixos-rebuild switch` first on NixOS hosts, then `home-manager switch`
- Drift fixes: pulseaudio rename, uniform `programs.zsh.enable`, uniform experimental-features, dedup `nix.gc` (removed from `modules/base.nix`)
- Supersedes #11 — SSH/avahi/authorized_keys become a two-line edit in `common.nix`, no external patch script needed

## Test plan
- [x] `nix eval` succeeds for all three hosts
- [x] `nixos-rebuild build --flake .#suspense --impure` on suspense produces a derivation
- [x] `nix store diff-closures` shows only expected changes vs. current system
- [ ] `sudo nixos-rebuild switch` on suspense — activate and verify desktop + audio + steam still work
- [ ] Same on dance and console after pulling the branch

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Close #11 with a pointer**

```bash
gh pr close 11 --comment "Superseded by #<new-pr-number> — that PR brings configuration.nix into the flake, which makes the check-nixos patch approach unnecessary."
```

Replace `<new-pr-number>` with the URL printed by the `gh pr create` step.

## Self-review

- Spec coverage: shared common.nix ✓, three host files ✓, flake wiring ✓, bootstrap update ✓, drift fixes noted ✓, no SSH work ✓, docs ✓.
- No placeholders in code steps.
- Type consistency: option paths (`services.pulseaudio.enable` vs `hardware.pulseaudio.enable`) reconciled to the new name in one place.
- SSH work is explicitly deferred per user instruction.
