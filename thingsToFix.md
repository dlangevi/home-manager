## Status

- "init works but then fails to push (no git rights)" — the home-manager
  repo's own `origin` was HTTPS, a different credential than the SSH key
  `dlsys init` set up (that key only ever covered fetching the private
  `dl-herd` flake input). Fixed by pointing `origin` at SSH instead, so one
  key does both. Clone itself still has to stay HTTPS (anonymous, public
  repo) since there's no SSH identity yet at that point.
- "herd also fails" — turned out to be universal, not herd-specific: `dl-herd`
  was a top-level flake `input`, which nix fetches before it can even call
  `outputs`, regardless of which host/features are being built. So *no*
  `dlsys switch` worked pre-auth, on any machine, any feature set. Fixed by
  decoupling `dl-herd` from `inputs` entirely (flake.nix's `herdSrc` + new
  `dl-herd.lock.json`) — a host that never selects `herd` now never touches
  it, auth or no auth. Also dropped `dlsys init`'s GitHub-SSH gate
  (`ensure_github_ssh` in init.rs), since nothing it protected against
  survives that change.
- "switch fails because the nixos hostname doesn't match" — fixed: `dlsys
  switch` now takes `--host <name>` to override the detected hostname (useful
  right after `init` on a fresh install, before a nixos switch has actually
  renamed the box).
- `bootstrap-syncthing.sh` itself had a real bug (not in this file originally,
  found while chasing the above): its GUI-address parsing matched the first
  `<address>` tag in `config.xml` *at all*, which is a peer device's address,
  not the GUI's. Fixed.

## Newly discovered: Tailscale is a hard prerequisite, not yet automated

Syncthing's peers (suspense, dance, console) are addressed only by tailnet
(MagicDNS) name in `modules/syncthing.nix` (global discovery is deliberately
off). A fresh machine with no Tailscale login can never reach a peer, so
`bootstrap-syncthing.sh`'s "waiting for a peer to connect" step would hang
forever with no indication why. Added `./bootstrap-tailscale.sh` (logs in,
waits for `Running`) and a fail-fast check at the top of
`bootstrap-syncthing.sh` that refuses immediately with a clear message if
Tailscale isn't up yet, instead of hanging.

Still manual, by design (private key material is deliberately never
provisioned by this repo — see modules/base.nix):

- `services.tailscale.enable` has to be hand-added to a brand-new
  `nixos/hosts/<host>.nix` the same way console/suspense have it — `dlsys
  init` does not do this automatically (consistent with the existing "grow
  the host file by hand" convention).
- The real SSH identity (`~/.ssh/id_github`, `~/.ssh/id_admin`) arrives via
  the synced KeePassXC vault once the "Sync" folder lands, not generated
  per-machine. Pull those out by hand after `bootstrap-syncthing.sh` finishes.

## Current bring-up order (now implemented end to end)

1. NixOS installs via the installer (placeholder hostname).
2. Clone the public repo over HTTPS (no creds needed):
   `git clone https://github.com/dlangevi/home-manager.git`
3. `./bootstrap.sh init` — name the real hostname, pick features (skip `herd`
   for now — nothing needs GitHub access yet with it excluded), registers
   + does the first home-manager switch. No GitHub auth required at all.
4. Hand-add `services.tailscale.enable = true;` to the new
   `nixos/hosts/<host>.nix` (copy console's block), then
   `dlsys switch nixos` (needs sudo).
5. `./bootstrap-tailscale.sh` — log into the tailnet.
6. `./bootstrap-syncthing.sh` — pair with an existing machine, pull down the
   "Sync" folder.
7. Pull `id_github`/`id_admin` out of the synced KeePassXC vault into
   `~/.ssh/`.
8. `git push` now works (SSH origin + real key). Add `herd` (and anything
   else that needs it) to `machines.nix` and switch again whenever ready.
