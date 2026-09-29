//! Build the two layers and activate the ones that moved.

use anyhow::{anyhow, Result};
use std::path::Path;

use crate::runner::{Output, Runner};
use crate::Target;

/// Which layers to act on.
#[derive(Copy, Clone, Debug, Default, PartialEq, Eq)]
pub struct Layers {
    pub hm: bool,
    pub nixos: bool,
}

impl Layers {
    pub fn none(&self) -> bool {
        !self.hm && !self.nixos
    }

    /// `"hm nixos"`, for the `==> changed:` line.
    pub fn label(&self) -> String {
        let mut v = Vec::new();
        if self.hm {
            v.push("hm");
        }
        if self.nixos {
            v.push("nixos");
        }
        v.join(" ")
    }
}

/// What is live right now, per layer. Empty when the layer has never been
/// activated on this host -- a fresh machine, or home-manager's first run --
/// which callers must treat as "differs".
#[derive(Clone, Debug, Default)]
pub struct Current {
    pub hm: String,
    pub nixos: String,
}

impl Current {
    pub fn read() -> Self {
        let deref = |p: &str| {
            std::fs::canonicalize(p)
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_default()
        };
        let home = std::env::var("HOME").unwrap_or_default();
        Current {
            hm: deref(&format!(
                "{home}/.local/state/home-manager/gcroots/current-home"
            )),
            nixos: deref("/run/current-system"),
        }
    }
}

/// Resolve an explicitly named target.
///
/// An explicit target stays a command, not a suggestion: `dlsys switch nixos`
/// re-switches even when the built system matches, which is what you want
/// when activation itself is the point -- a unit to restart, a stale
/// generation to re-link.
pub fn resolve_explicit(target: Target) -> Layers {
    match target {
        Target::Hm => Layers {
            hm: true,
            nixos: false,
        },
        Target::Nixos => Layers {
            hm: false,
            nixos: true,
        },
        Target::All => Layers {
            hm: true,
            nixos: true,
        },
        Target::Auto => Layers::default(),
    }
}

/// Compare built store paths against what is live.
///
/// Answering "what changed" by building both and comparing paths is exact: it
/// catches a flake.lock bump that only moves one layer, and skips a nixos/
/// edit that evaluates to the system already running. Deciding from changed
/// file paths instead can do neither. The build is not wasted -- the switch
/// that follows reuses it from the store.
pub fn changed(built_hm: &str, built_nixos: Option<&str>, current: &Current) -> Layers {
    Layers {
        hm: built_hm != current.hm,
        nixos: match built_nixos {
            Some(b) => b != current.nixos,
            None => false,
        },
    }
}

fn hm_attr(host: &str) -> String {
    format!(".#homeConfigurations.\"{host}\".activationPackage")
}

fn nixos_attr(host: &str) -> String {
    format!(".#nixosConfigurations.\"{host}\".config.system.build.toplevel")
}

fn build_out(runner: &dyn Runner, dir: &Path, attr: &str) -> Result<Output> {
    runner.capture(
        "nix",
        &["build", "--impure", "--no-link", "--print-out-paths", attr],
        dir,
    )
}

/// Build both layers concurrently and report which differ.
///
/// Concurrency is load-bearing, not incidental. Each layer is a separate
/// single-threaded nix eval costing ~9.5s on suspense (the NixOS module
/// fixpoint is ~11.5M thunks); nix's evaluator cannot use more than one core
/// and its eval cache does not cover deep config.* paths, so the only
/// parallelism available is separate processes. Measured: 18.97s serial ->
/// 9.39s concurrent for a no-op switch.
pub fn detect(
    runner: &dyn Runner,
    dir: &Path,
    host: &str,
    is_nixos: bool,
    current: &Current,
) -> Result<Layers> {
    let hm_a = hm_attr(host);
    let nixos_a = nixos_attr(host);

    eprintln!("==> checking home-manager layer");
    if is_nixos {
        eprintln!("==> checking nixos layer");
    }

    let (hm_res, nixos_res) = std::thread::scope(|s| {
        let hm = s.spawn(|| build_out(runner, dir, &hm_a));
        let nixos = is_nixos.then(|| s.spawn(|| build_out(runner, dir, &nixos_a)));
        (
            hm.join().expect("home-manager build thread panicked"),
            nixos.map(|h| h.join().expect("nixos build thread panicked")),
        )
    });

    let hm = hm_res?;
    if !hm.ok {
        return Err(anyhow!(
            "building the home-manager layer failed; nothing was switched"
        ));
    }
    let nixos = match nixos_res {
        Some(r) => {
            let o = r?;
            if !o.ok {
                return Err(anyhow!("building the nixos layer failed; nothing was switched"));
            }
            Some(o.stdout)
        }
        None => None,
    };

    Ok(changed(&hm.stdout, nixos.as_deref(), current))
}

/// Is this a NixOS host? Matches the bash test exactly.
pub fn is_nixos_host() -> bool {
    Path::new("/etc/nixos/configuration.nix").is_file()
        || Path::new("/run/current-system/nixos-version").exists()
}

/// Invoke home-manager via `nix run .#home-manager`.
///
/// Not the `home-manager` on PATH: this way the script works on a fresh
/// machine that only has nix, and stays pinned to the version in flake.lock
/// even when a stale binary is installed.
pub fn hm(runner: &dyn Runner, dir: &Path, args: &[&str]) -> Result<bool> {
    let mut a = vec!["run", "--impure", ".#home-manager", "--"];
    a.extend_from_slice(args);
    runner.run("nix", &a, dir)
}

