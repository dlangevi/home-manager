//! The pieces of snapserver's data model snapctl actually reads, plus the
//! pure decisions made on top of them: which client a typed name refers to,
//! and what a `+5` / `-5` / `50` argument resolves to against current state.
//!
//! Nothing here touches the network. The shapes come from
//! `doc/json_rpc_api/control.md` in badaix/snapcast (RPC v2.0.0) and are
//! deliberately partial -- every struct ignores fields snapctl has no use
//! for, which is also what keeps it from breaking when snapserver adds some.

use anyhow::{anyhow, bail, Result};
use serde::Deserialize;
use std::str::FromStr;

/// A snapclient's volume as snapserver models it: a percentage *and* an
/// independent mute flag, not a mute that zeroes the percentage.
#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
pub struct Volume {
    pub muted: bool,
    pub percent: i64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ClientConfig {
    /// The friendly name set from snapweb. Empty when never set, which is the
    /// normal case here -- `host.name` is what identifies a client instead.
    #[serde(default)]
    pub name: String,
    pub latency: i64,
    pub volume: Volume,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Host {
    pub name: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Client {
    /// Opaque, and MAC-derived in practice -- never something to type at a
    /// shell. Everything user-facing goes through `label()`.
    pub id: String,
    pub connected: bool,
    pub config: ClientConfig,
    pub host: Host,
}

impl Client {
    /// What to print, and what a typed name is matched against first.
    pub fn label(&self) -> &str {
        if self.config.name.is_empty() {
            &self.host.name
        } else {
            &self.config.name
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct Group {
    pub id: String,
    pub stream_id: String,
    pub clients: Vec<Client>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Stream {
    pub id: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ServerStatus {
    pub groups: Vec<Group>,
    pub streams: Vec<Stream>,
}

/// A client plus the group it sits in -- `Group.SetStream` needs the group id,
/// and the status table wants to show which stream a client is hearing, so
/// resolution hands back both rather than making callers search twice.
#[derive(Debug)]
pub struct Located<'a> {
    pub client: &'a Client,
    pub group: &'a Group,
}

impl ServerStatus {
    pub fn clients(&self) -> impl Iterator<Item = Located<'_>> {
        self.groups
            .iter()
            .flat_map(|g| g.clients.iter().map(move |c| Located { client: c, group: g }))
    }

    /// Resolve a name typed at the shell to exactly one client.
    ///
    /// Matching is case-insensitive against the friendly name, the hostname,
    /// and finally the raw id -- the id so that an ambiguous hostname is still
    /// addressable, since one host can run several snapclient instances and
    /// they differ only by an `...#2` suffix on the id.
    ///
    /// Ambiguity is an error rather than a first-match, because the whole
    /// point of these commands is that they are bound to a key and run
    /// unattended; silently moving the wrong machine's volume is worse than
    /// doing nothing.
    pub fn resolve<'a>(&'a self, name: &str) -> Result<Located<'a>> {
        let wanted = name.to_lowercase();

        let mut matches: Vec<Located<'a>> = self
            .clients()
            .filter(|l| {
                l.client.config.name.to_lowercase() == wanted
                    || l.client.host.name.to_lowercase() == wanted
                    || l.client.id.to_lowercase() == wanted
            })
            .collect();

        match matches.len() {
            1 => Ok(matches.remove(0)),
            0 => {
                let known: Vec<&str> = self.clients().map(|l| l.client.label()).collect();
                Err(anyhow!(
                    "no snapcast client named {name:?}; known clients: {}",
                    if known.is_empty() {
                        "(none connected)".to_string()
                    } else {
                        known.join(", ")
                    }
                ))
            }
            _ => {
                let ids: Vec<&str> = matches.iter().map(|l| l.client.id.as_str()).collect();
                Err(anyhow!(
                    "{name:?} matches {} clients; name one by id instead: {}",
                    matches.len(),
                    ids.join(", ")
                ))
            }
        }
    }

    /// Resolve a stream name case-insensitively against the configured
    /// sources ("Navidrome", "Spotify", "MPD" on dance). snapserver uses the
    /// `name=` query param of each `pipe://` source as the stream id, so the
    /// id *is* the human name and there is nothing else to match on.
    pub fn resolve_stream(&self, name: &str) -> Result<&str> {
        let wanted = name.to_lowercase();
        self.streams
            .iter()
            .find(|s| s.id.to_lowercase() == wanted)
            .map(|s| s.id.as_str())
            .ok_or_else(|| {
                let known: Vec<&str> = self.streams.iter().map(|s| s.id.as_str()).collect();
                anyhow!("no stream named {name:?}; known streams: {}", known.join(", "))
            })
    }
}

/// A numeric argument that may be absolute (`50`) or relative to the current
/// value (`+5`, `-5`).
///
/// The sign is what makes it relative, which means a bare negative absolute
/// (`-20` meaning "set latency to -20 ms") cannot be typed. That is a
/// deliberate trade: relative adjustment is what a keybinding needs, and any
/// value including negative ones is still reachable by repeating a relative
/// step, whereas losing `-5` to absolute parsing would make the hotkeys
/// impossible.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Adjust {
    Absolute(i64),
    Relative(i64),
}

impl Adjust {
    pub fn apply(self, current: i64, min: i64, max: i64) -> i64 {
        let raw = match self {
            Adjust::Absolute(v) => v,
            Adjust::Relative(d) => current + d,
        };
        raw.clamp(min, max)
    }
}

impl FromStr for Adjust {
    type Err = anyhow::Error;

    fn from_str(s: &str) -> Result<Self> {
        let s = s.trim();
        if s.is_empty() {
            bail!("expected a number like 50, +5 or -5");
        }
        // `+5` is not valid input to i64::from_str, so the relative case is
        // parsed off the remainder and the sign reapplied.
        let parse = |digits: &str| -> Result<i64> {
            digits
                .parse::<i64>()
                .map_err(|_| anyhow!("{s:?} is not a number like 50, +5 or -5"))
        };
        match s.strip_prefix('+') {
            Some(rest) => Ok(Adjust::Relative(parse(rest)?)),
            None => match s.strip_prefix('-') {
                Some(rest) => Ok(Adjust::Relative(-parse(rest)?)),
                None => Ok(Adjust::Absolute(parse(s)?)),
            },
        }
    }
}

/// What `snapctl mute` does, when no argument says otherwise.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MuteArg {
    On,
    Off,
    Toggle,
}

impl MuteArg {
    pub fn apply(self, current: bool) -> bool {
        match self {
            MuteArg::On => true,
            MuteArg::Off => false,
            MuteArg::Toggle => !current,
        }
    }
}

impl FromStr for MuteArg {
    type Err = anyhow::Error;

    fn from_str(s: &str) -> Result<Self> {
        match s.to_lowercase().as_str() {
            "on" | "true" | "yes" | "mute" => Ok(MuteArg::On),
            "off" | "false" | "no" | "unmute" => Ok(MuteArg::Off),
            "toggle" => Ok(MuteArg::Toggle),
            other => bail!("expected on, off or toggle, got {other:?}"),
        }
    }
}

pub const VOLUME_MIN: i64 = 0;
pub const VOLUME_MAX: i64 = 100;

/// snapweb's own latency slider runs -1000..1000 ms, so the same bounds apply
/// here -- not because snapserver rejects more, but so a key held down cannot
/// walk the offset somewhere unrecoverable by ear.
pub const LATENCY_MIN: i64 = -1000;
pub const LATENCY_MAX: i64 = 1000;

#[cfg(test)]
mod tests {
    use super::*;

    /// Trimmed from the `Server` example in snapcast's control.md, with the
    /// hostnames and stream names this deployment actually uses and a second
    /// instance on one host so the ambiguity path has something to trip on.
    const STATUS: &str = r#"{
      "groups": [
        {
          "id": "group-a",
          "muted": false,
          "name": "",
          "stream_id": "MPD",
          "clients": [
            {
              "id": "00:21:6a:7d:74:fc",
              "connected": true,
              "config": {"instance": 1, "latency": 0, "name": "", "volume": {"muted": false, "percent": 74}},
              "host": {"arch": "x86_64", "ip": "10.0.70.5", "mac": "00:21:6a:7d:74:fc", "name": "dance", "os": "NixOS"}
            },
            {
              "id": "aa:bb:cc:dd:ee:ff",
              "connected": true,
              "config": {"instance": 1, "latency": 20, "name": "Desk", "volume": {"muted": true, "percent": 48}},
              "host": {"arch": "x86_64", "ip": "10.0.70.6", "mac": "aa:bb:cc:dd:ee:ff", "name": "suspense", "os": "NixOS"}
            }
          ]
        },
        {
          "id": "group-b",
          "muted": false,
          "name": "",
          "stream_id": "Spotify",
          "clients": [
            {
              "id": "00:21:6a:7d:74:fc#2",
              "connected": false,
              "config": {"instance": 2, "latency": -5, "name": "", "volume": {"muted": false, "percent": 10}},
              "host": {"arch": "x86_64", "ip": "10.0.70.5", "mac": "00:21:6a:7d:74:fc", "name": "dance", "os": "NixOS"}
            }
          ]
        }
      ],
      "streams": [{"id": "Navidrome"}, {"id": "Spotify"}, {"id": "MPD"}]
    }"#;

    fn status() -> ServerStatus {
        serde_json::from_str(STATUS).expect("fixture parses")
    }

    #[test]
    fn parses_a_partial_server_status() {
        let s = status();
        assert_eq!(s.groups.len(), 2);
        assert_eq!(s.clients().count(), 3);
        assert_eq!(s.streams.len(), 3);
    }

    #[test]
    fn resolves_by_hostname() {
        let s = status();
        let found = s.resolve("suspense").unwrap();
        assert_eq!(found.client.id, "aa:bb:cc:dd:ee:ff");
        assert_eq!(found.group.id, "group-a");
    }

    #[test]
    fn resolves_by_friendly_name() {
        let s = status();
        assert_eq!(s.resolve("Desk").unwrap().client.host.name, "suspense");
    }

    #[test]
    fn resolution_is_case_insensitive() {
        let s = status();
        assert_eq!(s.resolve("SUSPENSE").unwrap().client.id, "aa:bb:cc:dd:ee:ff");
        assert_eq!(s.resolve("desk").unwrap().client.id, "aa:bb:cc:dd:ee:ff");
    }

    #[test]
    fn unknown_name_lists_what_is_known() {
        let s = status();
        let err = s.resolve("kitchen").unwrap_err().to_string();
        assert!(err.contains("kitchen"), "{err}");
        assert!(err.contains("Desk"), "{err}");
    }

    #[test]
    fn ambiguous_name_is_an_error_naming_the_ids() {
        let s = status();
        // Two snapclient instances on the host "dance".
        let err = s.resolve("dance").unwrap_err().to_string();
        assert!(err.contains("matches 2 clients"), "{err}");
        assert!(err.contains("00:21:6a:7d:74:fc#2"), "{err}");
    }

    #[test]
    fn an_ambiguous_host_is_still_addressable_by_id() {
        let s = status();
        let found = s.resolve("00:21:6a:7d:74:fc#2").unwrap();
        assert_eq!(found.group.id, "group-b");
    }

    #[test]
    fn label_prefers_the_friendly_name() {
        let s = status();
        assert_eq!(s.resolve("Desk").unwrap().client.label(), "Desk");
        assert_eq!(s.resolve("00:21:6a:7d:74:fc").unwrap().client.label(), "dance");
    }

    #[test]
    fn resolves_streams_case_insensitively() {
        let s = status();
        assert_eq!(s.resolve_stream("mpd").unwrap(), "MPD");
        let err = s.resolve_stream("radio").unwrap_err().to_string();
        assert!(err.contains("Navidrome"), "{err}");
    }

    #[test]
    fn adjust_parses_absolute_and_relative() {
        assert_eq!("50".parse::<Adjust>().unwrap(), Adjust::Absolute(50));
        assert_eq!("+5".parse::<Adjust>().unwrap(), Adjust::Relative(5));
        assert_eq!("-5".parse::<Adjust>().unwrap(), Adjust::Relative(-5));
        assert!("loud".parse::<Adjust>().is_err());
        assert!("".parse::<Adjust>().is_err());
    }

    #[test]
    fn adjust_applies_relative_to_current() {
        assert_eq!(
            Adjust::Relative(5).apply(74, VOLUME_MIN, VOLUME_MAX),
            79
        );
        assert_eq!(
            Adjust::Relative(-5).apply(74, VOLUME_MIN, VOLUME_MAX),
            69
        );
        assert_eq!(
            Adjust::Absolute(50).apply(74, VOLUME_MIN, VOLUME_MAX),
            50
        );
    }

    #[test]
    fn adjust_clamps_at_both_bounds() {
        assert_eq!(Adjust::Relative(10).apply(97, VOLUME_MIN, VOLUME_MAX), 100);
        assert_eq!(Adjust::Relative(-10).apply(3, VOLUME_MIN, VOLUME_MAX), 0);
        assert_eq!(Adjust::Absolute(999).apply(0, VOLUME_MIN, VOLUME_MAX), 100);
        assert_eq!(
            Adjust::Relative(-100).apply(-950, LATENCY_MIN, LATENCY_MAX),
            -1000
        );
    }

    #[test]
    fn mute_toggle_reads_current_state() {
        assert!(MuteArg::Toggle.apply(false));
        assert!(!MuteArg::Toggle.apply(true));
        assert!(MuteArg::On.apply(true));
        assert!(!MuteArg::Off.apply(false));
        assert_eq!("TOGGLE".parse::<MuteArg>().unwrap(), MuteArg::Toggle);
        assert!("sometimes".parse::<MuteArg>().is_err());
    }
}
