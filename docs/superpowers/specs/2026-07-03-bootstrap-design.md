# Bootstrap script for home-manager

## Purpose

Provide a single `bootstrap` command that (a) registers the current machine
against a per-machine feature list on first use, and (b) applies subsequent
updates. The registration is stored in a git-tracked `machines.nix` so the
choice of features per machine is visible across every clone of the repo.

The existing `hms` zsh alias (hardcoded to `#dev`) is superseded by
`./bootstrap upgrade`.

## Non-goals

- **Bootstrapping Nix itself.** The script assumes `nix` is already on PATH.
  A `# TODO(bootstrap-nix): install Nix if not present` comment is left near
  the top of the script; implementation deferred.
- **Removing or renaming a machine.** Both are done by hand editing
  `machines.nix`.
- **Config validation before commit.** The script does not run
  `nix flake check` before creating the registration commit; the switch step
  will surface eval errors, and the user can `git reset --soft HEAD~1` to
  undo.
- **Cross-platform packaging.** The script is plain bash. It relies on
  `nix`, `git`, `hostname`, and standard POSIX text tools. No `jq`
  dependency — the script uses `nix eval --apply` to extract exactly the
  boolean or string it needs, without JSON parsing in bash.
- **Installing the script onto PATH.** Users invoke it as `./bootstrap` from
  the repo root.

## Architecture

Three files change or appear at the repo root:

```
bootstrap        # bash CLI: `./bootstrap init` and `./bootstrap upgrade`
features.nix     # catalog of feature names -> module lists (imported by flake.nix)
machines.nix     # git-tracked hostname -> feature list
flake.nix        # refactored to import features.nix and machines.nix
```

Existing `homeConfigurations.base` / `.dev` / `.personal` are replaced by
hostname-keyed configurations derived from `machines.nix`.

## Component: `features.nix`

A function of flake inputs, returning an attrset mapping feature name to a
list of modules:

```nix
{ dldev, ... }:
{
  base  = [ ./home.nix ];
  dldev = [ dldev.homeModules.default ];
  aoe2  = [ ./modules/aoe2.nix ];
}
```

- `base` is the always-on feature and is included by every machine
  explicitly (not implicit in the catalog code).
- Adding a new feature backed by an existing flake input: one new key with
  its module list.
- Adding a new feature backed by a new flake input: add the input to
  `flake.nix`, forward it to `features.nix`, add the key.

The bash script reads feature names via lazy evaluation:

```
nix eval --impure --raw --expr \
  'builtins.concatStringsSep "\n" (builtins.attrNames (import ./features.nix { dldev = null; }))'
```

Passing `dldev = null` is safe because `builtins.attrNames` does not force
the module list values. This call is the single source of truth for which
features `init` prompts about.

## Component: `machines.nix`

A flat attrset mapping hostname (as a string, quoted) to a list of feature
names:

```nix
{
  "some-hostname" = [ "base" "dldev" ];
  "gaming-box"    = [ "base" "dldev" "aoe2" ];
}
```

- Entries are sorted alphabetically by hostname to keep diffs clean.
- Values include `base` explicitly so each machine's entry is self-describing.
- The file must be `{ }` (empty attrset) when no machines are registered,
  so a fresh clone still evaluates.

## Component: `flake.nix` (refactored)

```nix
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
```

If a machine names a feature that isn't in the catalog, `builtins.concatMap`
raises a "missing attribute" error at evaluation time, pointing at the bad
name.

## Component: `bootstrap` script

Bash script, executable, at the repo root. Two subcommands.

### `./bootstrap init`

Interactive registration for a new machine.

1. Check `nix --version` exits 0; otherwise print
   `"nix is not installed. Install Nix first (see README) and re-run."`
   and exit 1.
2. Check cwd is the flake root by testing `-f flake.nix`; otherwise print
   `"Run this from the home-manager repo root."` and exit 1.
3. Capture `HOSTNAME=$(hostname)`. Reject if it contains `"`, `\`, or a
   newline; print an actionable error and exit 1.
4. Query `machines.nix` for an existing entry via
   `nix eval --file machines.nix --apply 'x: builtins.hasAttr "'"$HOSTNAME"'" x' --json`,
   which prints `true` or `false`. If `true`, extract the current feature
   list with
   `nix eval --file machines.nix --apply 'x: builtins.concatStringsSep " " x."'"$HOSTNAME"'"' --raw`,
   print
   `"$HOSTNAME is already registered as [<features>]. Use ./bootstrap upgrade
   to apply changes, or edit machines.nix to modify the feature list."` and
   exit 1.