/// Refresh flake inputs, excluding nixpkgs-ollama.
///
/// Ollama's derivation triggers a multi-hour CUDA rebuild for sm_61 (the
/// Pascal GTX 1060 in suspense), so pinning its input means routine updates
/// hit the store cache. Bump it by hand with
/// `nix flake update nixpkgs-ollama`.
pub fn update_inputs(runner: &dyn Runner, dir: &Path) -> Result<()> {
    let out = runner.capture(
        "nix",
        &[
            "eval",
            "--raw",
            "--file",
            "flake.nix",
            "--apply",
            "f: builtins.concatStringsSep \" \" \
             (builtins.filter (n: n != \"nixpkgs-ollama\") \
             (builtins.attrNames f.inputs))",
        ],
        dir,
    )?;
    if !out.ok {
        return Err(anyhow!("could not read the flake's input list"));
    }
    let inputs: Vec<&str> = out.stdout.split_whitespace().collect();
    let mut args = vec!["flake", "update"];
    args.extend_from_slice(&inputs);
    if !runner.run("nix", &args, dir)? {
        return Err(anyhow!("nix flake update failed"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runner::FakeRunner;
    use std::path::PathBuf;

    fn cur(hm: &str, nixos: &str) -> Current {
        Current {
            hm: hm.to_string(),
            nixos: nixos.to_string(),
        }
    }

    #[test]
    fn nothing_changed_when_both_match() {
        let l = changed("/nix/store/a", Some("/nix/store/b"), &cur("/nix/store/a", "/nix/store/b"));
        assert!(l.none());
    }

    #[test]
    fn only_the_layer_that_moved_is_reported() {
        let l = changed("/nix/store/NEW", Some("/nix/store/b"), &cur("/nix/store/a", "/nix/store/b"));
        assert_eq!(l, Layers { hm: true, nixos: false });

        let l = changed("/nix/store/a", Some("/nix/store/NEW"), &cur("/nix/store/a", "/nix/store/b"));
        assert_eq!(l, Layers { hm: false, nixos: true });
    }

    /// A non-NixOS host has no system layer to compare, and must never be
    /// told to run nixos-rebuild.
    #[test]
    fn non_nixos_host_never_reports_the_nixos_layer() {
        let l = changed("/nix/store/NEW", None, &cur("/nix/store/a", "/run/current-system"));
        assert_eq!(l, Layers { hm: true, nixos: false });
    }

    /// A layer that has never been activated reads as empty, which must count
    /// as changed -- otherwise a fresh machine would decide it is up to date
    /// and switch nothing.
    #[test]
    fn never_activated_layer_counts_as_changed() {
        let l = changed("/nix/store/a", Some("/nix/store/b"), &cur("", ""));
        assert_eq!(l, Layers { hm: true, nixos: true });
    }

    #[test]
    fn explicit_targets_ignore_what_changed() {
        assert_eq!(resolve_explicit(Target::Hm), Layers { hm: true, nixos: false });
        assert_eq!(resolve_explicit(Target::Nixos), Layers { hm: false, nixos: true });
        assert_eq!(resolve_explicit(Target::All), Layers { hm: true, nixos: true });
    }

    #[test]
    fn label_lists_changed_layers() {
        assert_eq!(Layers { hm: true, nixos: true }.label(), "hm nixos");
        assert_eq!(Layers { hm: false, nixos: true }.label(), "nixos");
        assert_eq!(Layers::default().label(), "");
    }

    #[test]
    fn detect_builds_both_layers() {
        let f = FakeRunner::new(&[
            ("homeConfigurations", Output::out("/nix/store/hm-new")),
            ("nixosConfigurations", Output::out("/nix/store/sys-same")),
        ]);
        let l = detect(
            &f,
            &PathBuf::from("/repo"),
            "suspense",
            true,
            &cur("/nix/store/hm-old", "/nix/store/sys-same"),
        )
        .unwrap();
        assert_eq!(l, Layers { hm: true, nixos: false });

        let calls = f.calls();
        assert_eq!(calls.len(), 2, "both layers should be built: {calls:?}");
        assert!(calls.iter().any(|c| c.contains("homeConfigurations")));
        assert!(calls.iter().any(|c| c.contains("nixosConfigurations")));
        // Every nix invocation needs --impure: the flake reads $USER/$HOME.
        assert!(calls.iter().all(|c| c.contains("--impure")), "{calls:?}");
    }

    #[test]
    fn detect_skips_the_nixos_layer_on_a_non_nixos_host() {
        let f = FakeRunner::new(&[("homeConfigurations", Output::out("/nix/store/hm"))]);
        detect(&f, &PathBuf::from("/repo"), "wsl", false, &cur("/nix/store/hm", "")).unwrap();
        let calls = f.calls();
        assert_eq!(calls.len(), 1, "{calls:?}");
        assert!(!calls[0].contains("nixosConfigurations"));
    }

    /// A failed build must abort before anything is activated. The bash
    /// version's equivalent bug would have been switching a half-built
    /// config.
    #[test]
    fn detect_fails_loudly_when_a_build_fails() {
        let f = FakeRunner::new(&[("homeConfigurations", Output::fail())]);
        let err = detect(&f, &PathBuf::from("/repo"), "suspense", true, &cur("", ""))
            .unwrap_err()
            .to_string();
        assert!(err.contains("nothing was switched"), "{err}");
    }

    #[test]
    fn update_inputs_excludes_nixpkgs_ollama() {
        let f = FakeRunner::new(&[(
            "--apply",
            Output::out("nixpkgs home-manager dl-herd plasma-manager"),
        )]);
        update_inputs(&f, &PathBuf::from("/repo")).unwrap();
        let update = f.calls().into_iter().find(|c| c.contains("flake update")).unwrap();
        assert!(!update.contains("nixpkgs-ollama"), "{update}");
        assert!(update.contains("dl-herd"), "{update}");
    }
}
