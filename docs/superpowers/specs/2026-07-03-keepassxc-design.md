# KeePassXC + Syncthing integration for home-manager

## Purpose

Add KeePassXC as a declaratively-managed password manager across all home-manager
profiles (base, dev, personal), with the `.kdbx` database file synced between
machines via a self-hosted Syncthing daemon that is also managed by home-manager.

## Non-goals

- Browser integration (KeePassXC-Browser + native messaging). Deferred to a later
  spec.
- SSH agent / secret service integration. The chosen usage model prompts for the
  master password on every CLI call, so no daemon-side caching is needed.
- Auto-injecting secrets from KeePassXC into other Nix modules or dotfiles.
- Mobile (Android/iOS) Syncthing pairing. Handled manually outside Nix.
- Declarative Syncthing device pairing. Device IDs are added imperatively through
  the Syncthing web UI.

## Architecture

Two new modules under `modules/`, both imported unconditionally from `home.nix`
so every profile receives them:

```
modules/
  keepassxc.nix   # installs the KeePassXC package (GUI + CLI)
  syncthing.nix   # enables the Syncthing user daemon and declares the DB folder
```

The two modules are decoupled. `keepassxc.nix` knows nothing about how the
`.kdbx` file arrives on disk. `syncthing.nix` knows nothing about what the
synced folder contains. They share only a path convention:
`~/Sync/keepassxc/`.

## Component: `modules/keepassxc.nix`

Responsibilities:

- Add `pkgs.keepassxc` to `home.packages`. This single package provides both the
  GUI application and the `keepassxc-cli` binary.
- No management of `~/.config/keepassxc/keepassxc.ini`. Preferences such as
  recent-files list, window layout, and quick-unlock toggles remain imperative
  state owned by the application itself.
- No autostart entry in this iteration. The user launches KeePassXC manually.

CLI interaction model:

`keepassxc-cli show <db.kdbx> <entry>` prompts for the master password on each
invocation. This matches the chosen usage mode (prompt-per-call) and requires
no additional configuration.

## Component: `modules/syncthing.nix`

Uses home-manager's built-in `services.syncthing` module.

Configuration:

- `services.syncthing.enable = true` — starts a user-level systemd service on
  login.
- `services.syncthing.overrideDevices = false` and
  `services.syncthing.overrideFolders = false` — Nix declares the folder
  scaffolding, but the web UI can add or adjust devices and folders without
  being reset on the next `home-manager switch`. Strict mode can be enabled
  later once the topology is stable.
- One folder declared:
  - id: `keepassxc-db`
  - path: `~/Sync/keepassxc/`
  - devices: empty list initially; peers added via the web UI.
- Devices list at the top level: empty initially; peers added via the web UI.

The Syncthing web UI is reachable at `http://localhost:8384` after activation.

## Data flow

1. User edits an entry in KeePassXC GUI on machine A.
2. KeePassXC writes to `~/Sync/keepassxc/passwords.kdbx` on machine A.
3. Syncthing on machine A detects the change and pushes it to peers.
4. Syncthing on machine B writes the updated file to `~/Sync/keepassxc/`.
5. KeePassXC on machine B, next time it is opened or refreshed, sees the new
   file contents.
6. CLI usage on either machine reads the same file via
   `keepassxc-cli show ~/Sync/keepassxc/passwords.kdbx <entry>`.

Sync conflicts (concurrent edits on two offline machines) are surfaced by
Syncthing as `sync-conflict-*.kdbx` files. KeePassXC's built-in database merge
feature is used to reconcile them manually.

## Bootstrap flow

First machine (no existing peers):

1. Run `home-manager switch --flake .`.
2. Open KeePassXC, create a new database at
   `~/Sync/keepassxc/passwords.kdbx`, set a master password.
3. Populate initial entries.

Subsequent machines:

1. Run `home-manager switch --flake .`.
2. Open `http://localhost:8384` and pair with an existing peer by exchanging
   device IDs (one-time step per pair of machines).
3. Accept the `keepassxc-db` folder share invitation.
4. Wait for the `.kdbx` file to sync into `~/Sync/keepassxc/`.
5. Open KeePassXC, point it at `~/Sync/keepassxc/passwords.kdbx`, unlock with
   the master password.

Conflict handling: if two machines edit the database while both are offline,
Syncthing produces a `sync-conflict-<timestamp>-<device>.kdbx` file alongside
the original. Open both databases in KeePassXC and use
`Database → Merge from database…` to reconcile, then delete the conflict file.

## Placement in the flake

`home.nix` imports both new modules alongside the existing set:

```nix
imports = [
  ./modules/packages.nix
  ./modules/zsh.nix
  ./modules/tmux.nix
  ./modules/git.nix
  ./modules/neovim.nix
  ./modules/keepassxc.nix
  ./modules/syncthing.nix
];
```

Because `home.nix` is included by every profile in `flake.nix` (`base`, `dev`,
`personal`), all three profiles receive KeePassXC and Syncthing.

## Verification

After `home-manager switch --flake .`:

- `nix flake check` exits 0.
- `command -v keepassxc` and `command -v keepassxc-cli` both resolve.
- `systemctl --user status syncthing` reports `active (running)`.
- `curl -sf http://localhost:8384 >/dev/null` succeeds.
- Opening KeePassXC and unlocking a test database succeeds.
- `keepassxc-cli show ~/Sync/keepassxc/<test-db>.kdbx <test-entry>` prompts for
  the master password and returns the expected value.

## Risks and trade-offs

- **State-file conflicts.** Two machines editing the DB while both are offline
  produces a Syncthing conflict file. Mitigation: KeePassXC's merge feature.
  See the conflict-handling note in the bootstrap section.
- **Device pairing is imperative.** Device IDs live only in each Syncthing
  instance's local state, not in the Nix expression. A machine rebuild requires
  re-pairing via the web UI. This is an accepted trade-off to keep device IDs
  out of the git repo.
- **`overrideDevices=false` weakens declarative guarantees.** Some
  Syncthing configuration drifts outside of Nix control. Accepted for now;
  revisit once topology is stable.
- **No secret bootstrap for the initial `.kdbx`.** On a fresh machine with no
  peers, the user must create the database manually. This is intentional — the
  master password must never be in Nix.
