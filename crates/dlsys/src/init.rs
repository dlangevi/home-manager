//! Register this machine in `machines.nix`.

use anyhow::{anyhow, Result};
use std::io::Write;
use std::path::Path;

use crate::machines;
use crate::runner::Runner;
use crate::switch;

/// Asking the user yes/no, or for a line of free-form text. A trait so
/// `init`'s selection logic can be tested without a terminal.
///
/// `ask` has a default body that refuses: most `Prompt` impls (rollout's
/// `Always`, the feature-selection `ScriptedPrompt` below) only ever need
/// `confirm`, and giving `ask` a default means adding it here does not force
/// every existing implementor to grow a method it has no use for.
pub trait Prompt {
    fn confirm(&self, question: &str) -> Result<bool>;

    fn ask(&self, _question: &str) -> Result<String> {
        Err(anyhow!("this prompt cannot ask for free-form input"))
    }
}

/// Reads from the real terminal.
///
/// Explicitly /dev/tty, not stdin: `dlsys init` may be reached through
/// `bootstrap.sh`, and a bare stdin read would silently consume whatever the
/// caller piped in rather than asking a human.
pub struct TtyPrompt;

impl Prompt for TtyPrompt {
    fn confirm(&self, question: &str) -> Result<bool> {
        use std::io::{BufRead, BufReader};
        let tty = std::fs::File::open("/dev/tty")
            .map_err(|e| anyhow!("init needs a terminal to ask about features: {e}"))?;
        print!("{question} [y/N]: ");
        std::io::stdout().flush()?;
        let mut line = String::new();
        BufReader::new(tty).read_line(&mut line)?;
        Ok(matches!(line.trim(), "y" | "Y"))
    }

    fn ask(&self, question: &str) -> Result<String> {
        use std::io::{BufRead, BufReader};
        let tty = std::fs::File::open("/dev/tty")
            .map_err(|e| anyhow!("init needs a terminal to ask a question: {e}"))?;
        print!("{question} ");
        std::io::stdout().flush()?;
        let mut line = String::new();
        BufReader::new(tty).read_line(&mut line)?;
        Ok(line.trim().to_string())
    }
}

/// Make sure `git commit` has an identity to stamp commits with.
///
/// `git config --get` reads the merged local+global+system config, so this
/// only prompts when neither already supplies a value -- it does not fight an
/// identity set some other way. The common gap is a brand-new machine: Nix,
/// home-manager and this repo clone fine with no git identity at all, and the
/// first `dlsys init` is the first command here that actually needs one.
fn git_config_get(runner: &dyn Runner, dir: &Path, key: &str) -> Result<Option<String>> {
    let out = runner.capture("git", &["config", "--get", key], dir)?;
    Ok((out.ok && !out.stdout.is_empty()).then_some(out.stdout))
}

pub fn ensure_git_identity(runner: &dyn Runner, dir: &Path, prompt: &dyn Prompt) -> Result<()> {
    if git_config_get(runner, dir, "user.name")?.is_none() {
        let name = prompt.ask("No git user.name configured. Name for commits:")?;
        if !runner.run("git", &["config", "--global", "user.name", &name], dir)? {
            return Err(anyhow!("git config --global user.name failed"));
        }
    }
    if git_config_get(runner, dir, "user.email")?.is_none() {
        let email = prompt.ask("No git user.email configured. Email for commits:")?;
        if !runner.run("git", &["config", "--global", "user.email", &email], dir)? {
            return Err(anyhow!("git config --global user.email failed"));
        }
    }
    Ok(())
}

