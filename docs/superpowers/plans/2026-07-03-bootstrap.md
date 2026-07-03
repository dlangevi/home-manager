# Bootstrap Script Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce a `bootstrap` bash CLI with `init` and `upgrade` subcommands, backed by hostname-keyed feature composition declared in `machines.nix` and a feature catalog in `features.nix`.

**Architecture:** Split the flake's static `homeConfigurations.base/dev/personal` into a feature catalog (`features.nix`, function of inputs) and a per-machine registry (`machines.nix`, hostname → feature name list). `flake.nix` composes hostname-keyed configurations from those two files. A `bootstrap` script wraps interactive registration (`init`) and subsequent applies (`upgrade`), with a small `scripts/machines-write.nix` helper handling the deterministic rewrite of `machines.nix`.

**Tech Stack:** Nix flakes, home-manager 25.11 (standalone), bash 5, shellcheck.

**Spec:** `docs/superpowers/specs/2026-07-03-bootstrap-design.md`

## Global Constraints

- Target home-manager release: 25.11 (unchanged; matches flake.nix inputs).
- `flake.nix` uses `builtins.getEnv` for USER and HOME, so every `nix eval`, `nix build`, `nix flake check`, and `home-manager switch` invocation must pass `--impure`.
- `machines.nix` must be `{ }` (empty attrset) when no machines are registered; the flake must still evaluate in that state.
- No `jq` dependency. All structured data extraction happens via `nix eval --json` or `--raw` with `--apply`/`--expr`.
- All bash scripts start with `#!/usr/bin/env bash` and `set -euo pipefail`.
- `shellcheck bootstrap` must exit 0.
- The existing `.gitignore` (`result`, `*.swp`, `log.txt`, etc.) is respected — do not commit `result` symlinks or the current `log.txt`.
- Commit messages: concise, describe why not what.
- No `nix flake update` outside the explicit `--update` flag on `upgrade`. Do not touch `flake.lock` as part of any task in this plan.

## File Structure

New files:

- `features.nix` — function of flake inputs, returns `{ feature-name = [ modules... ]; }`. Single responsibility: the catalog of composable features.
- `machines.nix` — data-only attrset mapping hostname → list of feature names. Single responsibility: the fleet registry.
- `scripts/machines-write.nix` — pure Nix helper that takes `{ machines, host, features }` and returns the fully formatted new file content. Isolates all string-formatting logic from bash.
- `bootstrap` — executable bash script at repo root. Two subcommands (`init`, `upgrade`).

Modified files:

- `flake.nix` — replaces the static `base`/`dev`/`personal` outputs with per-hostname configurations derived from `features.nix` + `machines.nix`.
- `modules/zsh.nix` — the `hms` alias replaced with a call to `./bootstrap upgrade`.
- `README.md` — Setup and Updating sections rewritten to point at `./bootstrap`.

Unchanged: `home.nix`, `modules/*.nix` (except `zsh.nix`), `flake.lock`.

Rationale for `scripts/machines-write.nix` living in its own directory: bootstrap needs one helper today. If more bootstrap-support Nix expressions appear later, they land in the same directory. Keeps the repo root clean.

---

### Task 1: Feature catalog, machines registry, and flake refactor

**Files:**
- Create: `features.nix`
- Create: `machines.nix`
- Modify: `flake.nix` (whole file rewrite)

**Interfaces:**
- Consumes: existing flake inputs (`nixpkgs`, `home-manager`, `dldev`) and existing modules (`./home.nix`, `./modules/aoe2.nix`).
- Produces:
  - `features.nix` returns an attrset with keys `base`, `dldev`, `aoe2`, each a list of modules.
  - `machines.nix` returns an attrset mapping hostname (string) → list of feature name strings.
  - `flake.nix` exposes `homeConfigurations.<hostname>` for every entry in `machines.nix`.

This task is atomic — the three files must land in one commit or the flake won't evaluate.

- [ ] **Step 1: Create `features.nix`**

Create `features.nix` with exact content:

```nix
{ dldev, ... }:
{
  base  = [ ./home.nix ];
  dldev = [ dldev.homeModules.default ];
  aoe2  = [ ./modules/aoe2.nix ];
}
```

