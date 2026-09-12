{ config, lib, pkgs, homeDirectory, ... }:

let
  syncRoot = "${homeDirectory}/Sync/claude";
  link = config.lib.file.mkOutOfStoreSymlink;

  # Wrap `claude` so that starting a session in a new directory immediately
  # creates its memory/ dir under ~/Sync/claude/memory/<key>/ and symlinks
  # ~/.claude/projects/<key>/memory to it. Without this, new-project memories
  # would be written locally first and never sync.
  claudeWrapped = pkgs.symlinkJoin {
    name = "claude-code-wrapped";
    paths = [ pkgs.claude-code ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/claude --run '
        # Only a session launch needs a memory dir. Management subcommands get
        # run from anywhere — agent-session polls `claude agents` every few
        # seconds — and minting a dir for their cwd litters the synced folder.
        case "''${1:-}" in
          agents|mcp|doctor|update|install|plugin|auth|setup-token|gateway|import|project|auto-mode|ultrareview)
            : ;;
          *)
            cwd=$(pwd)
            key=$(printf "%s" "$cwd" | sed "s|[/.]|-|g")
            memSrc="${syncRoot}/memory/$key"
            projDir="${homeDirectory}/.claude/projects/$key"
            memDst="$projDir/memory"
            mkdir -p "$memSrc" "$projDir"
            if [ ! -e "$memDst" ] || [ -L "$memDst" ]; then
              ln -sfn "$memSrc" "$memDst"
            fi
            ;;
        esac
      '
    '';
  };
in
{
  home.packages = [ claudeWrapped ];

  # The wrapper creates (and Syncthing-replicates) a memory dir for its cwd on
  # every invocation, which is wrong for a process that only wants to *read*
  # session state — agent-session's monitor polls `claude agents --json`. Point
  # it at the unwrapped binary.
  home.sessionVariables.AGENT_SESSION_CLAUDE_BIN = "${pkgs.claude-code}/bin/claude";

  home.file.".claude/CLAUDE.md".source     = link "${syncRoot}/CLAUDE.md";
  home.file.".claude/settings.json".source = link "${syncRoot}/settings.json";
  home.file.".claude/commands".source      = link "${syncRoot}/commands";
  # Personal skills, shared across every workspace rather than living in one
  # project's .claude/. The asana skill in particular is needed anywhere the
  # task system comes up, not just in ~/auto/research.
  home.file.".claude/skills".source        = link "${syncRoot}/skills";

  # Backfill on activation for projects that already have a Sync memory dir
  # but no local symlink yet (e.g. after cloning on a fresh machine).
  home.activation.claudeMemoryLinks = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    memRoot="${syncRoot}/memory"
    projRoot="${homeDirectory}/.claude/projects"
    if [ -d "$memRoot" ]; then
      mkdir -p "$projRoot"
      for src in "$memRoot"/*/; do
        [ -d "$src" ] || continue
        key=$(basename "$src")
        dst="$projRoot/$key/memory"
        mkdir -p "$projRoot/$key"
        if [ -L "$dst" ] || [ ! -e "$dst" ]; then
          run ln -sfn "$src" "$dst"
        fi
      done
    fi
  '';
}
