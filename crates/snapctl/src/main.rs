//! snapctl -- per-client control of the snapcast group hosted on dance.
//!
//! Why this exists: Plasma has no native surface for a *remote* client's
//! volume. Its mixer enumerates local PipeWire streams, so this machine's own
//! snapclient already appears there, but the box across the room does not and
//! cannot. snapweb has those controls and is a browser tab you have to go
//! open. So the desktop surface is KDE global shortcuts (modules/plasma.nix)
//! plus KDE notifications, and this is what they run.
//!
//! Transport and now-playing are a different problem with a real native
//! answer -- mpd-mpris, wired up in modules/mpd-client.nix. snapctl
//! deliberately has no play/pause: that would be a second, worse control
//! surface for something the media keys already drive.

mod model;
mod notify;
mod rpc;

use anyhow::Result;
use clap::{Parser, Subcommand};
use serde_json::json;

use model::{Adjust, MuteArg, LATENCY_MAX, LATENCY_MIN, VOLUME_MAX, VOLUME_MIN};
use rpc::Connection;

/// Control snapcast clients: per-client volume, mute, latency trim and stream
/// routing, over snapserver's JSON-RPC control port.
#[derive(Parser)]
#[command(name = "snapctl", version, about, long_about = None)]
struct Cli {
    /// snapserver host. Defaults to $SNAPCAST_HOST, then "dance".
    #[arg(long, global = true, env = "SNAPCAST_HOST", default_value = "dance")]
    host: String,

    /// snapserver control port (its `tcp-control` socket, not snapweb's).
    #[arg(long, global = true, env = "SNAPCAST_PORT", default_value_t = 1705)]
    port: u16,

    /// Print the result as JSON instead of a human-readable line.
    #[arg(long, global = true)]
    json: bool,

    /// Also raise a desktop notification. For hotkeys, where there is no
    /// terminal to print to.
    #[arg(long, global = true)]
    notify: bool,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// List every client: volume, mute, latency and the stream it is playing.
    Status,

    /// Set or adjust a client's volume. VALUE is 0-100, or +N / -N to step
    /// relative to where it is now.
    Volume {
        /// Client hostname, its snapweb name, or its raw id.
        client: String,
        // Load-bearing, not tidiness: without it clap reads the `-5` in
        // `snapctl volume dance -5` as an unknown short flag and the command
        // fails before main() runs. Half the hotkeys in modules/plasma.nix
        // are a negative step. It has to sit on the arg -- the same setting
        // on the top-level command does not reach subcommands.
        #[arg(allow_negative_numbers = true)]
        value: Adjust,
    },

    /// Mute, unmute, or toggle a client. Defaults to toggle.
    Mute {
        client: String,
        #[arg(default_value = "toggle")]
        state: MuteArg,
    },

    /// Set or adjust a client's latency offset in ms, to compensate for
    /// speaker distance. VALUE is absolute, or +N / -N relative -- note that
    /// a leading minus always means relative, so a negative offset is reached
    /// by stepping down rather than by typing it.
    Latency {
        client: String,
        #[arg(allow_negative_numbers = true)]
        value: Adjust,
    },