- [ ] **Step 2: Determine the current machine's hostname**

Run: `hostname`

Record the output as `$CURRENT_HOSTNAME` for the next step. It will be used as the sole key in `machines.nix`. This machine previously used the `#personal` profile, so its feature list is `[ "base" "dldev" "aoe2" ]`.

- [ ] **Step 3: Create `machines.nix`**

Substitute `<HOSTNAME>` in the template below with the exact output of `hostname` from Step 2. Do not include a trailing dot or comment.

Create `machines.nix` with content:

```nix
{
  "<HOSTNAME>" = [ "base" "dldev" "aoe2" ];
}
```

- [ ] **Step 4: Rewrite `flake.nix`**

Replace the entire content of `flake.nix` with:

```nix
{
  description = "dlangevi home-manager config";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    dldev = {
      url = "path:/home/dlangevi/auto/dldev";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, home-manager, dldev, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      username = builtins.getEnv "USER";
      homeDirectory = builtins.getEnv "HOME";

      features = import ./features.nix { inherit dldev; };
      machines = import ./machines.nix;

      mkHome = featureNames: home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = builtins.concatMap (name: features.${name}) featureNames;
        extraSpecialArgs = { inherit username homeDirectory; };
      };
    in
    {
      homeConfigurations =
        builtins.mapAttrs (_: featureNames: mkHome featureNames) machines;
    };
}
```

- [ ] **Step 5: Verify the flake still evaluates**

Run: `nix flake check --impure`

Expected: exits 0. If eval errors appear, fix them before continuing — do not commit a broken flake.

- [ ] **Step 6: Verify the current machine's activation package builds**

Run: `nix build --impure ".#homeConfigurations.\"$(hostname)\".activationPackage" --no-link --print-out-paths`

Expected: prints a `/nix/store/...` path with no errors. This is the same activation package that `home-manager switch` would build.

- [ ] **Step 7: Commit**

```bash
git add features.nix machines.nix flake.nix
git commit -m "refactor: replace named profiles with per-hostname feature composition"
```

- [ ] **Step 8: Activate the new config once, to confirm end-to-end**

Run: `home-manager switch --impure --flake ".#$(hostname)"`

Expected: switch succeeds; no user-visible change in the environment (the module list is equivalent to the previous `#personal` profile).

If this fails, do not proceed. Diagnose and fix before Task 2.

---

### Task 2: `bootstrap` script and `scripts/machines-write.nix` helper

**Files:**
- Create: `scripts/machines-write.nix`
- Create: `bootstrap` (executable)

**Interfaces:**
- Consumes: `features.nix`, `machines.nix`, and `flake.nix` from Task 1. The current commit's `hostname` entry in `machines.nix`.
- Produces: an executable `./bootstrap` with two subcommands (`init`, `upgrade`) whose exact semantics are documented in the spec.

- [ ] **Step 1: Create `scripts/machines-write.nix`**

Create the directory and file:

```bash
mkdir -p scripts
```

Create `scripts/machines-write.nix` with exact content:

```nix
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
```

- [ ] **Step 2: Verify the helper file parses**

Run:
```bash
nix eval --impure --raw --expr '
  import ./scripts/machines-write.nix {
    machines = { };
    host = "test-host";
    features = [ "base" "dldev" ];
  }
'
```

Expected output (exactly this, with the final newline):
```
{
  "test-host" = [ "base" "dldev" ];
}
```

- [ ] **Step 3: Verify the helper handles alphabetical sort and merges**

Run:
```bash
nix eval --impure --raw --expr '
  import ./scripts/machines-write.nix {
    machines = { "zeta" = [ "base" ]; "alpha" = [ "base" "dldev" ]; };
    host = "middle";
    features = [ "base" ];
  }
'
```

Expected output:
```
{
  "alpha" = [ "base" "dldev" ];
  "middle" = [ "base" ];
  "zeta" = [ "base" ];
}
```

- [ ] **Step 4: Create `bootstrap` script**

Create `bootstrap` at the repo root with exact content:

