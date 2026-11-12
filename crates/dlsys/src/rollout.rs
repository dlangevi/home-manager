//! Run `switch auto` on every managed machine, one at a time.

use anyhow::{anyhow, Result};
use std::path::Path;

use crate::init::Prompt;
use crate::machines;
use crate::runner::Runner;
use crate::switch;

/// Upgrade order. suspense first: it runs the snapcast/music server that
/// dance's snapclient connects to.
///
/// console used to be excluded here because it was unreachable from the
/// tailnet and a bare `dlsys rollout` would hang on an ssh timeout to it
/// before reporting failure. Now that `run` attempts every host and reports
/// per-host success/failure instead of aborting on the first one, an
/// unreachable console just fails gracefully alongside whatever else
/// succeeded, so it is safe to include unconditionally.
pub const DEFAULT_ORDER: &[&str] = &["suspense", "dance", "console"];

/// host -> ssh destination.
pub fn ssh_target(host: &str) -> Option<&'static str> {
    match host {
        "suspense" => Some("dlangevi@suspense"),
        "dance" => Some("dance@dance"),
        "console" => Some("console@console"),
        _ => None,
    }
}

/// Local tool repos whose code ships through this flake.
///
/// Their working copy is what THIS host builds (see flake.nix's herdLocal
/// preference), but every remote host builds the revision pinned in
/// flake.lock. A rollout from a dirty or unpushed tool repo therefore
/// deploys one thing here and a different, older thing everywhere else --
/// silently. So rollout checks them first.
pub const TOOL_REPOS: &[(&str, &str)] = &[("dl-herd", "/home/dlangevi/auto/dl-herd")];

/// The state of a git checkout, as far as rollout cares.
#[derive(Debug, PartialEq, Eq)]
pub enum RepoState {
    Clean,
    Dirty,
    NoUpstream,
    /// Local is strictly ahead of upstream by this many commits.
    Ahead(u32),
    /// Behind, or rebased -- anything that is not a fast-forward.
    Diverged,
}

/// Classify a checkout from raw git output.
///
/// Split out from the IO so every branch is testable; the bash version's
/// equivalent logic was never covered by anything.
pub fn classify(porcelain: &str, upstream: Option<&str>, head: &str, ahead: Option<u32>) -> RepoState {
    if !porcelain.trim().is_empty() {
        return RepoState::Dirty;
    }
    let Some(upstream) = upstream else {
        return RepoState::NoUpstream;
    };
    if upstream == head {
        return RepoState::Clean;
    }
    match ahead {
        Some(n) if n > 0 => RepoState::Ahead(n),
        _ => RepoState::Diverged,
    }
}

fn git(runner: &dyn Runner, dir: &Path, args: &[&str]) -> Result<String> {
    Ok(runner.capture("git", args, dir)?.stdout)
}

/// What counts as "dirty".
///
/// The bash version was asymmetric here and this preserves that, because the
/// asymmetry is defensible: flakes only ever build *tracked* files, so an
/// untracked file cannot change what gets deployed.
///
///   * This repo -- tracked changes only. Refusing over an untracked stray
///     would block every rollout for a file that cannot affect the build.
///   * Tool repos -- any untracked file too. Stricter on purpose: an
///     untracked source file in dl-herd is almost certainly work in progress
///     that the author believes is being deployed, and it is not.
#[derive(Copy, Clone, PartialEq, Eq)]
pub enum Dirt {
    TrackedOnly,
    IncludeUntracked,
}

fn is_dirty(runner: &dyn Runner, dir: &Path, dirt: Dirt) -> Result<String> {
    match dirt {
        Dirt::IncludeUntracked => git(runner, dir, &["status", "--porcelain"]),
        Dirt::TrackedOnly => {
            // `git diff --quiet` exits non-zero when there are differences.
            let unstaged = !runner.capture("git", &["diff", "--quiet"], dir)?.ok;
            let staged = !runner.capture("git", &["diff", "--cached", "--quiet"], dir)?.ok;
            Ok(if unstaged || staged {
                "tracked changes".to_string()
            } else {
                String::new()
            })
        }
    }
}

