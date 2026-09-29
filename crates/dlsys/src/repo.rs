//! Locating the flake checkout.
//!
//! The bash dlsys answered this by `cd`-ing to its own directory, which is
//! why modules/base.nix had to install it as an out-of-store symlink -- a
//! store copy would have resolved to /nix/store, where there is no flake.nix
//! and no git. A store-installed binary cannot use that trick, so the path is
//! a convention instead.

use anyhow::{anyhow, Result};
use std::path::PathBuf;

/// `DLSYS_FLAKE` wins; otherwise `~/.config/home-manager`, which CLAUDE.md
/// already declares the single source of truth for all configuration.
///
/// Deliberately *not* "walk up from cwd looking for flake.nix". That would
/// make `dlsys switch`, run from inside some unrelated flake, do something
/// confident and wrong -- and this tool reconfigures the machine.
pub fn flake_dir() -> Result<PathBuf> {
    if let Some(dir) = std::env::var_os("DLSYS_FLAKE") {
        return Ok(PathBuf::from(dir));
    }
    let home = std::env::var_os("HOME")
        .ok_or_else(|| anyhow!("neither DLSYS_FLAKE nor HOME is set; cannot locate the flake"))?;
    Ok(PathBuf::from(home).join(".config/home-manager"))
}

/// Fails early with a clear message rather than letting nix report a missing
/// flake from a directory the user never mentioned.
pub fn require_flake(dir: &std::path::Path) -> Result<()> {
    if dir.join("flake.nix").is_file() {
        return Ok(());
    }
    Err(anyhow!(
        "no flake.nix in {} -- set DLSYS_FLAKE if the repo lives elsewhere",
        dir.display()
    ))
}