/// Is `git@github.com` reachable with whatever key ssh would offer it?
///
/// `git ls-remote` over ssh, not a bare `ssh -T`: GitHub's SSH endpoint never
/// grants a shell, so a *successful* `ssh -T` auth still exits non-zero and
/// only says so in a greeting on stderr -- which `Runner::capture` does not
/// even collect (it inherits stderr so nix's progress output keeps reaching
/// the terminal). `ls-remote` against a real repo exits 0 on success and
/// non-zero on auth failure, so it fits the existing `ok`-only seam exactly,
/// and it is a closer proxy for what's actually about to happen: fetching
/// dl-herd as a flake input.
fn github_ssh_authenticated(runner: &dyn Runner, dir: &Path) -> bool {
    runner
        .capture("git", &["ls-remote", "git@github.com:dlangevi/dl-herd.git"], dir)
        .map(|o| o.ok)
        .unwrap_or(false)
}

/// Make sure this machine can fetch the private flake inputs (dl-herd and any
/// other `git+ssh://git@github.com/...` input) before `init` tries to.
///
/// A brand-new machine has Nix and a repo clone but no SSH identity GitHub
/// has seen before, so the first `nix build`/`home-manager switch` that
/// touches those inputs fails with a bare "Permission denied (publickey)" and
/// no hint about what to do. This generates a key if none exists, prints it,
/// and waits for the human to add it at github.com/settings/ssh/new before
/// letting init proceed to the switch that needs it.
pub fn ensure_github_ssh(runner: &dyn Runner, dir: &Path, prompt: &dyn Prompt) -> Result<()> {
    if github_ssh_authenticated(runner, dir) {
        return Ok(());
    }

    let home = std::env::var("HOME").map_err(|_| anyhow!("HOME is not set"))?;
    let key_path = format!("{home}/.ssh/id_ed25519");
    let pub_path = format!("{key_path}.pub");

    if !Path::new(&pub_path).exists() {
        std::fs::create_dir_all(format!("{home}/.ssh"))
            .map_err(|e| anyhow!("could not create ~/.ssh: {e}"))?;
        let label = prompt.ask("No SSH key found. Label for the new key (e.g. your email):")?;
        if !runner.run(
            "ssh-keygen",
            &["-t", "ed25519", "-C", &label, "-f", &key_path, "-N", ""],
            dir,
        )? {
            return Err(anyhow!("ssh-keygen failed"));
        }
    }

    let pubkey = std::fs::read_to_string(&pub_path)
        .map_err(|e| anyhow!("could not read {pub_path}: {e}"))?;

    loop {
        println!(
            "\nAdd this key at https://github.com/settings/ssh/new, then continue:\n\n{}\n",
            pubkey.trim()
        );
        if !prompt.confirm("Added it to GitHub?")? {
            return Err(anyhow!(
                "GitHub SSH access not confirmed; fetching private flake inputs (dl-herd) will fail"
            ));
        }
        if github_ssh_authenticated(runner, dir) {
            return Ok(());
        }
        println!("Still not authenticating as git@github.com.");
    }
}

/// Which features to register, given the catalog and an answer for each.
///
/// `base` is always included and never asked about -- every machine has it.
/// Order follows the catalog so the written entry is stable.
pub fn select_features(catalog: &[String], prompt: &dyn Prompt) -> Result<Vec<String>> {
    let mut chosen = vec!["base".to_string()];
    for feat in catalog {
        if feat == "base" {
            continue;
        }
        if prompt.confirm(&format!("Include {feat}?"))? {
            chosen.push(feat.clone());
        }
    }
    Ok(chosen)
}

/// Pull `system.stateVersion` out of a generated `configuration.nix`.
///
/// Looks for an uncommented `system.stateVersion = "...";` line --
/// nixos-generate-config always emits this, never commented out, which is
/// why a plain `strip_prefix` search (no regex dependency) is enough.
fn extract_state_version(configuration_nix: &str) -> Option<String> {
    configuration_nix.lines().find_map(|line| {
        let line = line.trim();
        let rest = line.strip_prefix("system.stateVersion")?.trim_start();
        let rest = rest.strip_prefix('=')?.trim_start();
        let rest = rest.strip_prefix('"')?;
        let end = rest.find('"')?;
        Some(rest[..end].to_string())
    })
}

