//! The machine registry: hostname -> feature list.
//!
//! The bash version ran a separate `nix eval` per question and interpolated
//! the hostname straight into the expression:
//!
//!     nix eval --impure --json --file machines.nix \
//!       --apply "x: builtins.hasAttr \"$host\" x"
//!
//! That is why `get_hostname` had to reject quotes, backslashes and newlines
//! -- a hostname containing one would have been nix code. Reading the whole
//! attrset once as JSON removes both the repeated eval and the injection
//! seam, so no character validation is needed here.

use anyhow::{anyhow, Context, Result};
use std::collections::BTreeMap;
use std::path::Path;

use crate::runner::Runner;

/// hostname -> feature names. `BTreeMap` because `machines.nix` is kept
/// sorted by hostname and `init` has to write it back that way.
pub type Machines = BTreeMap<String, Vec<String>>;

pub fn load(runner: &dyn Runner, dir: &Path) -> Result<Machines> {
    let out = runner.capture(
        "nix",
        &["eval", "--impure", "--json", "--file", "machines.nix"],
        dir,
    )?;
    if !out.ok {
        return Err(anyhow!("could not evaluate machines.nix"));
    }
    serde_json::from_str(&out.stdout).context("machines.nix did not evaluate to hostname -> [feature]")
}

/// The feature catalog, as attribute names of `features.nix`.
///
/// `features.nix` is a function taking the flake inputs it splices into
/// module lists; `init` only needs the attribute *names*, so passing nulls is
/// enough to get the attrset's shape without evaluating any module.
pub fn feature_catalog(runner: &dyn Runner, dir: &Path) -> Result<Vec<String>> {
    let out = runner.capture(
        "nix",
        &[
            "eval",
            "--impure",
            "--json",
            "--file",
            "features.nix",
            "--apply",
            "f: builtins.attrNames (f { dl-herd = null; plasma-manager = null; })",
        ],
        dir,
    )?;
    if !out.ok {
        return Err(anyhow!("could not evaluate features.nix"));
    }
    serde_json::from_str(&out.stdout).context("features.nix did not evaluate to a list of names")
}

/// Add one host to `machines.nix` by editing the text in place.
///
/// NOT a port of `scripts/machines-write.nix`, deliberately. That file
/// regenerates the registry from the evaluated attrset, which throws away
/// everything nix evaluation does not see -- and the committed machines.nix
/// contains exactly two such things:
///
///   * `=` signs hand-aligned into a column
///   * a four-line comment explaining why slskd backs the ingestion queue
///     while Nicotine+ stays on console and suspense
///
/// So the bash `dlsys init` would have silently deleted both the first time
/// it ran on a new machine. Verified by round-tripping the real file through
/// the nix formatter: the comment and the alignment vanish.
///
/// Inserting a line instead preserves the file. The new entry goes before the
/// first host that sorts after it, and before any comment block attached to
/// that host -- a comment sits above the entry it describes, so splitting the
/// two would reattach it to the wrong machine.
pub fn insert_host(existing: &str, host: &str, features: &[String]) -> String {
    let entry = format!("  \"{}\" = [ {}];\n", host, features_str(features));

    let lines: Vec<&str> = existing.lines().collect();
    // Index of the first entry line whose host sorts after `host`.
    let mut target = None;
    for (i, line) in lines.iter().enumerate() {
        if let Some(existing_host) = entry_host(line) {
            if existing_host.as_str() > host {
                target = Some(i);
                break;
            }
        }
    }

    // Back up over the comment block (and blank lines) directly above that
    // entry so it stays with the host it documents.
    let insert_at = match target {
        Some(i) => {
            let mut j = i;
            while j > 0 {
                let prev = lines[j - 1].trim_start();
                if prev.starts_with('#') || prev.is_empty() {
                    j -= 1;
                } else {
                    break;
                }
            }
            j
        }
        // Sorts last: go just before the closing brace.
        None => lines
            .iter()
            .rposition(|l| l.trim() == "}")
            .unwrap_or(lines.len()),
    };

    let mut out = String::new();
    for (i, line) in lines.iter().enumerate() {
        if i == insert_at {
            out.push_str(&entry);
        }
        out.push_str(line);
        out.push('\n');
    }
    if insert_at >= lines.len() {
        out.push_str(&entry);
    }
    out
}

/// The hostname declared by a `  "name" = [ ... ];` line, if it is one.
fn entry_host(line: &str) -> Option<String> {
    let t = line.trim_start();
    let rest = t.strip_prefix('"')?;
    let (name, after) = rest.split_once('"')?;
    // Guard against a stray quoted string that is not an entry.
    after.trim_start().starts_with('=').then(|| name.to_string())
}

fn features_str(features: &[String]) -> String {
    features.iter().map(|f| format!("\"{f}\" ")).collect()
}

