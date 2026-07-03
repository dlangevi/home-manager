{ machines, host, features }:
let
  new = machines // { ${host} = features; };
  keys = builtins.sort (a: b: builtins.lessThan a b) (builtins.attrNames new);
  formatFeatures = fs:
    builtins.concatStringsSep " " (map (f: "\"" + f + "\"") fs);
  formatEntry = k:
    "  \"" + k + "\" = [ " + formatFeatures new.${k} + " ];";
in
"{\n" + builtins.concatStringsSep "\n" (map formatEntry keys) + "\n}\n"