```bash
#!/usr/bin/env bash
set -euo pipefail

# TODO(bootstrap-nix): install Nix if not present. Currently the script
# assumes `nix` is on PATH.

usage() {
  cat <<'EOF'
Usage:
  ./bootstrap init                Register this machine (interactive)
  ./bootstrap upgrade             home-manager switch for this machine
  ./bootstrap upgrade --update    Also run 'nix flake update' first
EOF
}

require_nix() {
  if ! command -v nix >/dev/null; then
    echo "nix is not installed. Install Nix first (see README) and re-run." >&2
    exit 1
  fi
}

require_flake_root() {
  if [[ ! -f flake.nix ]]; then
    echo "Run this from the home-manager repo root." >&2
    exit 1
  fi
}

get_hostname() {
  local h
  h=$(hostname)
  if [[ "$h" == *\"* || "$h" == *\\* || "$h" == *$'\n'* ]]; then
    echo "Hostname \"$h\" contains invalid characters (quote, backslash, or newline)." >&2
    exit 1
  fi
  printf '%s' "$h"
}

machine_registered() {
  local host=$1 result
  result=$(nix eval --impure --json --file machines.nix \
    --apply "x: builtins.hasAttr \"$host\" x")
  [[ "$result" == "true" ]]
}

machine_features() {
  local host=$1
  nix eval --impure --raw --file machines.nix \
    --apply "x: builtins.concatStringsSep \" \" x.\"$host\""
}

feature_catalog() {
  nix eval --impure --raw --file features.nix \
    --apply 'f:
      let attrs = f { dldev = null; };
      in builtins.concatStringsSep "\n" (builtins.attrNames attrs)'
}

do_init() {
  require_nix
  require_flake_root
  local host
  host=$(get_hostname)

  if machine_registered "$host"; then
    local existing
    existing=$(machine_features "$host")
    echo "$host is already registered as [ $existing ]." >&2
    echo "Use ./bootstrap upgrade to apply changes, or edit machines.nix to modify the feature list." >&2
    exit 1
  fi

  local features=("base")
  local feat answer
  # `|| [[ -n "$feat" ]]` handles feature_catalog's final line lacking a
  # trailing newline (nix eval --raw emits the string as-is).
  while IFS= read -r feat || [[ -n "$feat" ]]; do
    [[ -z "$feat" ]] && continue
    [[ "$feat" == "base" ]] && continue
    read -r -p "Include $feat? [y/N]: " answer </dev/tty
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      features+=("$feat")
    fi
  done < <(feature_catalog)

  local features_nix=""
  local f
  for f in "${features[@]}"; do
    features_nix+="\"$f\" "
  done

  local new_content
  new_content=$(nix eval --impure --raw --expr "
    import ./scripts/machines-write.nix {
      machines = import ./machines.nix;
      host = \"$host\";
      features = [ $features_nix];
    }
  ")
  printf '%s' "$new_content" > machines.nix

  local feature_list="${features[*]}"
  git add machines.nix
  git commit -m "chore: register $host with features $feature_list"

  if ! home-manager switch --impure --flake ".#$host"; then
    echo "Registration committed but switch failed. Fix the issue and run './bootstrap upgrade'," >&2
    echo "or undo with 'git reset --soft HEAD~1'." >&2
    exit 1
  fi
  echo "Registered. Run 'git push' when ready."
}

do_upgrade() {
  local do_update=0
  if [[ $# -ge 1 ]]; then
    if [[ "$1" == "--update" ]]; then
      do_update=1
    else
      usage >&2
      exit 2
    fi
  fi
  require_nix
  require_flake_root
  local host
  host=$(get_hostname)
  if ! machine_registered "$host"; then
    echo "$host is not registered. Run './bootstrap init' first." >&2
    exit 1
  fi
  if [[ $do_update -eq 1 ]]; then
    nix flake update
  fi
  home-manager switch --impure --flake ".#$host"
}

case "${1:-}" in
  init)
    shift
    do_init "$@"
    ;;
  upgrade)
    shift
    do_upgrade "$@"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
```

- [ ] **Step 5: Make the script executable**

Run: `chmod +x bootstrap`

- [ ] **Step 6: Static-check with shellcheck**

