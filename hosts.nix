# The fleet's ssh coordinates: who to log in as, and the mnemonic key that
# reaches each host from a picker.
#
# This is the source of truth. It exists because the same three triples were
# written out by hand in four places (dlsys, modules/herd.nix,
# modules/wezterm.nix, and tmux's domain menu would have been a fifth) and had
# already started to drift. Usernames are carried rather than derived because
# the three machines do not agree on one. Hosts resolve by bare name over
# Tailscale MagicDNS; there is no ssh_config and none is needed.
#
# Keyed by hostname so entries line up with machines.nix, but kept separate
# from it: machines.nix answers "what is deployed where" and is rewritten
# programmatically by `dlsys init`, while this is "how do I reach it" and is
# hand-maintained.
#
# `key` is the single character that selects the host in tmux's prefix+C menu,
# in tmux's prefix+M-<key> shortcut, and in wezterm's LEADER+ALT bindings --
# deliberately the same letter in all three.
{
  console  = { user = "console";  key = "c"; };
  dance    = { user = "dance";    key = "d"; };
  suspense = { user = "dlangevi"; key = "s"; };
}
