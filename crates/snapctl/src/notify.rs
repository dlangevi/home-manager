//! Desktop feedback for the hotkey case.
//!
//! A key bound to `snapctl volume dance +5` has no terminal, so without this
//! the only confirmation is the speakers themselves -- which is useless for
//! the client in the *other* room, the exact case this tool exists for.
//!
//! notify-send rather than a D-Bus crate: it is one process spawn on a path
//! already wrapped onto PATH by the derivation in flake.nix, against three
//! dependencies and an async runtime for the same effect.

use anyhow::{Context, Result};
use std::process::Command;

pub fn send(client: &str, what: &str, percent: Option<i64>) -> Result<()> {
    let mut cmd = Command::new("notify-send");
    cmd.arg("--app-name=snapcast")
        .arg("--expire-time=1500")
        .arg("--icon=audio-volume-high")
        // Plasma replaces rather than stacks notifications sharing this hint,
        // so holding a volume key down leaves one notification updating in
        // place instead of a column of them.
        .arg("-h")
        .arg("string:x-canonical-private-synchronous:snapctl");

    // Plasma renders this as a progress bar, the same way its own volume OSD
    // looks. Only meaningful for the commands that have a percentage.
    if let Some(p) = percent {
        cmd.arg("-h").arg(format!("int:value:{p}"));
    }

    cmd.arg(client).arg(what);

    let status = cmd.status().context("running notify-send")?;
    if !status.success() {
        // Not fatal: the volume change already happened, and a missing
        // notification daemon should not make the command look failed.
        eprintln!("snapctl: notify-send exited with {status}");
    }
    Ok(())
}
