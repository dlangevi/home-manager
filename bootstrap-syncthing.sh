#!/usr/bin/env bash
# Interactive first-time Syncthing pairing for a new machine.
#
# home-manager's `base` feature (modules/syncthing.nix) declares and starts
# the syncthing daemon and a "Sync" folder, but it cannot declare the mesh
# itself: pairing two Syncthing devices needs each side's device ID, which
# only exists once that device's daemon has started for the first time. Until
# this device is paired in and the "Sync" folder actually arrives,
# modules/claude.nix's symlinks into ~/Sync/claude (CLAUDE.md, commands/,
# skills/, memory/) point at nothing.
#
# Run this AFTER a `dlsys switch` (or `dlsys init`) has already applied the
# `base` feature -- that's what starts syncthing in the first place.
set -euo pipefail

if ! command -v curl >/dev/null 2>&1; then
  exec nix shell nixpkgs#curl --command "$0" "$@"
fi

if ! systemctl --user is-active --quiet syncthing.service; then
  echo "syncthing.service is not running. Run 'dlsys switch' first (it's part" >&2
  echo "of the 'base' feature), then re-run this script." >&2
  exit 1
fi

# home-manager/upstream syncthing moved its state dir off ~/.config to the
# XDG state dir a while back; this is where a current nixpkgs syncthing puts
# it, cert included.
config="$HOME/.local/state/syncthing/config.xml"
[[ -f "$config" ]] || {
  echo "No $config yet -- syncthing hasn't finished its first start. Wait a" >&2
  echo "few seconds and re-run." >&2
  exit 1
}

api_key=$(grep -oP '(?<=<apikey>)[^<]+' "$config")
gui_addr=$(grep -oP '(?<=<address>)[^<]+' "$config" | grep -v '^dynamic$' | head -1)
api() { curl -sf -H "X-API-Key: $api_key" "http://${gui_addr}$1"; }

device_id=$(api /rest/system/status | jq -r .myID)

cat <<EOF

This machine's Syncthing device ID:

    $device_id

On a machine that's already syncing (e.g. suspense), open its Syncthing web
UI (usually http://localhost:8384) and:
  1. Actions -> Add Remote Device -> paste the ID above, name it "$(hostname)".
  2. Under "Share Folders with Device", check "Sync". Save.
  3. If this machine's own UI (http://${gui_addr}) pops a prompt to accept
     the incoming device or folder, accept it there too.

Waiting for this device to connect to a peer...
EOF

tick=0
until api /rest/system/connections \
  | jq -e '.connections | to_entries[] | select(.value.connected)' >/dev/null 2>&1
do
  sleep 2
  tick=$((tick + 1))
  # Every ~30s, repeat the ID so it doesn't scroll off a long terminal.
  if (( tick % 15 == 0 )); then
    echo "Still waiting -- device ID is $device_id"
  fi
done
echo "Connected to a peer."

echo "Waiting for the 'Sync' folder to finish its initial sync..."
while true; do
  status=$(api "/rest/db/status?folder=sync" 2>/dev/null) || { sleep 2; continue; }
  state=$(jq -r '.state' <<<"$status")
  global=$(jq -r '.globalBytes' <<<"$status")
  insync=$(jq -r '.inSyncBytes' <<<"$status")
  pct=0
  (( global > 0 )) && pct=$(( insync * 100 / global ))
  printf '\r  state=%-14s %3d%%  ' "$state" "$pct"
  [[ "$state" == "idle" && "$global" -gt 0 ]] && break
  sleep 2
done
echo

cat <<'EOF'

Done. ~/Sync should now be populated, so ~/.claude/CLAUDE.md and friends
should resolve (modules/claude.nix symlinks them from ~/Sync/claude). If a
symlink still looks dangling, re-run `dlsys switch` to re-trigger its
activation hooks.

If this device/folder share doesn't survive the next `dlsys switch`, see the
`overrideFolders` comment in modules/syncthing.nix -- it may still need
flipping back to `false` now that every machine has paired at least once.
EOF
