//! dlsys -- apply this flake's home-manager and NixOS layers.
//!
//! Replaces the 565-line bash script of the same name. See CLAUDE.md for why:
//! the script parsed structured data out of `nix eval`, orchestrated
//! concurrency by hand, and pushed command strings through ssh, none of which
//! bash does safely.

mod init;
mod machines;
mod repo;
mod rollout;
mod runner;
mod switch;

use anyhow::{anyhow, Result};
use clap::{Parser, Subcommand};
use runner::{RealRunner, Runner};
use std::path::Path;

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
pub enum Target {
    /// Build both layers, switch only those whose store path differs
    Auto,
    /// home-manager only
    Hm,
    /// nixos-rebuild only
    Nixos,
    /// Both, unconditionally
    All,
}

/// This machine's hostname, via the `hostname` command rather than a Linux
/// procfs read, so a non-NixOS macOS or WSL install works the same way.
///
/// The bash version validated this against quotes, backslashes and newlines
/// because it interpolated the result into a nix expression. Nothing here
/// does that any more -- machines.nix is read as JSON -- so the hostname is
/// only ever compared or used as a process argument.
fn hostname(runner: &dyn Runner, dir: &Path) -> Result<String> {
    let out = runner.capture("hostname", &[], dir)?;
    if !out.ok || out.stdout.is_empty() {
        return Err(anyhow!("could not determine this machine's hostname"));
    }
    Ok(out.stdout)
}

fn do_switch(
    runner: &dyn Runner,
    dir: &Path,
    target: Target,
    update: bool,
    pull: bool,
) -> Result<()> {
    repo::require_flake(dir)?;

    if pull {
        // Refuse to pull onto local edits: --pull exists to deploy what is
        // upstream, and a merge you have not seen is not that.
        let dirty = !runner.capture("git", &["status", "--porcelain"], dir)?.stdout.is_empty();
        if dirty {
            return Err(anyhow!(
                "working tree has uncommitted changes; --pull refuses to pull on top of them"
            ));
        }
        println!("==> git pull --ff-only");
        if !runner.run("git", &["pull", "--ff-only"], dir)? {
            return Err(anyhow!("git pull --ff-only failed"));
        }
    }

    let host = hostname(runner, dir)?;
    let machines = machines::load(runner, dir)?;
    if !machines.contains_key(&host) {
        return Err(anyhow!("{host} is not registered. Run 'dlsys init' first."));
    }

    if update {
        switch::update_inputs(runner, dir)?;
    }

    let is_nixos = switch::is_nixos_host();

    let layers = if target == Target::Auto {
        let current = switch::Current::read();
        let l = switch::detect(runner, dir, &host, is_nixos, &current)?;
        if l.none() {
            println!("Already up to date; nothing to switch.");
            return Ok(());
        }
        println!("==> changed: {}", l.label());
        l
    } else {
        switch::resolve_explicit(target)
    };

    if layers.nixos {
        if !is_nixos {
            return Err(anyhow!(
                "this host is not NixOS -- the 'nixos' target is unavailable"
            ));
        }
        println!("==> nixos-rebuild switch --flake .#{host}");
        let flake = format!(".#{host}");
        if !runner.run(
            "sudo",
            &["nixos-rebuild", "switch", "--flake", &flake, "--impure"],
            dir,
        )? {
            return Err(anyhow!("nixos-rebuild switch failed"));
        }
    }

    if layers.hm {
        println!("==> home-manager switch --flake .#{host}");
        let flake = format!(".#{host}");
        if !switch::hm(runner, dir, &["switch", "--impure", "--flake", &flake])? {
            return Err(anyhow!("home-manager switch failed"));
        }
    }

    Ok(())
}

fn main() -> Result<()> {
    enable_flakes_for_child_nix();
    let cli = Cli::parse();
    let runner = RealRunner;
    let dir = repo::flake_dir()?;

    match cli.command {
        Command::Init => {
            let host = hostname(&runner, &dir)?;
            init::run(&runner, &dir, &host, &init::TtyPrompt)
        }
        Command::Switch {
            target,
            update,
            pull,
        } => do_switch(&runner, &dir, target, update, pull),
        Command::Rollout { order, update } => {
            let host = hostname(&runner, &dir)?;
            let dir2 = dir.clone();
            rollout::run(
                &runner,
                &dir,
                order.as_deref(),
                update,
                &host,
                &init::TtyPrompt,
                // This host switches in-process rather than over ssh.
                &|| do_switch(&RealRunner, &dir2, Target::Auto, false, false),
            )
        }
    }
}
