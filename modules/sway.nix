{ ... }:
{
  # Only sets the modifier key; everything else is sway's own sensible
  # default keybinding set (home-manager fills it in around this).
  wayland.windowManager.sway = {
    enable = true;
    config = {
      modifier = "Mod1"; # left Alt
    };
  };
}