Run: `nix run nixpkgs#shellcheck -- bootstrap`

Expected: exit 0 with no output. If shellcheck flags any issues, fix them before committing.

- [ ] **Step 7: Verify usage output**

Run: `./bootstrap`

Expected: prints the usage message to stderr and exits 2.

Run: `./bootstrap foo`

Expected: prints the usage message to stderr and exits 2.

- [ ] **Step 8: Verify `init` refuses on already-registered machine**

The current machine was registered in Task 1, so `init` must refuse.

Run: `./bootstrap init`

Expected: prints
```
<hostname> is already registered as [ base dldev aoe2 ].
Use ./bootstrap upgrade to apply changes, or edit machines.nix to modify the feature list.
```
to stderr and exits 1. No file changes.

- [ ] **Step 9: Verify `upgrade` on this machine**

Run: `./bootstrap upgrade`

Expected: `home-manager switch --impure --flake ".#$(hostname)"` runs and completes successfully. Same activation package as Task 1 Step 8.

- [ ] **Step 10: Verify `upgrade` rejects unknown flags**

Run: `./bootstrap upgrade --nonsense`

Expected: prints usage to stderr and exits 2.

- [ ] **Step 11: (Do NOT run) Verify `upgrade --update` semantics manually**

Do NOT actually run `./bootstrap upgrade --update` — the plan explicitly bans touching `flake.lock`. Instead, inspect the script and confirm that `--update` triggers `nix flake update` before `home-manager switch`. This is a code-review verification, not a runtime one.

- [ ] **Step 12: Commit**

```bash
git add scripts/machines-write.nix bootstrap
git commit -m "feat: add bootstrap CLI for machine registration and upgrades"
```

---

### Task 3: Replace the `hms` alias in `modules/zsh.nix`

**Files:**
- Modify: `modules/zsh.nix:22`

**Interfaces:**
- Consumes: the `bootstrap` script from Task 2.
- Produces: an `hms` alias that delegates to `./bootstrap upgrade`.

- [ ] **Step 1: Update the alias**

In `modules/zsh.nix`, replace the line:

```nix
      hms = ''nix flake update dldev --flake ~/.config/home-manager 2>/dev/null; home-manager switch --extra-experimental-features "nix-command flakes" --flake ~/.config/home-manager#dev'';
```

with:

```nix
      hms = ''~/.config/home-manager/bootstrap upgrade'';
```

Leave the other aliases (`tmac`, `as-deploy`) and every other line in the file unchanged.

- [ ] **Step 2: Apply the change**

Run: `./bootstrap upgrade`

Expected: switch succeeds, home-manager reloads shell config.

- [ ] **Step 3: Verify the alias in a fresh shell**

Run: `zsh -i -c 'alias hms'`

Expected output (single line):
```
hms='~/.config/home-manager/bootstrap upgrade'
```

- [ ] **Step 4: Commit**

```bash
git add modules/zsh.nix
git commit -m "chore(zsh): point hms alias at bootstrap upgrade"
```

---

### Task 4: Rewrite the README setup and updating sections

**Files:**
- Modify: `README.md` (Setup on WSL, Setup on NixOS, Updating sections)

**Interfaces:**
- Consumes: `bootstrap init` / `bootstrap upgrade` (Task 2).
- Produces: a README where the documented flow matches reality.

- [ ] **Step 1: Rewrite the "Setup on WSL" section (steps 5-8)**

Locate the block that starts at "### 5. Clone this repo" and ends before "## Setup on NixOS". Replace it with:

```markdown
### 5. Clone this repo

```bash
# Back up any default config home-manager already generated
mv ~/.config/home-manager ~/.config/home-manager.default 2>/dev/null || true

git clone git@github.com:dlangevi/home-manager.git ~/.config/home-manager
cd ~/.config/home-manager
```

### 6. Register this machine and apply

```bash
./bootstrap init
```

`init` will:

- Ask yes/no for each optional feature (`base` is always on).
- Write your machine's entry to `machines.nix`.
- Commit the registration.
- Run the first `home-manager switch`.

After it finishes, push the registration commit:

```bash
git push
```

### 7. Set zsh as default shell

```bash
command -v zsh | sudo tee -a /etc/shells
chsh -s "$(command -v zsh)"
```

### 8. Local secrets

Create `~/.zshenv.local` for machine-specific environment variables (not tracked by git):

```bash
export ASANA_TOKEN="your-token-here"
```
```

