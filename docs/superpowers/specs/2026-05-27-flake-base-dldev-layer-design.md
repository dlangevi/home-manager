# Design: Flake-based home-manager with optional dldev layer

## Problem

Two parallel home-manager configs exist on this machine and have drifted:

- `~/.config/home-manager` — channels-based (`home.nix` + `modules/`). Read by bare
  `home-manager switch`. Currently broken (nixpkgs 24.11 vs home-manager 25.11 skew).
- `~/auto/dldev` — a flake with its own stale `homeConfigurations.suspense` (a
  pre-slim fork still carrying GUI/gaming packages), plus the `agent-session` Rust
  crate and a Rust devShell.

`home-manager switch --flake .#suspense` only ever worked when run from inside
`~/auto/dldev`; it built that flake's config, never the dotfiles config. There is no
committed `flake.nix` in `~/.config/home-manager`.

Goal: one canonical flake-based home config that always provides the base toolset, and
can optionally layer in the dldev tooling — with dldev owning its own bootstrap.

## Decisions

- **dldev stays its own flake/repo.** The dotfiles flake consumes it as an optional input.
- **dldev exports a home-manager module** (Approach A) — it owns what it installs, so
  enabling it is self-bootstrapping and future dldev tools need no dotfiles-repo change.
- **dldev payload is binary-only.** Enabling the layer installs the prebuilt
  `agent-session` binary. The Rust build toolchain (cargo, rustc, clippy, rustfmt,
  pkg-config) stays in dldev's existing `devShells.default`, entered via `nix develop`.
- **Use-based profiles, not per-machine.** Two outputs:
  - `#base` — base unix configs only.
  - `#dev`  — base + dldev binary. Used at work to consume the toolchain; on a machine
    where dldev itself is developed, switch to `#dev` and run `nix develop ~/auto/dldev`.
  - (`#dldev` was considered but is identical to `#dev`, so dropped.)
- **Pin to stable 25.11.** nixpkgs `nixos-25.11`, home-manager `release-25.11`,
  matching the already-updated channels. Flake mode ignores `NIX_PATH`/channels, which
  also resolves the original bare-switch breakage.

## Architecture

### `~/auto/dldev` (tooling flake) — one new output

```nix
homeModules.default = { pkgs, ... }: {
  home.packages = [ self.packages.${pkgs.stdenv.hostPlatform.system}.agent-session ];
};
```

That is the entire dldev payload. `devShells.default` (Rust toolchain) is unchanged.
The stale `home/` tree (`common.nix`, `profiles/*`) is no longer consumed by anything;
it is left in place and flagged as dead code to delete in a later, separate change —
not touched here.

### `~/.config/home-manager` (dotfiles flake) — new `flake.nix` + `flake.lock`

Inputs:

```nix
inputs = {
  nixpkgs.url  = "github:NixOS/nixpkgs/nixos-25.11";
  home-manager = { url = "github:nix-community/home-manager/release-25.11";
                   inputs.nixpkgs.follows = "nixpkgs"; };
  dldev        = { url = "path:/home/dlangevi/auto/dldev";
                   inputs.nixpkgs.follows = "nixpkgs"; };
};
```

The `dldev` input is structured so swapping `path:` for `github:dlangevi/dldev` later is
a one-line change (makes `#dev` fully portable; `#base` never needs dldev present).

Outputs — a small `mkHome` helper wraps `home-manager.lib.homeManagerConfiguration` with
the right `pkgs`/system:

```nix
homeConfigurations = {
  base = mkHome [ ./home.nix ];
  dev  = mkHome [ ./home.nix inputs.dldev.homeModules.default ];
};
```

`home.nix` and `modules/` are unchanged; `home.nix` already imports
`modules/{packages,zsh,tmux,git,neovim}`.

### Deploy

```
home-manager switch --flake ~/.config/home-manager#base   # base machine
home-manager switch --flake ~/.config/home-manager#dev    # base + dldev binary
```

Pinned by `flake.lock`, identical across machines, no channel/`NIX_PATH` involvement.

## Components & boundaries

- `modules/*.nix` — base config units (unchanged). What: declare one tool each. Depends
  on: `pkgs`.
- `home.nix` — base entry point aggregating the modules (unchanged).
- `flake.nix` (dotfiles) — defines inputs, `mkHome`, and the `base`/`dev` outputs. What:
  the single entry point. Depends on: nixpkgs, home-manager, optionally dldev.
- `dldev:homeModules.default` — the dldev payload. What: add `agent-session` to
  `home.packages`. Depends on: dldev's own `packages.<system>.agent-session`.

## Out of scope

- Deleting/refactoring dldev's stale `home/` tree (separate change).
- Moving the `agent-session` crate (it stays in dldev).
- The `home-manager switch` shorthand alias (separate TODO, depends on final attr names).
- Resolving uncommitted `modules/neovim.nix` changes (separate, pre-existing).

## Success criteria

1. `nix flake check ~/.config/home-manager` passes.
2. `home-manager switch --flake ~/.config/home-manager#base` succeeds and `agent-session`
   is NOT on `PATH`.
3. `home-manager switch --flake ~/.config/home-manager#dev` succeeds and `agent-session`
   IS on `PATH`; nvim/tmux/git/cli tools present in both.
4. `flake.lock` pins nixpkgs to 25.11 and home-manager to release-25.11.
5. `nix develop ~/auto/dldev` still provides the Rust toolchain.
