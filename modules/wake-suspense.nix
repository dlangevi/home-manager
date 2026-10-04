# "Wake suspense and start playing", as one launcher on console.
#
# suspense is downstairs and normally powered off; this is the upstairs end of
# that. Its own feature rather than part of desktop-apps because desktop-apps
# is also selected by dance and suspense, and a launcher that wakes suspense
# is meaningless on suspense.
#
# The two halves that make the packet land are elsewhere:
# nixos/modules/wol-relay.nix (subnet route + permanent ARP entry on dance)
# and nixos/hosts/suspense.nix (arming the NIC).
{ pkgs, ... }:

let
  suspenseIp = "10.0.70.116";
  lanBroadcast = "10.0.70.255";
  suspenseMac = "70:85:c2:54:95:95";

  # Sunshine's HTTP port. Waiting on this rather than on ping is deliberate:
  # the kernel answers ICMP long before Sunshine is listening, and handing
  # Moonlight a host that is up but not yet serving is the failure this
  # launcher exists to avoid.
  sunshinePort = 47989;

  wake-suspense = pkgs.writeShellScriptBin "wake-suspense" ''
    # Both sends, unconditionally. The broadcast is what works when console is
    # on this LAN; the unicast is what works when it is not, routing over the
    # tailnet via dance's subnet route and its permanent neighbour entry.
    # Neither can report success and neither costs anything, so sending both
    # beats branching on which network console happens to be on.
    ${pkgs.wakeonlan}/bin/wakeonlan -i ${lanBroadcast} ${suspenseMac}
    ${pkgs.wakeonlan}/bin/wakeonlan -i ${suspenseIp} ${suspenseMac}

    # ~2 minutes. A cold boot to Sunshine listening is comfortably under that,
    # and giving up earlier would just drop the user into a dead Moonlight.
    for _ in $(${pkgs.coreutils}/bin/seq 60); do
      ${pkgs.netcat-openbsd}/bin/nc -z -w 1 ${suspenseIp} ${toString sunshinePort} && break
      ${pkgs.coreutils}/bin/sleep 2
    done

    # Launch regardless of whether the wait succeeded -- Moonlight's own error
    # is more useful than this script silently deciding not to start.
    exec ${pkgs.moonlight-qt}/bin/moonlight "$@"
  '';
in
{
  home.packages = [ wake-suspense ];

  # Full store path rather than a bare name, for the reason spelled out on the
  # google-messages entry in desktop-apps.nix: a .desktop Exec= resolved
  # against the session PATH dangles wherever that PATH differs.
  xdg.desktopEntries.wake-suspense = {
    name = "Wake suspense and play";
    comment = "Wake suspense, wait for Sunshine, then open Moonlight";
    exec = "${wake-suspense}/bin/wake-suspense";
    icon = "moonlight";
    terminal = false;
    type = "Application";
    categories = [ "Game" ];
  };
}
