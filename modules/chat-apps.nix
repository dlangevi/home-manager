{ pkgs, ... }:

{
  home.packages = with pkgs; [
    discord
    signal-desktop
    teams-for-linux
    zoom-us
  ];

  # Google Messages for web, as its own launcher entry rather than a bookmark
  # you have to go find. Unlike KDE Connect's kdeconnect-sms -- which reads
  # Android's SMS/MMS content provider and so cannot see RCS conversations,
  # because Google Messages keeps those in its own private database -- this is
  # the real app, so RCS threads, group chats and media all work. It relays
  # through the phone, so the phone has to be online, and the QR pairing lapses
  # after roughly two weeks of not using it.
  #
  # Points at floorp-bin rather than the `firefox` on PATH: that one comes
  # from the NixOS layer, which non-NixOS installs of this feature don't
  # have, and the entry would silently dangle there. floorp-bin itself comes
  # from the `desktop-apps` feature, which every machine selecting this one
  # also selects.
  xdg.desktopEntries.google-messages = {
    name = "Messages";
    comment = "Text messages from the phone (Google Messages for web)";
    exec = "${pkgs.floorp-bin}/bin/floorp --new-window https://messages.google.com/web";
    icon = "smartphone";
    terminal = false;
    type = "Application";
    categories = [ "Network" "InstantMessaging" ];
  };
}
