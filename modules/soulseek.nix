# Nicotine+, a Soulseek client.
#
# Its own feature rather than part of desktop-apps: that feature is also
# selected by console and dance, and neither is a machine you'd go looking for
# music on. suspense is where music is acquired (it also holds `music`/cdrip
# and the optical drive); dance only serves the finished library.
#
# Home-manager rather than NixOS -- a GUI app one user launches, no daemon, no
# hardware, no root. The one system-layer piece is the listening port: without
# it Nicotine+ runs in "closed" mode, where downloads still work but no peer can
# connect to you directly and your queue positions suffer. TCP 2234 is opened in
# both nixos/hosts/suspense.nix and nixos/hosts/console.nix; set the same port
# under Preferences -> Network on each machine, as Nicotine+ writes its own
# config at runtime and so is not managed from here.
{ pkgs, ... }:

{
  home.packages = [ pkgs.nicotine-plus ];
}
