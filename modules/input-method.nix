{ pkgs, ... }:

{
  i18n.inputMethod = {
    enable = true;
    type = "fcitx5";
    fcitx5 = {
      addons = with pkgs; [ qt6Packages.fcitx5-chinese-addons ];
      # Sway speaks the native Wayland input-method protocol; XIM (the
      # waylandFrontend = false path) only reaches Xwayland-routed apps.
      # Harmless for plasmax11 on suspense -- fcitx5 picks its frontend by
      # the live session type, not by what's declared here.
      waylandFrontend = true;

      settings = {
        # Pins the trigger hotkey rather than relying on fcitx5's upstream
        # default (which happens to also be Control+space today) so this
        # stays correct even if that default ever changes.
        globalOptions.Hotkey = {
          TriggerKeys = "Control+space";
          EnumerateWithTriggerKeys = true;
        };

        # Without an explicit profile, a fresh fcitx5 only auto-generates
        # whatever group its first run happens to land on -- not guaranteed
        # to include Pinyin at all. DefaultIM is keyboard-us so sessions
        # start in plain keyboard mode; Control+space (above) enumerates to
        # Pinyin and back.
        inputMethod = {
          GroupOrder."0" = "Default";
          "Groups/0" = {
            Name = "Default";
            "Default Layout" = "us";
            DefaultIM = "keyboard-us";
          };
          "Groups/0/Items/0".Name = "keyboard-us";
          "Groups/0/Items/1".Name = "pinyin";
        };
      };
    };
  };
}