/// Render a whole `machines.nix` from scratch.
///
/// Only for the case where the file does not exist yet. For an existing file
/// use [`insert_host`], which does not discard comments or alignment.
/// Kept byte-identical to `scripts/machines-write.nix` (golden test below).
pub fn render(machines: &Machines) -> String {
    let mut s = String::from("{\n");
    for (host, features) in machines {
        s.push_str("  \"");
        s.push_str(host);
        s.push_str("\" = [ ");
        for f in features {
            s.push('"');
            s.push_str(f);
            s.push_str("\" ");
        }
        s.push_str("];\n");
    }
    s.push_str("}\n");
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(pairs: &[(&str, &[&str])]) -> Machines {
        pairs
            .iter()
            .map(|(h, fs)| {
                (
                    h.to_string(),
                    fs.iter().map(|f| f.to_string()).collect::<Vec<_>>(),
                )
            })
            .collect()
    }

    /// Golden output. These strings are what scripts/machines-write.nix
    /// produces today; if this test fails, `init` is about to rewrite
    /// machines.nix in a new format.
    #[test]
    fn render_matches_the_nix_formatter() {
        let got = render(&m(&[
            ("dance", &["base", "streaming"]),
            ("suspense", &["base", "dev"]),
        ]));
        assert_eq!(
            got,
            "{\n  \"dance\" = [ \"base\" \"streaming\" ];\n  \"suspense\" = [ \"base\" \"dev\" ];\n}\n"
        );
    }

    #[test]
    fn render_sorts_hosts_regardless_of_insertion_order() {
        let a = render(&m(&[("zeta", &["base"]), ("alpha", &["base"])]));
        let b = render(&m(&[("alpha", &["base"]), ("zeta", &["base"])]));
        assert_eq!(a, b);
        assert!(a.find("alpha").unwrap() < a.find("zeta").unwrap());
    }

    /// A host with only `base` still renders the trailing space before `]`,
    /// matching the nix formatter's `formatFeatures` + `" ];"`.
    #[test]
    fn render_single_feature() {
        assert_eq!(
            render(&m(&[("console", &["base"])])),
            "{\n  \"console\" = [ \"base\" ];\n}\n"
        );
    }

    /// The committed file, verbatim -- hand-aligned `=` and the slskd comment
    /// block included. These are precisely what regenerating would destroy,
    /// so the fixture has to be the real thing.
    const REAL: &str = concat!(
        "{\n",
        "  \"console\"  = [ \"base\" \"desktop-apps\" \"mpd-client\" ];\n",
        "  \"dance\"    = [ \"base\" \"streaming\" ];\n",
        "  # slskd is the acquisition backend for the ingestion queue --\n",
        "  # Nicotine+ has no API a script could drive.\n",
        "  \"suspense\" = [ \"base\" \"dev\" ];\n",
        "}\n"
    );

    fn feats(fs: &[&str]) -> Vec<String> {
        fs.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn insert_preserves_alignment_and_comments_of_other_entries() {
        let got = insert_host(REAL, "dusk", &feats(&["base"]));
        // Everything that was there is still there, byte for byte.
        assert!(got.contains("  \"console\"  = [ \"base\" \"desktop-apps\" \"mpd-client\" ];"));
        assert!(got.contains("  \"dance\"    = [ \"base\" \"streaming\" ];"));
        assert!(got.contains("  # slskd is the acquisition backend"));
        assert!(got.contains("  # Nicotine+ has no API a script could drive."));
        assert!(got.contains("  \"suspense\" = [ \"base\" \"dev\" ];"));
        assert!(got.contains("  \"dusk\" = [ \"base\" ];"));
    }

    #[test]
    fn insert_places_host_in_sorted_position() {
        let got = insert_host(REAL, "dusk", &feats(&["base"]));
        let at = |s: &str| got.find(s).unwrap();
        assert!(at("\"dance\"") < at("\"dusk\""));
        assert!(at("\"dusk\"") < at("\"suspense\""));
    }

    /// The comment block documents suspense. Inserting a host that sorts
    /// between `dance` and `suspense` must not land between the comment and
    /// the entry it describes.
    #[test]
    fn insert_does_not_split_a_comment_from_its_entry() {
        let got = insert_host(REAL, "dusk", &feats(&["base"]));
        let at = |s: &str| got.find(s).unwrap();
        assert!(
            at("\"dusk\"") < at("# slskd"),
            "new entry must go above the comment block, not between it and suspense:\n{got}"
        );
        assert!(at("# Nicotine+") < at("\"suspense\""));
    }

    #[test]
    fn insert_last_host_goes_before_closing_brace() {
        let got = insert_host(REAL, "zulu", &feats(&["base", "dev"]));
        assert!(got.ends_with("  \"zulu\" = [ \"base\" \"dev\" ];\n}\n"), "{got}");
    }

    #[test]
    fn insert_first_host_goes_above_everything() {
        let got = insert_host(REAL, "aardvark", &feats(&["base"]));
        assert!(got.starts_with("{\n  \"aardvark\" = [ \"base\" ];\n"), "{got}");
    }

    /// Round-tripping must stay parseable: the result is still one entry per
    /// host and nothing was dropped.
    #[test]
    fn insert_keeps_every_host() {
        let got = insert_host(REAL, "dusk", &feats(&["base"]));
        for h in ["console", "dance", "suspense", "dusk"] {
            assert_eq!(
                got.lines().filter(|l| entry_host(l).as_deref() == Some(h)).count(),
                1,
                "expected exactly one entry for {h} in:\n{got}"
            );
        }
    }

    #[test]
    fn entry_host_ignores_non_entry_lines() {
        assert_eq!(entry_host("  # \"dance\" = [ ];"), None);
        assert_eq!(entry_host("{"), None);
        assert_eq!(entry_host("}"), None);
        assert_eq!(entry_host("  \"dance\" = [ \"base\" ];").as_deref(), Some("dance"));
        assert_eq!(entry_host("  \"dance\"  = [ \"base\" ];").as_deref(), Some("dance"));
    }
}