/// Copy this machine's detected hardware facts into the repo, verbatim.
///
/// Disk UUIDs and kernel modules can't be templated -- there is nothing to
/// generate here, only to copy. Mirrors the migration CLAUDE.md already
/// documents by hand for `nixos/hardware/<host>.nix`.
fn ensure_nixos_hardware_file(dir: &Path, host: &str) -> Result<Option<String>> {
    let src = Path::new("/etc/nixos/hardware-configuration.nix");
    if !src.is_file() {
        return Ok(None);
    }
    let dst_dir = dir.join("nixos/hardware");
    let dst = dst_dir.join(format!("{host}.nix"));
    if dst.exists() {
        return Ok(None);
    }
    std::fs::create_dir_all(&dst_dir)
        .map_err(|e| anyhow!("could not create {}: {e}", dst_dir.display()))?;
    std::fs::copy(src, &dst)
        .map_err(|e| anyhow!("could not copy {} to {}: {e}", src.display(), dst.display()))?;
    Ok(Some(format!("nixos/hardware/{host}.nix")))
}

/// Seed `nixos/hosts/<host>.nix` -- not a copy, a minimal starting point.
///
/// `nixosConfigurations.<host>` (flake.nix's `mkNixos`) hard-requires this
/// file to exist, with no `/etc/nixos` fallback the way the hardware module
/// has one, so a fresh NixOS install needs *something* here before the first
/// `dlsys switch nixos`. The only two facts every host file actually needs
/// -- confirmed by diffing all three committed ones against
/// `nixos/common.nix` -- are the hostname (already known: it's `host`) and
/// stateVersion (never in common.nix, must come from the real machine, must
/// never be guessed or bumped). Everything else in a stock generated
/// `configuration.nix` either duplicates common.nix already or is installer
/// boilerplate with no home in this repo; every real host file was
/// hand-grown from something this small, not trimmed down from something
/// large, so that is the shape to generate too.
fn ensure_nixos_host_file(dir: &Path, host: &str) -> Result<Option<String>> {
    let dst = dir.join("nixos/hosts").join(format!("{host}.nix"));
    if dst.exists() {
        return Ok(None);
    }
    let generated = std::fs::read_to_string("/etc/nixos/configuration.nix").ok();
    let state_version = generated.as_deref().and_then(extract_state_version).ok_or_else(|| {
        anyhow!(
            "could not find system.stateVersion in /etc/nixos/configuration.nix; \
             create nixos/hosts/{host}.nix by hand before running 'dlsys switch nixos'"
        )
    })?;

    let dst_dir = dir.join("nixos/hosts");
    std::fs::create_dir_all(&dst_dir)
        .map_err(|e| anyhow!("could not create {}: {e}", dst_dir.display()))?;
    let contents = format!(
        "{{ ... }}:\n\n{{\n  networking.hostName = \"{host}\";\n  system.stateVersion = \"{state_version}\";\n}}\n"
    );
    std::fs::write(&dst, contents).map_err(|e| anyhow!("could not write {}: {e}", dst.display()))?;
    Ok(Some(format!("nixos/hosts/{host}.nix")))
}

/// Set up this NixOS machine's repo-tracked config, if it is not there
/// already -- a generated minimal `hosts/<host>.nix` plus a verbatim-copied
/// `hardware/<host>.nix`. No-op on a non-NixOS machine.
fn ensure_nixos_host_files(dir: &Path, host: &str) -> Result<Vec<String>> {
    if !switch::is_nixos_host() {
        return Ok(Vec::new());
    }

    let mut added = Vec::new();
    added.extend(ensure_nixos_host_file(dir, host)?);
    added.extend(ensure_nixos_hardware_file(dir, host)?);

    if !added.is_empty() {
        println!("Wrote NixOS config for {host}: {}", added.join(", "));
    }
    Ok(added)
}