- [ ] **Step 2: Rewrite the "Setup on NixOS" section**

Locate the block that starts at "## Setup on NixOS" and ends before "## Updating". Replace with:

```markdown
## Setup on NixOS

On NixOS, Nix is already installed. Start from step 5 of the WSL setup (Clone this repo).

If home-manager is already installed as a NixOS module, remove it from the system config first — this flake uses standalone mode.
```

- [ ] **Step 3: Rewrite the "Updating" section**

Locate the block that starts at "## Updating" and ends before "## Neovim config". Replace with:

```markdown
## Updating

Everyday:

```bash
./bootstrap upgrade
```

Refresh pinned inputs first (nixpkgs, home-manager, dldev), then switch:

```bash
./bootstrap upgrade --update
```

`nix flake update` writes to `flake.lock`; commit it with a follow-up commit if you want the update to persist across machines:

```bash
git add flake.lock
git commit -m "chore: refresh flake inputs"
git push
```
```

- [ ] **Step 4: Delete obsolete channel-based instructions**

Locate the "### 3. Add channels" and "### 4. Install home-manager" sections. These reference `nix-channel` and `nix-shell '<home-manager>'`, which are no longer used by this flake-based setup. Delete both sections entirely; renumber the remaining steps so the sequence in "Setup on WSL" reads 1, 2, 3, 4, 5, 6.

Concretely, after deletion the "Setup on WSL" step order becomes:
1. Install WSL
2. Install Nix
3. Clone this repo (was 5)
4. Register this machine and apply (was 6)
5. Set zsh as default shell (was 7)
6. Local secrets (was 8)

Update the step numbers and headings accordingly. Leave the "### 1. Install WSL" and "### 2. Install Nix" sections untouched.

- [ ] **Step 5: Verify the README renders sensibly**

Run: `head -80 README.md`

Skim for numbering consistency and dangling references. Confirm no mention of `#dev`, `#base`, `#personal`, or the `nix-channel` workflow remains.

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "docs: update README for bootstrap-based setup and upgrades"
```

---

## Self-Review Notes

- **Spec coverage:**
  - `features.nix` shape + catalog contents → Task 1 Step 1.
  - `machines.nix` shape, empty-attrset requirement → Task 1 Step 3 (populated) + spec constraint honored by the `mkHome` composition (empty attrset yields no configs).
  - `flake.nix` refactor with `mkHome` / `mapAttrs` → Task 1 Step 4.
  - `bootstrap init` steps 1-10 from spec → Task 2 `do_init` in Step 4 code block.
  - `bootstrap upgrade` steps 1-6 from spec → Task 2 `do_upgrade` in Step 4 code block.
  - Hostname validation for quote/backslash/newline → Task 2 `get_hostname`.
  - `--impure` everywhere → applied in every `nix eval`, `nix build`, `home-manager switch` invocation.
  - `hms` alias replacement → Task 3.
  - Nix bootstrap TODO comment → Task 2 Step 4 header comment.
  - Verification list from spec → covered by Task 1 Steps 5-8 and Task 2 Steps 6-10.
  - Optional store-path equivalence check → available via Task 1 Step 6's `--print-out-paths`. Not gating; user can compare against a pre-refactor build if they had one on hand.

- **Placeholder scan:** the only TODO in the plan is the deliberate one from the spec (`bootstrap-nix`), embedded in the script header comment and covered explicitly by Non-goals in the spec. No TBDs elsewhere.

- **Type consistency:** function argument names (`x`, `f`, `k`, `fs`) inside `--apply` lambdas and `machines-write.nix` are consistent. Feature name strings (`"base"`, `"dldev"`, `"aoe2"`) match verbatim between `features.nix` and `machines.nix`. `machine_registered` returns 0 on registered / 1 on unregistered (bash convention); `do_init` and `do_upgrade` both branch on it correctly.
