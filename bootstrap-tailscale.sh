#!/usr/bin/env bash
# Interactive first-time Tailscale login for a new machine.
#
# modules/syncthing.nix's peers (suspense, dance) are reachable only at their
# tailnet (MagicDNS) addresses -- `tcp://suspense:22000`, `tcp://dance:22000`
# -- because syncthing's own discovery servers are deliberately disabled (see
# that module's globalAnnounceEnabled comment). Until this machine is logged
# into the same tailnet, those names don't resolve anywhere, so
# bootstrap-syncthing.sh's "waiting for a peer to connect" step would hang
# forever with no indication why.
#
# Meant to run right after a `dlsys switch nixos` (or `nrs`) that first turns
# on `services.tailscale` for this host -- see the comment in
# nixos/hosts/<host>.nix next to it if this is a brand-new machine and that
# block isn't there yet, add it the same way console/suspense have it -- and
# before bootstrap-syncthing.sh.
set -euo pipefail

if ! command -v tailscale >/dev/null 2>&1; then
  echo "tailscale isn't on PATH. Make sure services.tailscale.enable is set in" >&2
  echo "nixos/hosts/\$(hostname).nix and 'dlsys switch nixos' (or 'nrs') has" >&2
  echo "completed, then re-run this script." >&2
  exit 1
fi

echo "Waiting for tailscaled.service..."
waited=0
timeout=60
until systemctl is-active --quiet tailscaled.service; do
  if (( waited >= timeout )); then
    echo "tailscaled.service still isn't active after ${timeout}s." >&2
    exit 1
  fi
  sleep 2
  waited=$((waited + 2))
done

backend_state() {
  sudo tailscale status --json | jq -r .BackendState
}

if [[ "$(backend_state)" != "Running" ]]; then
  cat <<'EOF'

Not logged into Tailscale yet. Starting 'tailscale up' -- open the URL it
prints below in a browser and approve this device on the tailnet:

EOF
  sudo tailscale up
fi

echo "Waiting for this device to report Running..."
tick=0
until [[ "$(backend_state)" == "Running" ]]; do
  sleep 2
  tick=$((tick + 1))
  if (( tick % 15 == 0 )); then
    echo "Still waiting -- run 'tailscale status' for details."
  fi
done

cat <<'EOF'

Tailscale is up. Peers are now reachable by tailnet name (suspense, dance,
console).

Next: ./bootstrap-syncthing.sh
EOF