pub fn run(runner: &dyn Runner, dir: &Path, host: &str, prompt: &dyn Prompt) -> Result<()> {
    crate::repo::require_flake(dir)?;
    ensure_git_identity(runner, dir, prompt)?;

    let existing = machines::load(runner, dir)?;
    if let Some(features) = existing.get(host) {
        return Err(anyhow!(
            "{host} is already registered as [ {} ].\n\
             Use 'dlsys switch' to apply changes, or edit machines.nix to modify the feature list.",
            features.join(" ")
        ));
    }

    let catalog = machines::feature_catalog(runner, dir)?;
    let features = select_features(&catalog, prompt)?;

    // Edit the file's text rather than regenerating it from the evaluated
    // attrset -- see machines::insert_host for why that matters here.
    let path = dir.join("machines.nix");
    let current = std::fs::read_to_string(&path)
        .map_err(|e| anyhow!("could not read {}: {e}", path.display()))?;
    let updated = machines::insert_host(&current, host, &features);
    std::fs::write(&path, &updated)
        .map_err(|e| anyhow!("could not write {}: {e}", path.display()))?;

    let nixos_files = ensure_nixos_host_files(dir, host)?;
    let mut add_args: Vec<&str> = vec!["add", "machines.nix"];
    add_args.extend(nixos_files.iter().map(String::as_str));
    if !runner.run("git", &add_args, dir)? {
        return Err(anyhow!("git add machines.nix failed"));
    }
    let msg = format!("chore: register {host} with features {}", features.join(" "));
    if !runner.run("git", &["commit", "-m", &msg], dir)? {
        return Err(anyhow!("git commit failed"));
    }

    ensure_github_ssh(runner, dir, prompt)?;

    let flake = format!(".#{host}");
    if !switch::hm(runner, dir, &["switch", "--impure", "--flake", &flake])? {
        return Err(anyhow!(
            "Registration committed but switch failed. Fix the issue and run 'dlsys switch',\n\
             or undo with 'git reset --soft HEAD~1'."
        ));
    }
    println!("Registered. Run 'git push' when ready.");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runner::{FakeRunner, Output};
    use std::path::PathBuf;
    use std::sync::Mutex;

    #[test]
    fn extract_state_version_reads_a_normal_generated_line() {
        let generated = "{ config, lib, pkgs, ... }:\n{\n  system.stateVersion = \"24.11\";\n}\n";
        assert_eq!(extract_state_version(generated), Some("24.11".to_string()));
    }

    #[test]
    fn extract_state_version_ignores_a_trailing_comment() {
        let generated = "system.stateVersion = \"23.11\"; # Did you read the comment?\n";
        assert_eq!(extract_state_version(generated), Some("23.11".to_string()));
    }

    #[test]
    fn extract_state_version_tolerates_extra_whitespace() {
        let generated = "  system.stateVersion   =   \"25.05\"  ;\n";
        assert_eq!(extract_state_version(generated), Some("25.05".to_string()));
    }

    #[test]
    fn extract_state_version_is_none_when_absent() {
        let generated = "{ config, ... }:\n{\n  networking.hostName = \"nixos\";\n}\n";
        assert_eq!(extract_state_version(generated), None);
    }

    #[test]
    fn extract_state_version_ignores_a_commented_out_line() {
        let generated = "# system.stateVersion = \"24.11\";\n";
        assert_eq!(extract_state_version(generated), None);
    }

    /// Answers `true` for the named features, `false` for everything else,
    /// and records what it was asked.
    struct ScriptedPrompt {
        yes: Vec<String>,
        asked: Mutex<Vec<String>>,
    }

    impl ScriptedPrompt {
        fn new(yes: &[&str]) -> Self {
            Self {
                yes: yes.iter().map(|s| s.to_string()).collect(),
                asked: Mutex::new(Vec::new()),
            }
        }
    }

    impl Prompt for ScriptedPrompt {
        fn confirm(&self, question: &str) -> Result<bool> {
            self.asked.lock().unwrap().push(question.to_string());
            Ok(self.yes.iter().any(|y| question.contains(y.as_str())))
        }
    }

    fn catalog() -> Vec<String> {
        ["base", "dev", "gaming", "herd"]
            .iter()
            .map(|s| s.to_string())
            .collect()
    }

    #[test]
    fn base_is_always_included_and_never_asked_about() {
        let p = ScriptedPrompt::new(&[]);
        let got = select_features(&catalog(), &p).unwrap();
        assert_eq!(got, vec!["base"]);
        assert!(
            !p.asked.lock().unwrap().iter().any(|q| q.contains("base")),
            "base must not be offered as a choice"
        );
    }

    #[test]
    fn selected_features_follow_catalog_order() {
        let p = ScriptedPrompt::new(&["herd", "dev"]);
        assert_eq!(
            select_features(&catalog(), &p).unwrap(),
            vec!["base", "dev", "herd"]
        );
    }

    /// A throwaway directory that looks enough like the repo to get past
    /// `require_flake`. Named by test so concurrent tests do not collide.
    fn temp_repo(name: &str, machines_nix: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("dlsys-test-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("flake.nix"), "{}").unwrap();
        std::fs::write(dir.join("machines.nix"), machines_nix).unwrap();
        dir
    }

    /// Re-registering must refuse rather than overwrite the existing entry.
    #[test]
    fn refuses_a_host_that_is_already_registered() {
        let dir = temp_repo("already", "{\n  \"suspense\" = [ \"base\" \"dev\" ];\n}\n");
        let f = FakeRunner::new(&[
            ("machines.nix", Output::out(r#"{"suspense":["base","dev"]}"#)),
            ("config --get user.name", Output::out("Test User")),
            ("config --get user.email", Output::out("test@example.com")),
        ]);
        let p = ScriptedPrompt::new(&[]);
        let err = run(&f, &dir, "suspense", &p).unwrap_err().to_string();

        assert!(err.contains("already registered"), "{err}");
        assert!(err.contains("base dev"), "{err}");
        // Nothing was committed, and the file is untouched.
        assert!(!f.calls().iter().any(|c| c.contains("commit")), "{:?}", f.calls());
        assert_eq!(
            std::fs::read_to_string(dir.join("machines.nix")).unwrap(),
            "{\n  \"suspense\" = [ \"base\" \"dev\" ];\n}\n"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The end-to-end shape of a successful registration: the file gains the
    /// new host, keeps the old ones verbatim, and the commit message names
    /// the chosen features.
    #[test]
    fn registers_a_new_host_without_disturbing_the_file() {
        let original = concat!(
            "{\n",
            "  \"console\"  = [ \"base\" ];\n",
            "  # keep me\n",
            "  \"suspense\" = [ \"base\" \"dev\" ];\n",
            "}\n"
        );
        let dir = temp_repo("register", original);
        let f = FakeRunner::new(&[
            ("--file machines.nix", Output::out(r#"{"console":["base"],"suspense":["base","dev"]}"#)),
            ("--file features.nix", Output::out(r#"["base","dev","gaming"]"#)),
            ("config --get user.name", Output::out("Test User")),
            ("config --get user.email", Output::out("test@example.com")),
        ]);
        let p = ScriptedPrompt::new(&["gaming"]);

        run(&f, &dir, "dusk", &p).unwrap();

        let written = std::fs::read_to_string(dir.join("machines.nix")).unwrap();
        assert!(written.contains("  \"console\"  = [ \"base\" ];"), "{written}");
        assert!(written.contains("  # keep me"), "{written}");
        assert!(written.contains("  \"dusk\" = [ \"base\" \"gaming\" ];"), "{written}");
        // Sorted between console and suspense.
        assert!(written.find("console").unwrap() < written.find("dusk").unwrap());
        assert!(written.find("dusk").unwrap() < written.find("suspense").unwrap());

        let calls = f.calls();
        assert!(calls.iter().any(|c| c.contains("git add machines.nix")), "{calls:?}");
        assert!(
            calls.iter().any(|c| c.contains("register dusk with features base gaming")),
            "{calls:?}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
