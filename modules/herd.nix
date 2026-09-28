{ lib, ... }:

# The fleet, as every machine in it sees the others.
#
# One list, deployed everywhere. herd drops its own hostname, so whichever
# machine you are sitting at is the one aggregating and the rest are answering
# -- there is no hub to configure, and nothing to change when you move.
#
# The destinations carry usernames because the three do not agree on one, which
# is also why this cannot be derived from the hostname alone. They come from
# hosts.nix now rather than being written out here; the order is alphabetical
# as a result, which herd does not care about (remote.rs `hosts()` filters the
# list and fans out over it, with no privileged first entry).
{
  programs.herd.hosts =
    lib.mapAttrsToList (host: v: "${v.user}@${host}") (import ../hosts.nix);
}
