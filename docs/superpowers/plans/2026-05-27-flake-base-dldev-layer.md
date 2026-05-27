# Flake-based home-manager with optional dldev layer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the broken channels/dual-config setup with one flake in `~/.config/home-manager` exposing `#base` and `#dev` profiles, where `#dev` layers in dldev's `claude-session` binary via a home module dldev exports.

**Architecture:** `~/auto/dldev` gains a `homeModules.default` output that adds its prebuilt `claude-session` binary to `home.packages`. The dotfiles flake takes dldev as an optional input and composes two `homeConfigurations`: `base` (existing modules only) and `dev` (base + dldev module). Inputs pin nixpkgs `nixos-25.11` and home-manager `release-25.11`.

**Tech Stack:** Nix flakes, home-manager (standalone), existing `home.nix` + `modules/`.

**Verification model:** No unit-test framework. Verification = `nix flake check`, `home-manager switch --flake`, and PATH smoke checks.

---

### Task 1: Export `homeModules.default` from the dldev flake

**Files:**
- Modify: `/home/dlangevi/auto/dldev/flake.nix`

- [ ] **Step 1: Add `self` to the outputs arguments**

In `outputs = { nixpkgs, home-manager, ... }:` add `self`:

```nix
  outputs = { self, nixpkgs, home-manager, ... }:
```

- [ ] **Step 2: Add the `homeModules.default` output**

Inside the returned attribute set (the `{ ... }` block that currently holds
`packages`, `homeConfigurations`, `devShells`), add:

```nix
      homeModules.default = { pkgs, ... }: {
        home.packages = [
          self.packages.${pkgs.stdenv.hostPlatform.system}.claude-session
        ];
      };
```

- [ ] **Step 3: Verify the flake evaluates and exposes the module**

Run: `nix flake show ~/auto/dldev 2>&1 | grep -A2 homeModules`
Expected: a `homeModules` entry with `default` listed.

- [ ] **Step 4: Commit (in the dldev repo)**

