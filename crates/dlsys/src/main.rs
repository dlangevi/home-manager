//! dlsys -- apply this flake's home-manager and NixOS layers.
//!
//! Replaces the 565-line bash script of the same name. See CLAUDE.md for why:
//! the script parsed structured data out of `nix eval`, orchestrated
//! concurrency by hand, and pushed command strings through ssh, none of which
//! bash does safely.

mod machines;
mod repo;
mod runner;

use anyhow::Result;
use clap::{Parser, Subcommand};

/// A fresh Nix ships with flakes off, so the very first `dlsys init` on a new
/// machine would die with "experimental Nix feature 'nix-command' is
/// disabled" before it could write the nix.conf that enables them. Appended
/// last so it wins over any inherited NIX_CONFIG. Carried over verbatim from
/// the bash version's dlsys:10-21.
fn enable_flakes_for_child_nix() {
    const LINE: &str = "extra-experimental-features = nix-command flakes";
    let value = match std::env::var("NIX_CONFIG") {
        Ok(existing) if !existing.is_empty() => format!("{existing}\n{LINE}"),
        _ => LINE.to_string(),
    };
    std::env::set_var("NIX_CONFIG", value);
}

#[derive(Parser)]
#[command(
    name = "dlsys",
    about = "Apply this flake's home-manager and NixOS layers",
    disable_help_subcommand = true
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Register this machine (interactive)
    Init,

    /// Build and activate the layers that changed
    Switch {
        /// Which layer to switch. `auto` switches only what differs.
        #[arg(value_enum, default_value_t = Target::Auto)]
        target: Target,

        /// Refresh flake inputs first (excludes nixpkgs-ollama)
        #[arg(long)]
        update: bool,

        /// `git pull --ff-only` this checkout before building
        #[arg(long)]
        pull: bool,
    },

    /// Run `switch auto` on every managed machine
    Rollout {
        /// Explicit host order (comma-separated; may be a subset)
        #[arg(long, value_delimiter = ',')]
        order: Option<Vec<String>>,

        /// Refresh flake inputs once locally, commit and push, then upgrade
        #[arg(long)]
        update: bool,
    },
}

#[derive(Copy, Clone, PartialEq, Eq, clap::ValueEnum)]
enum Target {
    /// Build both layers, switch only those whose store path differs
    Auto,
    /// home-manager only
    Hm,
    /// nixos-rebuild only
    Nixos,
    /// Both, unconditionally
    All,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Init => todo!("init"),
        Command::Switch { .. } => todo!("switch"),
        Command::Rollout { .. } => todo!("rollout"),
    }
}
