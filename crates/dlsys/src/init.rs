//! Register this machine in `machines.nix`.

use anyhow::{anyhow, Result};
use std::io::Write;
use std::path::Path;

use crate::machines;
use crate::runner::Runner;
use crate::switch;

/// Asking the user yes/no. A trait so `init`'s selection logic can be tested
/// without a terminal.
pub trait Prompt {
    fn confirm(&self, question: &str) -> Result<bool>;
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

pub fn run(runner: &dyn Runner, dir: &Path, host: &str, prompt: &dyn Prompt) -> Result<()> {
    crate::repo::require_flake(dir)?;

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

    if !runner.run("git", &["add", "machines.nix"], dir)? {
        return Err(anyhow!("git add machines.nix failed"));
    }
    let msg = format!("chore: register {host} with features {}", features.join(" "));
    if !runner.run("git", &["commit", "-m", &msg], dir)? {
        return Err(anyhow!("git commit failed"));
    }

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
        let f = FakeRunner::new(&[(
            "machines.nix",
            Output::out(r#"{"suspense":["base","dev"]}"#),
        )]);
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
