#!/usr/bin/env bash
# The only bash left. Its whole job is to make `dlsys` runnable, then get out
# of the way -- so it must work on a machine that has nothing but a git
# checkout and a shell.
#
#   ./bootstrap.sh switch          same as `dlsys switch`
#   ./bootstrap.sh init            first run on a new machine
#
# Once home-manager has run, `dlsys` is on PATH and you can call it directly.
# This script stays the entry point for two cases that cannot assume that:
# a fresh machine, and `dlsys rollout`, which invokes it over ssh because the
# remote may not have this revision of the binary installed yet.
set -euo pipefail

here=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)

# A fresh Nix ships with flakes off, so the very first invocation would die
# with "experimental Nix feature 'nix-command' is disabled" before it could
# write the nix.conf that enables them. Appended last so it wins over any
# inherited NIX_CONFIG; NixOS hosts already set both via
# nix.settings.experimental-features.
export NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG$'\n'}extra-experimental-features = nix-command flakes"

if ! command -v nix >/dev/null 2>&1; then
  # Sourcing the profile is enough when Nix is installed but not on PATH --
  # a non-login shell, typically. Try that before proposing an install.
  for profile in /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh \
                 "$HOME/.nix-profile/etc/profile.d/nix.sh"; do
    # shellcheck disable=SC1090
    [[ -e "$profile" ]] && . "$profile" && break
  done
fi

if ! command -v nix >/dev/null 2>&1; then
  # Installing the daemon touches /nix, systemd units and /etc/bash.bashrc,
  # and is not cleanly reversible. Ask rather than assume -- this is the one
  # thing here that changes a machine the user may not have meant to change.
  echo "Nix is not installed. The official multi-user installer will:"
  echo "  - create /nix and a nix-daemon systemd service"
  echo "  - add build users and edit shell init files"
  echo "It requires sudo and is not cleanly reversible."
  read -r -p "Run it now? [y/N]: " answer </dev/tty
  [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted; install Nix and re-run." >&2; exit 1; }
  curl --proto '=https' --tlsv1.2 -sSf -L https://nixos.org/nix/install | sh -s -- --daemon
  # shellcheck disable=SC1091
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi

# git+file:// rather than path: when this is a git checkout. path: copies the
# directory verbatim and ignores .gitignore, so it would haul ./target -- a
# cargo debug build -- into the store on every invocation. Same bug that made
# `dlsys switch` slow when flake.nix fetched dl-herd with path:.
if [[ -d "$here/.git" ]]; then
  flake="git+file://$here"
else
  flake="path:$here"
fi

exec nix run --impure "$flake#dlsys" -- "$@"