    /// Point the client's group at a different source ("Navidrome",
    /// "Spotify", "MPD"). Affects every client in that group, which is what
    /// a snapcast group is for.
    Stream {
        client: String,
        stream: String,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let mut conn = Connection::connect(&cli.host, cli.port)?;

    // Every mutating command is read-modify-write: relative steps and `mute
    // toggle` all need the current value, and the status table needs the lot.
    // One GetStatus up front covers all of them.
    let status = conn.status()?;

    match &cli.command {
        Command::Status => {
            if cli.json {
                let rows: Vec<_> = status
                    .clients()
                    .map(|l| {
                        json!({
                            "id": l.client.id,
                            "name": l.client.label(),
                            "host": l.client.host.name,
                            "connected": l.client.connected,
                            "volume": l.client.config.volume.percent,
                            "muted": l.client.config.volume.muted,
                            "latency": l.client.config.latency,
                            "group": l.group.id,
                            "stream": l.group.stream_id,
                        })
                    })
                    .collect();
                println!("{}", serde_json::to_string_pretty(&json!({"clients": rows}))?);
            } else {
                print_table(&status);
            }
            return Ok(());
        }

        Command::Volume { client, value } => {
            let found = status.resolve(client)?;
            let current = found.client.config.volume;
            let percent = value.apply(current.percent, VOLUME_MIN, VOLUME_MAX);
            conn.set_volume(&found.client.id, percent, current.muted)?;
            report(
                &cli,
                found.client.label(),
                &format!(
                    "volume {percent}%{}",
                    if current.muted { " (muted)" } else { "" }
                ),
                Some(percent),
            )?;
        }

        Command::Mute { client, state } => {
            let found = status.resolve(client)?;
            let current = found.client.config.volume;
            let muted = state.apply(current.muted);
            // SetVolume carries both fields, so the percentage has to be
            // echoed back unchanged or muting would also reset it.
            conn.set_volume(&found.client.id, current.percent, muted)?;
            report(
                &cli,
                found.client.label(),
                if muted { "muted" } else { "unmuted" },
                Some(if muted { 0 } else { current.percent }),
            )?;
        }

        Command::Latency { client, value } => {
            let found = status.resolve(client)?;
            let latency = value.apply(found.client.config.latency, LATENCY_MIN, LATENCY_MAX);
            conn.set_latency(&found.client.id, latency)?;
            report(&cli, found.client.label(), &format!("latency {latency} ms"), None)?;
        }

        Command::Stream { client, stream } => {
            let found = status.resolve(client)?;
            let stream_id = status.resolve_stream(stream)?.to_string();
            conn.set_stream(&found.group.id, &stream_id)?;
            report(
                &cli,
                found.client.label(),
                &format!("playing {stream_id}"),
                None,
            )?;
        }
    }

    Ok(())
}

fn print_table(status: &model::ServerStatus) {
    let rows: Vec<_> = status.clients().collect();
    let width = rows
        .iter()
        .map(|l| l.client.label().len())
        .max()
        .unwrap_or(0)
        .max("CLIENT".len());

    println!("{:<width$}  {:>6}  {:>8}  STREAM", "CLIENT", "VOLUME", "LATENCY");
    for l in rows {
        let volume = if l.client.config.volume.muted {
            format!("{}% M", l.client.config.volume.percent)
        } else {
            format!("{}%", l.client.config.volume.percent)
        };
        let stream = if l.client.connected {
            l.group.stream_id.clone()
        } else {
            format!("{} (offline)", l.group.stream_id)
        };
        println!(
            "{:<width$}  {:>6}  {:>8}  {}",
            l.client.label(),
            volume,
            format!("{} ms", l.client.config.latency),
            stream,
        );
    }
}

/// One place for "say what just happened", so stdout and the notification
/// never drift apart.
fn report(cli: &Cli, client: &str, what: &str, percent: Option<i64>) -> Result<()> {
    if cli.json {
        println!(
            "{}",
            serde_json::to_string(&json!({"client": client, "result": what}))?
        );
    } else {
        println!("{client}: {what}");
    }
    if cli.notify {
        notify::send(client, what, percent)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::CommandFactory;

    #[test]
    fn clap_definition_is_valid() {
        Cli::command().debug_assert();
    }

    /// The regression this exists for: clap reads a leading `-` as a short
    /// flag, so `volume dance -5` failed to parse at all. Half the hotkeys in
    /// modules/plasma.nix are a negative step.
    #[test]
    fn negative_steps_parse_as_values_not_flags() {
        let cli = Cli::try_parse_from(["snapctl", "volume", "dance", "-5"]).unwrap();
        match cli.command {
            Command::Volume { client, value } => {
                assert_eq!(client, "dance");
                assert_eq!(value, Adjust::Relative(-5));
            }
            _ => panic!("parsed as the wrong subcommand"),
        }

        let cli = Cli::try_parse_from(["snapctl", "latency", "suspense", "-20"]).unwrap();
        match cli.command {
            Command::Latency { value, .. } => assert_eq!(value, Adjust::Relative(-20)),
            _ => panic!("parsed as the wrong subcommand"),
        }
    }

    #[test]
    fn positive_and_absolute_steps_still_parse() {
        for (arg, expected) in [("+5", Adjust::Relative(5)), ("50", Adjust::Absolute(50))] {
            let cli = Cli::try_parse_from(["snapctl", "volume", "dance", arg]).unwrap();
            match cli.command {
                Command::Volume { value, .. } => assert_eq!(value, expected, "for {arg}"),
                _ => panic!("parsed as the wrong subcommand"),
            }
        }
    }

    #[test]
    fn mute_defaults_to_toggle() {
        let cli = Cli::try_parse_from(["snapctl", "mute", "dance"]).unwrap();
        match cli.command {
            Command::Mute { state, .. } => assert_eq!(state, MuteArg::Toggle),
            _ => panic!("parsed as the wrong subcommand"),
        }
    }

    #[test]
    fn host_and_port_have_the_deployment_defaults() {
        // env() on these args would read the ambient SNAPCAST_HOST, so this
        // asserts the fallback rather than whatever the shell happens to set.
        let cli = Cli::try_parse_from(["snapctl", "--host", "dance", "status"]).unwrap();
        assert_eq!(cli.host, "dance");
        assert_eq!(cli.port, 1705);
    }
}
