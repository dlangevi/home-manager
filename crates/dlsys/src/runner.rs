//! The seam between dlsys's decision logic and the commands it shells out to.
//!
//! Every `nix`, `git`, `ssh`, `sudo` and `nixos-rebuild` invocation goes
//! through `Runner`. That exists so the interesting logic -- which layers
//! changed, whether a rollout is safe to start -- can be unit-tested against
//! `FakeRunner` without touching the real system. The bash version had no such
//! seam, which is why none of its safety checks were ever tested.

use anyhow::{anyhow, Result};
use std::path::Path;
use std::process::{Command, Stdio};

// Only FakeRunner needs these, and it is test-only.
#[cfg(test)]
use std::collections::VecDeque;
#[cfg(test)]
use std::sync::Mutex;

/// A finished command. `ok` is the exit status; `stdout` is trimmed because
/// every caller here wants a store path, a git rev or a hostname, never
/// trailing whitespace.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Output {
    pub ok: bool,
    pub stdout: String,
}

/// Implementors must be `Send + Sync`: `switch` builds both layers on separate
/// threads, and both share one runner.
pub trait Runner: Send + Sync {
    /// Run and capture stdout. stderr is inherited so nix's progress output
    /// still reaches the terminal.
    fn capture(&self, program: &str, args: &[&str], cwd: &Path) -> Result<Output>;

    /// Run with all three streams inherited, for interactive or
    /// progress-heavy commands whose output we do not parse.
    fn run(&self, program: &str, args: &[&str], cwd: &Path) -> Result<bool>;
}

pub struct RealRunner;

impl Runner for RealRunner {
    fn capture(&self, program: &str, args: &[&str], cwd: &Path) -> Result<Output> {
        let out = Command::new(program)
            .args(args)
            .current_dir(cwd)
            .stderr(Stdio::inherit())
            .output()
            .map_err(|e| anyhow!("failed to run `{program}`: {e}"))?;
        Ok(Output {
            ok: out.status.success(),
            stdout: String::from_utf8_lossy(&out.stdout).trim().to_string(),
        })
    }

    fn run(&self, program: &str, args: &[&str], cwd: &Path) -> Result<bool> {
        let status = Command::new(program)
            .args(args)
            .current_dir(cwd)
            .status()
            .map_err(|e| anyhow!("failed to run `{program}`: {e}"))?;
        Ok(status.success())
    }
}

/// Records what was asked of it and replays canned answers.
///
/// Answers are consumed in order. An empty queue means "succeeded, printed
/// nothing", which keeps tests that only care about *which* commands ran from
/// having to enumerate output for all of them.
#[cfg(test)]
pub struct FakeRunner {
    calls: Mutex<Vec<String>>,
    answers: Mutex<VecDeque<Output>>,
}

#[cfg(test)]
impl FakeRunner {
    pub fn new(answers: Vec<Output>) -> Self {
        Self {
            calls: Mutex::new(Vec::new()),
            answers: Mutex::new(answers.into()),
        }
    }

    /// Every command run so far, as `"program arg arg"`, in order.
    pub fn calls(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
    }

    fn record(&self, program: &str, args: &[&str]) -> Output {
        let mut line = String::from(program);
        for a in args {
            line.push(' ');
            line.push_str(a);
        }
        self.calls.lock().unwrap().push(line);
        self.answers
            .lock()
            .unwrap()
            .pop_front()
            .unwrap_or(Output {
                ok: true,
                stdout: String::new(),
            })
    }
}

#[cfg(test)]
impl Runner for FakeRunner {
    fn capture(&self, program: &str, args: &[&str], _cwd: &Path) -> Result<Output> {
        Ok(self.record(program, args))
    }

    fn run(&self, program: &str, args: &[&str], _cwd: &Path) -> Result<bool> {
        Ok(self.record(program, args).ok)
    }
}