5. Query feature names from `features.nix` (bash pipeline above). Loop over
   every feature that is not `base`, prompt
   `"Include $feature? [y/N]: "`, and collect answers into a bash array.
   `base` is prepended to the resulting list unconditionally.
6. Rewrite `machines.nix` from scratch. The script uses a single
   `nix eval --raw` invocation that reads the existing file, merges in the
   new `"$HOSTNAME" = [ ... ]` entry, sorts hostnames alphabetically, and
   emits the full formatted file content to stdout. The bash script
   redirects this into `machines.nix`. The Nix expression is embedded in
   the script (a short `--apply` lambda). This keeps JSON parsing out of
   bash and makes the diff deterministic.
7. `git add machines.nix && git commit -m "chore: register $HOSTNAME with
   features $FEATURES"` where `$FEATURES` is a space-separated list.
8. Run `home-manager switch --impure --flake ".#$HOSTNAME"`.
9. On success, print `"Registered. Run 'git push' when ready."` and exit 0.
10. On switch failure, print
    `"Registration committed but switch failed. Fix the issue and run
    './bootstrap upgrade', or undo the registration with 'git reset --soft
    HEAD~1'."` and exit with the switch's exit code.

### `./bootstrap upgrade [--update]`

Non-interactive application of the current machine's registered features.

1. Same nix/cwd sanity checks as `init` (steps 1-2).
2. Capture `HOSTNAME=$(hostname)`.
3. Verify `machines.nix` contains a `"$HOSTNAME"` key (same
   `nix eval ... --apply 'x: builtins.hasAttr ...' --json` check as
   `init` step 4). If it prints `false`, print
   `"$HOSTNAME is not registered. Run './bootstrap init' first."` and
   exit 1.
4. If `--update` is present, run `nix flake update`.
5. Run `home-manager switch --impure --flake ".#$HOSTNAME"`.
6. Exit with the switch's exit code.

### Argument handling

- Exactly one subcommand: `init` or `upgrade`. Otherwise print usage and
  exit 2.
- `upgrade --update` is the only supported flag. Any other flag prints
  usage and exits 2.
- No global `--help` flag beyond the usage message printed on unknown
  input.

## Related change: replace the `hms` alias

`modules/zsh.nix` currently defines:

```
hms = ''nix flake update dldev --flake ~/.config/home-manager 2>/dev/null; home-manager switch --extra-experimental-features "nix-command flakes" --flake ~/.config/home-manager#dev'';
```

Replace with:

```
hms = ''~/.config/home-manager/bootstrap upgrade'';
```

The bootstrap script is the single upgrade entry point. If someone wants
`nix flake update` to run too, they use `hms --update`.

## Verification

- `bash -n bootstrap` and `shellcheck bootstrap` both pass.
- `nix flake check --impure` passes with an empty `machines.nix`.
- `nix flake check --impure` passes with a populated `machines.nix`.
- On a machine registered as `[ "base" "dldev" ]`,
  `home-manager switch --impure --flake ".#$(hostname)"` activates
  successfully. Optionally, comparing store paths of
  `.#homeConfigurations.dev.activationPackage` (pre-refactor) against
  `.#homeConfigurations.<hostname>.activationPackage` (post-refactor) is a
  strong equivalence check.
- `./bootstrap init` on an already-registered machine exits 1 with the
  expected message and makes no filesystem or git changes.
- `./bootstrap upgrade` on an unregistered machine exits 1 with the
  expected message.
- `./bootstrap upgrade` on a registered machine invokes exactly the same
  underlying command as manually running
  `home-manager switch --impure --flake ".#$(hostname)"`.

## Risks and trade-offs

- **Committing hostnames publicly.** `machines.nix` will contain every
  machine's hostname in a public repo. Acceptable per the discussion in
  the KeePassXC design; hostnames are not secret.
- **Commit-before-switch ordering.** `init` commits the mapping before
  running the switch. If the switch fails, the user must manually undo
  the commit. Accepted as simpler than atomic rollback.
- **Feature name typos in machines.nix.** Detected at eval time by
  `builtins.concatMap`. A hand-edit that introduces a bad name will
  break `nix flake check` immediately.
- **Existing machines pre-bootstrap.** The refactor removes `#base`,
  `#dev`, `#personal`. Any machine that has not yet run `init` cannot
  `home-manager switch` until it does. Accepted; the current machine
  (dlangevi's box) is the only one affected and will be re-registered
  as part of the rollout.
- **Hostname stability.** If a machine's hostname changes, its entry in
  `machines.nix` becomes stale. User edits the file by hand.
- **`--impure` is required everywhere** because `flake.nix` uses
  `builtins.getEnv` for `USER` and `HOME`. The bootstrap always passes
  `--impure`; users invoking `home-manager` directly must remember it.