/// Gather the git facts, then hand them to [`classify`].
///
/// Every verdict goes through `classify` so the tests covering it are
/// testing what actually runs, rather than a parallel reimplementation.
fn inspect(runner: &dyn Runner, dir: &Path, dirt: Dirt) -> Result<RepoState> {
    let porcelain = is_dirty(runner, dir, dirt)?;
    if !porcelain.trim().is_empty() {
        // Return early rather than fetching: a dirty tree is refused
        // regardless of what origin says, and `git fetch` is the slow part.
        return Ok(classify(&porcelain, None, "", None));
    }

    runner.capture("git", &["fetch", "--quiet", "origin"], dir)?;
    let up = runner.capture("git", &["rev-parse", "--verify", "--quiet", "@{u}"], dir)?;
    let upstream = (up.ok && !up.stdout.is_empty()).then_some(up.stdout);
    let head = git(runner, dir, &["rev-parse", "HEAD"])?;

    // Ahead only when upstream is an ancestor of HEAD; anything else that
    // differs is diverged (behind, or rebased).
    let ahead = match &upstream {
        Some(u) if *u != head => {
            let is_ancestor = runner
                .capture("git", &["merge-base", "--is-ancestor", u, &head], dir)?
                .ok;
            if is_ancestor {
                let range = format!("{u}..{head}");
                Some(
                    git(runner, dir, &["rev-list", "--count", &range])?
                        .trim()
                        .parse()
                        .unwrap_or(1),
                )
            } else {
                None
            }
        }
        _ => None,
    };

    Ok(classify(&porcelain, upstream.as_deref(), &head, ahead))
}

/// This checkout must be clean and match upstream: remote hosts upgrade from
/// the pushed commit, not from what is sitting here.
pub fn require_clean_repo(runner: &dyn Runner, dir: &Path) -> Result<()> {
    match inspect(runner, dir, Dirt::TrackedOnly)? {
        RepoState::Clean => Ok(()),
        RepoState::Dirty => Err(anyhow!(
            "Working tree has uncommitted changes. Commit or stash them first --\n\
             remote hosts upgrade from the pushed commit, not from this checkout."
        )),
        RepoState::NoUpstream => Err(anyhow!("Current branch has no upstream. Push it first.")),
        RepoState::Ahead(_) | RepoState::Diverged => Err(anyhow!(
            "Local branch differs from its upstream. Push (or pull) first so every\n\
             host upgrades the same commit."
        )),
    }
}

/// Refuse to roll out from a dirty tool repo; offer to push an unpushed one.
///
/// A push only changes what origin has -- flake.lock still pins the old
/// revision -- so a successful push is followed by bumping that input, which
/// is what actually gets the new code onto the remote hosts.
pub fn check_tool_repos(runner: &dyn Runner, dir: &Path, prompt: &dyn Prompt) -> Result<()> {
    for (name, path) in TOOL_REPOS {
        let repo = Path::new(path);
        if !repo.join(".git").exists() {
            continue;
        }
        println!("==> checking {name} ({path})");

        match inspect(runner, repo, Dirt::IncludeUntracked)? {
            RepoState::Clean => continue,
            RepoState::Dirty => {
                return Err(anyhow!(
                    "{name} has uncommitted changes. Remote hosts build the pushed\n\
                     revision, so commit and push them before rolling out:\n  git -C {path} status"
                ))
            }
            RepoState::NoUpstream => {
                return Err(anyhow!("{name}'s branch has no upstream. Push it first."))
            }
            RepoState::Diverged => {
                return Err(anyhow!(
                    "{name} has diverged from its upstream (behind, or rebased).\n\
                     Reconcile it by hand before rolling out."
                ))
            }
            RepoState::Ahead(n) => {
                println!("{name} is ahead of origin by {n} commit(s).");
                if !prompt.confirm("Push them now?")? {
                    return Err(anyhow!(
                        "Declined. Remote hosts would get the older pinned revision."
                    ));
                }
                if !runner.run("git", &["push"], repo)? {
                    return Err(anyhow!("pushing {name} failed"));
                }
                // The push moved origin; teach flake.lock about it, or the
                // rollout still deploys the revision it pinned before.
                println!("==> nix flake update {name}");
                if !runner.run("nix", &["flake", "update", name], dir)? {
                    return Err(anyhow!("nix flake update {name} failed"));
                }
                let changed = !git(runner, dir, &["diff", "--quiet", "--", "flake.lock"])?.is_empty()
                    || !runner
                        .capture("git", &["diff", "--exit-code", "--", "flake.lock"], dir)?
                        .ok;
                if changed {
                    let msg = format!("chore: bump {name}");
                    runner.run("git", &["commit", "-q", "flake.lock", "-m", &msg], dir)?;
                    runner.run("git", &["push", "-q"], dir)?;
                    println!("flake.lock bumped to the new {name} revision, committed and pushed.");
                } else {
                    println!("flake.lock already pinned that revision.");
                }
            }
        }
    }
    Ok(())
}

