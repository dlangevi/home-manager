# Mirror ~/documents onto the second physical disk.
#
# ~/documents is the canonical copy of personal paperwork (taxes, immigration,
# medical, housing, identity) and lives on the root SSD. This mirrors it to the
# storage SSD so a single drive failure cannot lose it.
#
# This is REDUNDANCY, NOT HISTORY. rsync --delete makes the mirror a true
# replica, so a deletion in ~/documents propagates on the next run. It does not
# protect against fire, theft, or an accidental rm, and it is not a substitute
# for an encrypted offsite copy.
{ config, pkgs, ... }:

let
  home    = config.home.homeDirectory;
  storage = "${home}/storage";
  src     = "${home}/documents";
  dst     = "${storage}/documents-mirror";

  # On-demand encrypted snapshot for manual upload to Google Drive.
  # Deliberately NOT automated: no daemon, no OAuth, no cloud credentials on
  # this machine. Produces one file; you upload it when you feel like it.
  snapshot = pkgs.writeShellScriptBin "documents-snapshot" ''
    set -euo pipefail
    src="${src}"
    out="''${1:-$HOME/documents-snapshot-$(${pkgs.coreutils}/bin/date +%F).tar.age}"

    if [ ! -d "$src" ]; then
      echo "$src does not exist" >&2
      exit 1
    fi

    cat >&2 <<'NOTE'
    This snapshot is encrypted with a passphrase you are about to choose.
    Store that passphrase in KeePass AND write it on paper kept somewhere
    physically separate. If you lose it, the snapshot is unrecoverable --
    there is no reset, no recovery, no support to appeal to.
    NOTE

    ${pkgs.gnutar}/bin/tar -C "$HOME" -cf - documents \
      | ${pkgs.age}/bin/age -p -o "$out"
    ${pkgs.coreutils}/bin/chmod 600 "$out"

    echo >&2
    echo "wrote $out ($(${pkgs.coreutils}/bin/du -h "$out" | ${pkgs.coreutils}/bin/cut -f1))" >&2
    echo >&2
    echo "verify + restore into a scratch dir:" >&2
    echo "  mkdir -p /tmp/restore && age -d '$out' | tar -C /tmp/restore -xf -" >&2
  '';

  mirror = pkgs.writeShellScript "documents-mirror" ''
    set -euo pipefail

    # Guard 1: if the storage disk is not mounted, ${storage} is just a bare
    # directory on the root disk. Mirroring there would burn root space and
    # give false confidence that the data sits on a second spindle.
    if ! ${pkgs.util-linux}/bin/mountpoint -q "${storage}"; then
      echo "storage disk not mounted -- skipping mirror" >&2
      exit 0
    fi

    # Guard 2: never let a missing or empty source --delete the mirror away.
    if [ ! -d "${src}" ] || [ -z "$(${pkgs.coreutils}/bin/ls -A "${src}")" ]; then
      echo "${src} missing or empty -- refusing to mirror" >&2
      exit 1
    fi

    ${pkgs.coreutils}/bin/mkdir -p "${dst}"
    ${pkgs.coreutils}/bin/chmod 700 "${dst}"

    # --checksum: the set is small (~500M), so pay the read cost and catch
    # silent corruption rather than trusting size+mtime.
    ${pkgs.rsync}/bin/rsync -a --delete --checksum "${src}/" "${dst}/"

    echo "mirrored $(${pkgs.findutils}/bin/find "${src}" -type f | ${pkgs.coreutils}/bin/wc -l) files"
  '';
in
{
  home.packages = [ pkgs.age snapshot ];

  systemd.user.services.documents-mirror = {
    Unit.Description = "Mirror ~/documents to the storage disk";
    Service = {
      Type = "oneshot";
      ExecStart = toString mirror;
    };
  };

  systemd.user.timers.documents-mirror = {
    Unit.Description = "Daily mirror of ~/documents to the storage disk";
    Timer = {
      OnCalendar = "daily";
      Persistent = true; # a powered-off day still runs on next boot
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