```bash
git -C ~/auto/dldev add flake.nix
git -C ~/auto/dldev commit -m "feat: export homeModules.default for claude-session binary

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Write the dotfiles `flake.nix`

**Files:**
- Create: `/home/dlangevi/.config/home-manager/flake.nix`

- [ ] **Step 1: Create `flake.nix`**

```nix
{
  description = "dlangevi home-manager config";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    dldev = {
      url = "path:/home/dlangevi/auto/dldev";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, home-manager, dldev, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      mkHome = modules: home-manager.lib.homeManagerConfiguration {
        inherit pkgs modules;
      };
    in
    {
      homeConfigurations = {
        base = mkHome [ ./home.nix ];
        dev  = mkHome [ ./home.nix dldev.homeModules.default ];
      };
    };
}
```

- [ ] **Step 2: Generate `flake.lock` and confirm it resolves**

Run: `cd ~/.config/home-manager && nix flake lock`
Expected: creates `flake.lock` with no errors.

- [ ] **Step 3: Verify the pins are stable 25.11 / release-25.11**

Run: `cd ~/.config/home-manager && nix flake metadata --json | nix run nixpkgs#jq -- -r '.locks.nodes.nixpkgs.locked.ref, .locks.nodes.home-manager.locked.ref'`
Expected: `nixos-25.11` then `release-25.11` (ref may appear under `.locked.ref`; if empty, inspect `nix flake metadata` output and confirm nixpkgs rev is a 25.11 commit).

---

### Task 3: Verify both configurations evaluate and build

**Files:** none (verification only)

- [ ] **Step 1: Run `nix flake check`**

Run: `cd ~/.config/home-manager && nix flake check 2>&1 | tail -20`
Expected: no errors. (If `claude-session` fails to build with a `cargoHash`
mismatch under nixpkgs 25.11, update `cargoHash` in `~/auto/dldev/flake.nix` to the
hash Nix reports, re-commit Task 1's file, then re-run.)

- [ ] **Step 2: Build `#base` without activating**

Run: `cd ~/.config/home-manager && nix build .#homeConfigurations.base.activationPackage --no-link 2>&1 | tail -5; echo EXIT=$?`
Expected: EXIT=0.

- [ ] **Step 3: Build `#dev` without activating**

Run: `cd ~/.config/home-manager && nix build .#homeConfigurations.dev.activationPackage --no-link 2>&1 | tail -5; echo EXIT=$?`
Expected: EXIT=0.

---

### Task 4: Activate `#dev` and smoke-test the layering

**Files:** none (activation + verification)

- [ ] **Step 1: Switch to `#dev`**

Run: `home-manager switch -b backup --flake ~/.config/home-manager#dev 2>&1 | tail -10`
Expected: "Activating ..." completes with no error.

- [ ] **Step 2: Verify base tools and the dldev binary are present**

Run: `for b in nvim tmux git rg fd claude-session; do printf '%s -> ' "$b"; command -v "$b" || echo MISSING; done`
Expected: all resolve to nix store paths; `claude-session` present.

- [ ] **Step 3: Verify `#base` excludes the dldev binary (build-time profile check)**

Run: `nix build ~/.config/home-manager#homeConfigurations.base.activationPackage --no-link --print-out-paths | xargs -I{} sh -c 'ls {}/home-path/bin/claude-session 2>/dev/null && echo PRESENT || echo "absent (correct)"'`
Expected: `absent (correct)`.

- [ ] **Step 4: Verify the dldev devShell still provides the Rust toolchain**

Run: `nix develop ~/auto/dldev --command sh -c 'cargo --version && rustc --version'`
Expected: prints cargo and rustc versions.

---

### Task 5: Commit the dotfiles flake

**Files:**
- Add: `flake.nix`, `flake.lock`

- [ ] **Step 1: Commit (leave the unrelated `modules/neovim.nix` change unstaged)**

```bash
cd ~/.config/home-manager
git add flake.nix flake.lock
git commit -m "feat: add flake with #base and #dev profiles

#dev layers dldev's claude-session via its exported home module.
Pins nixpkgs nixos-25.11 and home-manager release-25.11.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Update README to the flake workflow

**Files:**
- Modify: `/home/dlangevi/.config/home-manager/README.md`

- [ ] **Step 1: Replace the channel-based "Apply" and "Updating" guidance**

In `README.md`, change the apply command from `home-manager switch -b backup` to:

```bash
home-manager switch -b backup --flake ~/.config/home-manager#dev   # base + dldev tooling
# or, base configs only:
home-manager switch -b backup --flake ~/.config/home-manager#base
```

And in "Updating", replace `nix-channel --update && home-manager switch` with:

```bash
nix flake update           # bump pinned inputs
home-manager switch --flake ~/.config/home-manager#dev
```

Add one line under "Structure" noting `flake.nix` is the entry point exposing
`#base` and `#dev`, and that `#dev` pulls in dldev's `claude-session` binary.

- [ ] **Step 2: Commit**

```bash
cd ~/.config/home-manager
git add README.md
git commit -m "docs: switch README to flake-based workflow

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- dldev exports home module → Task 1.
- dotfiles flake, inputs, mkHome, base/dev outputs → Task 2.
- 25.11 / release-25.11 pins → Task 2 Step 3.
- `nix flake check` passes (success criterion 1) → Task 3 Step 1.
- `#base` excludes / `#dev` includes claude-session (criteria 2, 3) → Task 4 Steps 2-3.
- base tools present in both (criterion 3) → Task 4 Step 2 + Task 3 base build.
- lockfile pins (criterion 4) → Task 2 Step 3.
- devShell toolchain intact (criterion 5) → Task 4 Step 4.
- Out-of-scope items (stale dldev `home/`, crate move, alias, neovim.nix) correctly not tasked; README was stale and is fixed in Task 6.

**Placeholder scan:** none — every step has concrete commands/code. The cargoHash note in Task 3 Step 1 is a conditional remediation, not a placeholder.

**Type consistency:** `homeModules.default` (Task 1) is referenced as `dldev.homeModules.default` (Task 2). `mkHome` takes a module list in both outputs. Profile names `base`/`dev` consistent across Tasks 2-6.
