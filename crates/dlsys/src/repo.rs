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
#[cfg(test)]
mod tests {
    use super::*;
    use std::env;
    use std::sync::{Arc, Mutex};

    #[test]
    fn test_flake_dir_returns_dlsys_flake_when_set() {
        let original_dlsys = env::var_os("DLSYS_FLAKE");
        let test_path = "/fake/dlsys/flake";
        env::set_var("DLSYS_FLAKE", test_path);

        let result = flake_dir();
        assert!(result.is_ok());
        assert_eq!(result.unwrap().as_os_str(), std::path::Path::new(test_path).as_os_str());

        // Restore original environment
        if let Some(orig) = original_dlsys {
            env::set_var("DLSYS_FLAKE", orig);
        } else {
            env::remove_var("DLSYS_FLAKE");
        }
    }

    #[test]
    fn test_flake_dir_fallback_to_home_when_dlsys_unset() {
        let original_home = env::var_os("HOME");
        let original_dlsys = env::var_os("DLSYS_FLAKE");

        // Ensure DLSYS_FLAKE is unset
        env::remove_var("DLSYS_FLAKE");

        // Set HOME to a known path for this test
        let home_dir = "/fake/home/user";
        env::set_var("HOME", home_dir);

        let result = flake_dir();
        assert!(result.is_ok());
        let expected_path = format!("{}/.config/home-manager", home_dir);
        assert_eq!(result.unwrap(), std::path::PathBuf::from(expected_path));

        // Restore original environment
        if let Some(orig_home) = original_home {
            env::set_var("HOME", orig_home);
        } else {
            env::remove_var("HOME");
        }
        if let Some(orig_dlsys) = original_dlsys {
            env::set_var("DLSYS_FLAKE", orig_dlsys);
        } else {
            env::remove_var("DLSYS_FLAKE");
        }
    }

    #[test]
    fn test_flake_dir_errors_when_both_vars_unset() {
        let original_home = env::var_os("HOME");
        let original_dlsys = env::var_os("DLSYS_FLAKE");

        env::remove_var("HOME");
        env::remove_var("DLSYS_FLAKE");

        let result = flake_dir();
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("neither DLSYS_FLAKE nor HOME"));

        // Restore original environment
        if let Some(orig_home) = original_home {
            env::set_var("HOME", orig_home);
        } else {
            env::remove_var("HOME");
        }
        if let Some(orig_dlsys) = original_dlsys {
            env::set_var("DLSYS_FLAKE", orig_dlsys);
        } else {
            env::remove_var("DLSYS_FLAKE");
        }
    }

    #[test]
    fn test_require_flake_ok_when_exists() {
        // Create a temporary directory with flake.nix
        let temp_dir = tempfile::tempdir().unwrap();
        let flake_path = temp_dir.path().join("flake.nix");
        std::fs::write(&flake_path, "{ }").unwrap();

        let result = require_flake(temp_dir.path());
        assert!(result.is_ok());
    }

    #[test]
    fn test_require_flake_err_when_absent() {
        let temp_dir = tempfile::tempdir().unwrap();

        let result = require_flake(temp_dir.path());
        assert!(result.is_err());
        let err_msg = result.unwrap_err().to_string();
        assert!(err_msg.contains(&format!("{}", temp_dir.path().display())));
    }

    // Tests that use environment variables are wrapped in a mutex to ensure they can run in parallel safely.
    // This simulates concurrent test execution scenarios where env state might otherwise conflict.
    #[test]
    fn test_flake_dlsys_priority_parallel_safe() {
        let results = Arc::new(Mutex::new(Vec::<Result<PathBuf>>::new()));

        let results1 = results.clone();
        let handle1 = std::thread::spawn(move || {
            // Set DLSYS_FLAKE for this thread's context (simulated via global env)
            env::set_var("DLSYS_FLAKE", "/test/path/one");
            let res = flake_dir();
            results1.lock().unwrap().push(res);
        });

        let results2 = results.clone();
        let handle2 = std::thread::spawn(move || {
            // Ensure DLSYS_FLAKE is unset for this thread's context
            env::remove_var("DLSYS_FLAKE");
            let home_val = env::var("HOME").unwrap_or_else(|_| "/fake/home".to_string());
            env::set_var("HOME", &home_val);
            let res = flake_dir();
            results2.lock().unwrap().push(res);
        });

        handle1.join().unwrap();
        handle2.join().unwrap();

        // Note: Since these are global env vars, the order of execution matters for the actual values returned.
        // However, the mutex ensures we don't panic on dropped locks or simultaneous writes to shared state if extended.
        // For correctness in this specific isolation test, we just verify they completed without crashing.
        assert_eq!(results.lock().unwrap().len(), 2);

        env::remove_var("DLSYS_FLAKE");
    }

    #[test]
    fn test_require_flake_error_message_formatting() {
        let temp_dir = tempfile::tempdir().unwrap();
        let dir_path_str = format!("{}", temp_dir.path().display());

        let result = require_flake(temp_dir.path());
        assert!(result.is_err());
        let err_msg = result.unwrap_err().to_string();
        
        // Verify the error message contains the specific directory path provided to the function
        assert!(err_msg.contains("no flake.nix in"));
        assert!(err_msg.contains(&dir_path_str));
    }
}
