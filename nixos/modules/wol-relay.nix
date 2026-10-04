# Wake-on-LAN relay for suspense.
#
# suspense is the Sunshine host and spends most of its life powered off. A
# magic packet only reaches it as a broadcast on this LAN, and no VPN into
# this network carries one: UniFi OS terminates Teleport and WireGuard on a
# routed subnet of their own (teleportSubnet in media-audio.nix is
# 192.168.2.0/24), and routers have not forwarded directed broadcasts since
# RFC 2644 made them a smurf-attack vector.
#
# Unicast fails for a less obvious reason, and it is the one worth writing
# down. Routing a packet to suspense's LAN address works fine; the gateway
# then has to resolve that address to a MAC, and a powered-off machine does
# not answer ARP, so the packet is dropped before it reaches the wire. There
# is a misleading window of a few minutes after shutdown where the gateway's
# still-cached ARP entry makes this appear to work.
#
# dance is on this LAN and always on, so it can be the thing that already
# knows suspense's MAC. Two halves:
#
#   - advertise this LAN into the tailnet, so a packet addressed to suspense
#     from anywhere on the tailnet arrives here to be forwarded;
#   - hold a permanent neighbour entry for suspense, so forwarding it needs
#     no ARP reply and emits a frame addressed to suspense's NIC regardless.
#
# The other two halves of a working wake live elsewhere: the adapter is armed
# by networking.interfaces.enp5s0.wakeOnLan in hosts/suspense.nix, and the
# board is armed in the BIOS (Advanced -> ACPI Configuration: "PCIE Devices
# Power On" enabled, "Deep Sleep" disabled -- the latter otherwise cuts
# standby power to the PCIe slots in S5, so the NIC cannot listen at all).
#
# This deliberately does not fix Teleport. A neighbour entry here only helps
# packets that dance routes; one arriving over the UniFi VPN still dies at the
# gateway's ARP lookup. That would need a static entry on the UDM itself,
# which this repo cannot express and which firmware updates discard.
{ pkgs, ... }:

let
  lanSubnet = "10.0.70.0/24";

  # suspense's onboard Realtek (enp5s0, r8169). The MAC is what actually does
  # the work; the address only has to be the one Moonlight and `wakeonlan -i`
  # aim at, and it is a DHCP reservation on the UDM.
  suspenseIp = "10.0.70.116";
  suspenseMac = "70:85:c2:54:95:95";
in
{
  services.tailscale = {
    # enable and openFirewall come from media-audio.nix, which dance also
    # imports -- only the routing half is new here.
    useRoutingFeatures = "server";

    # extraSetFlags, not extraUpFlags. The latter is read only by
    # tailscaled-autoconnect, which the module gates on authKeyFile being set;
    # dance has no auth key, so flags put there would never be applied and the
    # route would silently never appear. extraSetFlags drives
    # tailscaled-set.service, which runs unconditionally.
    #
    # The route still has to be approved once, by hand, under Machines ->
    # dance -> Subnets in the Tailscale admin console.
    extraSetFlags = [ "--advertise-routes=${lanSubnet}" ];
  };

  # For driving the relay by hand over ssh, which is also how it gets tested.
  environment.systemPackages = [ pkgs.wakeonlan ];

  # Reinstated on every link event rather than written once at boot: a
  # permanent neighbour entry is flushed when the interface goes down, and an
  # entry that quietly disappears after a link flap would turn this into an
  # intermittent failure months from now.
  networking.networkmanager.dispatcherScripts = [{
    type = "basic";
    source = pkgs.writeShellScript "suspense-wol-neighbour" ''
      case "$2" in
        up|dhcp4-change) ;;
        *) exit 0 ;;
      esac
      # The tailnet interface coming up says nothing about the LAN link.
      [ "$1" = tailscale0 ] && exit 0

      # Derived rather than hardcoded: dance's LAN interface name is recorded
      # nowhere else in this repo (hardware/dance.nix only carries a
      # commented-out template line), so pinning it here would be a second
      # place to get it wrong.
      dev=$(${pkgs.iproute2}/bin/ip -o route get ${suspenseIp} \
        | ${pkgs.gawk}/bin/awk '{print $3}')
      [ -n "$dev" ] || exit 0

      ${pkgs.iproute2}/bin/ip neigh replace ${suspenseIp} \
        lladdr ${suspenseMac} dev "$dev" nud permanent
    '';
  }];
}
