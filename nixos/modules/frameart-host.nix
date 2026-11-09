# Image host for the Frame Art app on the Samsung Smart Monitor.
#
# The monitor has ~1 GB of free storage, so the art lives here and the app
# fetches it over HTTP. nginx lists the folder as JSON (autoindex_format json),
# so no index file has to be generated. Content is pushed in with rsync from
# console and edited in place, not built by Nix -- same reasoning as the
# freelance and jpc pages.
{ pkgs, ... }:

let
  siteDir = "/srv/www/frameart";
  port = 8088;

  # Where the monitor sits: the home router's own subnet, not dance's LAN.
  # dance's other services are scoped to 10.0.70.0/24 + the tailnet only, so
  # this port gets its own rule rather than widening port 80 for everyone.
  monitorSubnet = "192.168.0.0/24";
  lanSubnet = "10.0.70.0/24";
  tailnet = "100.64.0.0/10";

  # console's key, limited to rsync inside siteDir. It cannot get a shell,
  # forward ports, or touch anything outside the image folder, even though
  # the `dance` account itself is in wheel.
  consoleKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBkjtBq222boX0Q1zyMYbDJnJHA12T8vBAeLWIRtGWrC console@frameart";
in
{
  # /srv/www itself comes from freelance-site.nix.
  systemd.tmpfiles.rules = [
    "d ${siteDir} 0755 dance users -"
  ];

  services.nginx.virtualHosts."frameart" = {
    listen = [ { addr = "0.0.0.0"; inherit port; } ];
    root = siteDir;
    extraConfig = ''
      autoindex on;
      autoindex_format json;
      # The TV app loads from file://, so reading the listing is cross-origin.
      # Plain <img> loads do not need it.
      add_header Access-Control-Allow-Origin "*" always;
    '';
  };

  networking.firewall.extraCommands =
    let
      allow = subnet:
        "iptables -A nixos-fw -p tcp -s ${subnet} --dport ${toString port} -j nixos-fw-accept";
    in ''
      ${allow monitorSubnet}
      ${allow lanSubnet}
      ${allow tailnet}
    '';

  users.users.dance.openssh.authorizedKeys.keys = [
    ''restrict,command="${pkgs.rrsync}/bin/rrsync ${siteDir}" ${consoleKey}''
  ];
}