/// Validate the host list before touching anything.
pub fn resolve_hosts(order: Option<&[String]>, registered: &machines::Machines) -> Result<Vec<String>> {
    let hosts: Vec<String> = match order {
        Some(o) => o.to_vec(),
        None => DEFAULT_ORDER.iter().map(|s| s.to_string()).collect(),
    };
    for host in &hosts {
        if host.is_empty() {
            return Err(anyhow!("Empty host in --order list."));
        }
        if !registered.contains_key(host) {
            return Err(anyhow!("{host} is not registered in machines.nix."));
        }
        if ssh_target(host).is_none() {
            return Err(anyhow!(
                "{host} has no ssh target in dlsys's host map. Add one before including it."
            ));
        }
    }
    Ok(hosts)
}

/// The command a remote host runs.
///
/// `./bootstrap.sh`, not `./dlsys`: dlsys is a store binary now, and the
/// remote may not have this revision of it installed yet. bootstrap.sh is in
/// the repo the host just pulled, needs only nix, and execs into the right
/// dlsys -- so no ordering dance is required during the cutover.
pub fn remote_command() -> &'static str {
    "set -e; cd ~/.config/home-manager && git pull --ff-only && ./bootstrap.sh switch auto"
}

#[allow(clippy::too_many_arguments)]
pub fn run(
    runner: &dyn Runner,
    dir: &Path,
    order: Option<&[String]>,
    update: bool,
    self_host: &str,
    prompt: &dyn Prompt,
    switch_self: &dyn Fn() -> Result<()>,
) -> Result<()> {
    crate::repo::require_flake(dir)?;

    let registered = machines::load(runner, dir)?;
    let hosts = resolve_hosts(order, &registered)?;

    require_clean_repo(runner, dir)?;
    check_tool_repos(runner, dir, prompt)?;

    if update {
        println!("==> nix flake update");
        switch::update_inputs(runner, dir)?;
        let unchanged = runner
            .capture("git", &["diff", "--exit-code", "--", "flake.lock"], dir)?
            .ok;
        if unchanged {
            println!("flake.lock unchanged; nothing to push.");
        } else {
            runner.run(
                "git",
                &["commit", "-q", "flake.lock", "-m", "chore: update flake inputs"],
                dir,
            )?;
            runner.run("git", &["push", "-q"], dir)?;
            println!("flake.lock updated, committed and pushed.");
        }
    }

    let (succeeded, failed) = attempt_hosts(runner, dir, &hosts, self_host, switch_self);

    if !succeeded.is_empty() {
        println!("\nUpgraded: {}", succeeded.join(" "));
    }
    if !failed.is_empty() {
        // Deliberately not an error: an unreachable or failing host is
        // skipped, not treated as a rollout failure, so the rest of the
        // fleet still deploys and the command still exits 0.
        eprintln!("Skipped (unreachable or failed): {}", failed.join(" "));
    }
    Ok(())
}

