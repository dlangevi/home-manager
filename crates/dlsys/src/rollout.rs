//! Run `switch auto` on every managed machine, one at a time.

use anyhow::{anyhow, Result};
use std::path::Path;

use crate::init::Prompt;
use crate::machines;
use crate::runner::Runner;
use crate::switch;

/// Upgrade order. suspense first: it runs the snapcast/music server that
/// dance's snapclient connects to.
pub const DEFAULT_ORDER: &[&str] = &["suspense", "dance", "console"];

/// host -> ssh destination. `console` is deliberately absent from the map's
/// usable set in practice -- it is unreachable from the tailnet and upgraded
/// by hand -- but it is listed so a `--order` naming it fails with the right
/// message rather than a generic one.
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

/// Gather the git facts, then hand them to [`classify`].
///
/// Every verdict goes through `classify` so the tests covering it are
/// testing what actually runs, rather than a parallel reimplementation.
fn inspect(runner: &dyn Runner, dir: &Path) -> Result<RepoState> {
    let porcelain = git(runner, dir, &["status", "--porcelain"])?;
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
    match inspect(runner, dir)? {
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

        match inspect(runner, repo)? {
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

    let total = hosts.len();
    for (i, host) in hosts.iter().enumerate() {
        println!("\n==> [{}/{}] {}", i + 1, total, host);
        let ok = if host == self_host {
            switch_self().is_ok()
        } else {
            let target = ssh_target(host).expect("validated by resolve_hosts");
            runner.run("ssh", &["-t", target, remote_command()], dir)?
        };
        if !ok {
            let remaining: Vec<&str> = hosts[i + 1..].iter().map(|s| s.as_str()).collect();
            eprintln!("FAILED on {host}.");
            if !remaining.is_empty() {
                eprintln!("Not attempted: {}", remaining.join(" "));
            }
            return Err(anyhow!("rollout aborted at {host}"));
        }
    }

    println!("\nUpgraded: {}", hosts.join(" "));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runner::{FakeRunner, Output};
    use std::collections::BTreeMap;
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
        let f = FakeRunner::new(&[("status --porcelain", Output::out(" M modules/base.nix"))]);
        let err = require_clean_repo(&f, &PathBuf::from("/repo")).unwrap_err().to_string();
        assert!(err.contains("uncommitted changes"), "{err}");
        // It must not have gone on to fetch or compare.
        assert!(!f.calls().iter().any(|c| c.contains("fetch")), "{:?}", f.calls());
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
}
