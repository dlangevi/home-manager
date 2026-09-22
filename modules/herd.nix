{ ... }:

# The fleet, as every machine in it sees the others.
#
# One list, deployed everywhere. herd drops its own hostname, so whichever
# machine you are sitting at is the one aggregating and the rest are answering
# -- there is no hub to configure, and nothing to change when you move.
#
# The destinations carry usernames because the three do not agree on one, which
# is also why this cannot be derived from the hostname alone.
{
  programs.herd.hosts = [
    "dlangevi@suspense"
    "dance@dance"
    "console@console"
  ];
}