/// Attempt every host in order, never stopping early. A host that is
/// unreachable or fails its switch must not stop the rest of the fleet from
/// upgrading -- failures are collected and reported together at the end.
fn attempt_hosts<'a>(
    runner: &dyn Runner,
    dir: &Path,
    hosts: &'a [String],
    self_host: &str,
    switch_self: &dyn Fn() -> Result<()>,
) -> (Vec<&'a str>, Vec<&'a str>) {
    let total = hosts.len();
    let mut succeeded = Vec::new();
    let mut failed = Vec::new();
    for (i, host) in hosts.iter().enumerate() {
        println!("\n==> [{}/{}] {}", i + 1, total, host);
        let ok = if host == self_host {
            switch_self().is_ok()
        } else {
            let target = ssh_target(host).expect("validated by resolve_hosts");
            runner
                .run("ssh", &["-t", target, remote_command()], dir)
                .unwrap_or(false)
        };
        if ok {
            succeeded.push(host.as_str());
        } else {
            eprintln!("FAILED on {host}.");
            failed.push(host.as_str());
        }
    }
    (succeeded, failed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runner::{FakeRunner, Output};
    use std::collections::BTreeMap;
    use std::fs;
    use std::path::PathBuf;

    struct Always(bool);
    impl Prompt for Always {
        fn confirm(&self, _: &str) -> Result<bool> {
            Ok(self.0)
        }
    }

    fn registered(hosts: &[&str]) -> machines::Machines {
        let mut m = BTreeMap::new();
        for h in hosts {
            m.insert(h.to_string(), vec!["base".to_string()]);
        }
        m
    }

    #[test]
    fn classify_covers_every_state() {
        assert_eq!(classify(" M file", Some("a"), "a", None), RepoState::Dirty);
        assert_eq!(classify("", None, "a", None), RepoState::NoUpstream);
        assert_eq!(classify("", Some("a"), "a", None), RepoState::Clean);
        assert_eq!(classify("", Some("a"), "b", Some(2)), RepoState::Ahead(2));
        assert_eq!(classify("", Some("a"), "b", None), RepoState::Diverged);
    }

    /// Dirtiness outranks everything: a dirty tree is refused even if it is
    /// otherwise in sync.
    #[test]
    fn dirty_wins_over_other_states() {
        assert_eq!(classify("?? new", Some("a"), "a", Some(0)), RepoState::Dirty);
    }

    #[test]
    fn require_clean_repo_refuses_a_dirty_tree() {
        // Tracked change -> `git diff --quiet` exits non-zero.
        let f = FakeRunner::new(&[("diff --quiet", Output::fail())]);
        let err = require_clean_repo(&f, &PathBuf::from("/repo")).unwrap_err().to_string();
        assert!(err.contains("uncommitted changes"), "{err}");
        // It must not have gone on to fetch or compare.
        assert!(!f.calls().iter().any(|c| c.contains("fetch")), "{:?}", f.calls());
    }

    /// This repo ignores untracked files, matching the bash version. Flakes
    /// only build tracked files, so a stray untracked file cannot change
    /// what is deployed -- refusing over one would block every rollout.
    #[test]
    fn require_clean_repo_ignores_untracked_files() {
        let f = FakeRunner::new(&[
            // Both diffs clean; only `status --porcelain` would show the stray.
            ("diff --quiet", Output::out("")),
            ("status --porcelain", Output::out("?? stray.log")),
            ("rev-parse --verify", Output::out("same")),
            ("rev-parse HEAD", Output::out("same")),
        ]);
        require_clean_repo(&f, &PathBuf::from("/repo")).unwrap();
    }

    /// Tool repos are stricter, also matching the bash version: an untracked
    /// source file there is work the author probably thinks is deploying.
    #[test]
    fn tool_repos_do_not_ignore_untracked_files() {
        if !Path::new(TOOL_REPOS[0].1).join(".git").exists() {
            return;
        }
        let f = FakeRunner::new(&[("status --porcelain", Output::out("?? src/new.rs"))]);
        let err = check_tool_repos(&f, &PathBuf::from("/repo"), &Always(true))
            .unwrap_err()
            .to_string();
        assert!(err.contains("uncommitted changes"), "{err}");
    }

    #[test]
    fn require_clean_repo_refuses_an_unpushed_branch() {
        let f = FakeRunner::new(&[
            ("status --porcelain", Output::out("")),
            ("rev-parse --verify", Output::out("upstream-sha")),
            ("rev-parse HEAD", Output::out("local-sha")),
            ("merge-base", Output::out("")),
            ("rev-list --count", Output::out("3")),
        ]);
        let err = require_clean_repo(&f, &PathBuf::from("/repo")).unwrap_err().to_string();
        assert!(err.contains("differs from its upstream"), "{err}");
    }

    #[test]
    fn require_clean_repo_refuses_when_there_is_no_upstream() {
        let f = FakeRunner::new(&[
            ("status --porcelain", Output::out("")),
            ("rev-parse --verify", Output::fail()),
        ]);
        let err = require_clean_repo(&f, &PathBuf::from("/repo")).unwrap_err().to_string();
        assert!(err.contains("no upstream"), "{err}");
    }

    #[test]
    fn require_clean_repo_accepts_a_clean_synced_tree() {
        let f = FakeRunner::new(&[
            ("status --porcelain", Output::out("")),
            ("rev-parse --verify", Output::out("same-sha")),
            ("rev-parse HEAD", Output::out("same-sha")),
        ]);
        require_clean_repo(&f, &PathBuf::from("/repo")).unwrap();
    }

    #[test]
    fn unknown_host_is_rejected_before_anything_runs() {
        let err = resolve_hosts(
            Some(&["nosuchhost".to_string()]),
            &registered(&["suspense"]),
        )
        .unwrap_err()
        .to_string();
        assert!(err.contains("not registered"), "{err}");
    }

    #[test]
    fn registered_host_without_an_ssh_target_is_rejected() {
        let err = resolve_hosts(Some(&["orphan".to_string()]), &registered(&["orphan"]))
            .unwrap_err()
            .to_string();
        assert!(err.contains("no ssh target"), "{err}");
    }

    #[test]
    fn empty_host_in_order_is_rejected() {
        let err = resolve_hosts(Some(&["".to_string()]), &registered(&["suspense"]))
            .unwrap_err()
            .to_string();
        assert!(err.contains("Empty host"), "{err}");
    }

    #[test]
    fn default_order_puts_suspense_before_dance() {
        let hosts = resolve_hosts(None, &registered(&["suspense", "dance", "console"])).unwrap();
        let pos = |h: &str| hosts.iter().position(|x| x == h).unwrap();
        assert!(pos("suspense") < pos("dance"), "{hosts:?}");
    }

    /// console is included by default now that an unreachable host fails
    /// gracefully instead of aborting the rest of the rollout.
    #[test]
    fn default_order_includes_console() {
        let hosts = resolve_hosts(None, &registered(&["suspense", "dance", "console"])).unwrap();
        assert_eq!(hosts, vec!["suspense", "dance", "console"], "{hosts:?}");
    }

    /// Naming it explicitly still works too.
    #[test]
    fn console_can_still_be_named_explicitly() {
        let hosts = resolve_hosts(
            Some(&["console".to_string()]),
            &registered(&["suspense", "console"]),
        )
        .unwrap();
        assert_eq!(hosts, vec!["console"]);
    }

    /// An unreachable or failing host must not stop the rest of the fleet
    /// from upgrading.
    #[test]
    fn a_failed_host_does_not_abort_the_remaining_hosts() {
        struct FailDance;
        impl Runner for FailDance {
            fn capture(&self, _: &str, _: &[&str], _: &Path) -> Result<Output> {
                Ok(Output { ok: true, stdout: String::new() })
            }
            fn run(&self, program: &str, args: &[&str], _: &Path) -> Result<bool> {
                if program == "ssh" && args.iter().any(|a| a.contains("dance")) {
                    return Err(anyhow!("ssh: connection timed out"));
                }
                Ok(true)
            }
        }

        let hosts = vec![
            "dance".to_string(),
            "console".to_string(),
        ];
        let (succeeded, failed) = attempt_hosts(
            &FailDance,
            &PathBuf::from("/repo"),
            &hosts,
            "suspense",
            &|| Ok(()),
        );
        assert_eq!(failed, vec!["dance"], "{failed:?}");
        assert_eq!(succeeded, vec!["console"], "{succeeded:?}");
    }

    /// The local host switches in-process rather than over ssh, and that
    /// path's failure is just as graceful as a remote one's.
    #[test]
    fn self_host_failure_is_also_graceful() {
        let hosts = vec!["suspense".to_string(), "dance".to_string()];
        let (succeeded, failed) = attempt_hosts(
            &FakeRunner::new(&[]),
            &PathBuf::from("/repo"),
            &hosts,
            "suspense",
            &|| Err(anyhow!("local switch failed")),
        );
        assert_eq!(failed, vec!["suspense"], "{failed:?}");
        assert_eq!(succeeded, vec!["dance"], "{succeeded:?}");
    }

    /// A declined push must abort, not silently deploy the older pin to
    /// every remote while this host builds the newer working copy.
    #[test]
    fn declining_to_push_a_tool_repo_aborts() {
        if !Path::new(TOOL_REPOS[0].1).join(".git").exists() {
            return; // no local dl-herd checkout on this machine
        }
        let f = FakeRunner::new(&[
            ("status --porcelain", Output::out("")),
            ("rev-parse --verify", Output::out("up")),
            ("rev-parse HEAD", Output::out("head")),
            ("merge-base", Output::out("")),
            ("rev-list --count", Output::out("2")),
        ]);
        let err = check_tool_repos(&f, &PathBuf::from("/repo"), &Always(false))
            .unwrap_err()
            .to_string();
        assert!(err.contains("Declined"), "{err}");
        assert!(!f.calls().iter().any(|c| c.starts_with("git push")), "{:?}", f.calls());
    }

    #[test]
    fn dirty_tool_repo_aborts_the_rollout() {
        if !Path::new(TOOL_REPOS[0].1).join(".git").exists() {
            return;
        }
        let f = FakeRunner::new(&[("status --porcelain", Output::out(" M src/main.rs"))]);
        let err = check_tool_repos(&f, &PathBuf::from("/repo"), &Always(true))
            .unwrap_err()
            .to_string();
        assert!(err.contains("uncommitted changes"), "{err}");
    }

    /// Remotes must go through bootstrap.sh, not ./dlsys -- the binary may
    /// not be installed there yet.
    #[test]
    fn remote_command_uses_bootstrap_and_pulls_first() {
        let c = remote_command();
        assert!(c.contains("./bootstrap.sh switch auto"), "{c}");
        assert!(c.contains("git pull --ff-only"), "{c}");
        assert!(!c.contains("./dlsys"), "{c}");
        // `set -e` so a failed pull does not go on to switch a stale tree.
        assert!(c.starts_with("set -e;"), "{c}");
    }

    /// End-to-end: `run` itself must not return an error just because one
    /// host was unreachable -- that host is skipped, not a rollout failure.
    #[test]
    fn run_skips_an_unreachable_host_without_erroring() {
        let temp_dir = tempfile::tempdir().unwrap();
        fs::write(temp_dir.path().join("flake.nix"), "").unwrap();

        let f = FakeRunner::new(&[
            (
                "machines.nix",
                Output::out(r#"{"suspense":["base"],"dance":["base"],"console":["base"]}"#),
            ),
            ("status --porcelain", Output::out("")),
            ("rev-parse --verify", Output::out("same")),
            ("rev-parse HEAD", Output::out("same")),
            ("ssh -t dance@dance", Output::fail()),
            ("ssh -t console@console", Output::out("")),
        ]);

        let result = run(
            &f,
            temp_dir.path(),
            None,
            false,
            "suspense",
            &Always(true),
            &|| Ok(()),
        );

        assert!(result.is_ok(), "{result:?}");
        let calls = f.calls();
        assert!(calls.iter().any(|c| c.contains("console@console")), "{calls:?}");
    }
}
