//! snapserver's JSON-RPC 2.0 control API over a raw TCP socket.
//!
//! The same API snapweb drives over a websocket, but framed as newline-
//! delimited JSON, which is why `tcp-control` is enabled in
//! nixos/modules/snapcast.nix -- it means no websocket client here, only
//! serde_json over a TcpStream.
//!
//! The one thing that is not request/response: snapserver pushes
//! notifications (`Client.OnVolumeChanged` and friends) down the same socket,
//! unprompted. They have no `id`, so every read loops until it sees the id it
//! sent rather than trusting the next line to be the answer.

use anyhow::{anyhow, bail, Context, Result};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

use crate::model::ServerStatus;

const TIMEOUT: Duration = Duration::from_secs(5);

pub struct Connection {
    reader: BufReader<TcpStream>,
    writer: TcpStream,
    next_id: u64,
}

impl Connection {
    pub fn connect(host: &str, port: u16) -> Result<Self> {
        let addr = (host, port)
            .to_socket_addrs()
            .with_context(|| format!("resolving {host}:{port}"))?
            .next()
            .ok_or_else(|| anyhow!("{host}:{port} resolved to no addresses"))?;

        let stream = TcpStream::connect_timeout(&addr, TIMEOUT)
            .with_context(|| format!("connecting to snapserver at {host}:{port}"))?;
        stream.set_read_timeout(Some(TIMEOUT))?;
        stream.set_write_timeout(Some(TIMEOUT))?;

        Ok(Self {
            reader: BufReader::new(stream.try_clone()?),
            writer: stream,
            next_id: 1,
        })
    }

    pub fn call(&mut self, method: &str, params: Value) -> Result<Value> {
        let id = self.next_id;
        self.next_id += 1;

        let mut line = serde_json::to_string(&request(id, method, &params))?;
        line.push_str("\r\n");
        self.writer
            .write_all(line.as_bytes())
            .with_context(|| format!("sending {method}"))?;
        self.writer.flush()?;

        loop {
            let mut buf = String::new();
            let n = self
                .reader
                .read_line(&mut buf)
                .with_context(|| format!("waiting for a reply to {method}"))?;
            if n == 0 {
                bail!("snapserver closed the connection before replying to {method}");
            }
            let value: Value = serde_json::from_str(buf.trim())
                .with_context(|| format!("parsing snapserver's reply to {method}"))?;

            // Unsolicited notification for some other client's volume etc.
            if value.get("id").is_none_or(|v| v.as_u64() != Some(id)) {
                continue;
            }
            return result_of(value).with_context(|| format!("{method} failed"));
        }
    }

    pub fn status(&mut self) -> Result<ServerStatus> {
        let result = self.call("Server.GetStatus", json!({}))?;
        let server = result
            .get("server")
            .ok_or_else(|| anyhow!("Server.GetStatus reply had no `server` key"))?;
        serde_json::from_value(server.clone()).context("parsing Server.GetStatus")
    }

    pub fn set_volume(&mut self, client_id: &str, percent: i64, muted: bool) -> Result<()> {
        self.call(
            "Client.SetVolume",
            json!({"id": client_id, "volume": {"muted": muted, "percent": percent}}),
        )?;
        Ok(())
    }

    pub fn set_latency(&mut self, client_id: &str, latency: i64) -> Result<()> {
        self.call("Client.SetLatency", json!({"id": client_id, "latency": latency}))?;
        Ok(())
    }

    pub fn set_stream(&mut self, group_id: &str, stream_id: &str) -> Result<()> {
        self.call(
            "Group.SetStream",
            json!({"id": group_id, "stream_id": stream_id}),
        )?;
        Ok(())
    }
}

/// Split out from `call` so the wire format can be asserted against the
/// examples in control.md without a socket.
fn request(id: u64, method: &str, params: &Value) -> Value {
    // `Server.GetStatus` takes none, and snapserver is happy either way, but
    // an empty `params` object is noise in a log.
    let omit_params = params.as_object().is_some_and(|o| o.is_empty());
    if omit_params {
        json!({"id": id, "jsonrpc": "2.0", "method": method})
    } else {
        json!({"id": id, "jsonrpc": "2.0", "method": method, "params": params})
    }
}

/// Turn a JSON-RPC envelope into its `result`, or into an `Err` carrying
/// snapserver's own message. A protocol-level error is a normal outcome here
/// (a client that just disconnected, a stream id that no longer exists), so
/// it must not panic.
fn result_of(value: Value) -> Result<Value> {
    if let Some(err) = value.get("error") {
        let code = err.get("code").and_then(Value::as_i64);
        let message = err
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("unknown error");
        let detail = err.get("data").and_then(Value::as_str);
        return match (code, detail) {
            (Some(c), Some(d)) => Err(anyhow!("snapserver error {c}: {message} ({d})")),
            (Some(c), None) => Err(anyhow!("snapserver error {c}: {message}")),
            _ => Err(anyhow!("snapserver error: {message}")),
        };
    }
    value
        .get("result")
        .cloned()
        .ok_or_else(|| anyhow!("snapserver reply had neither `result` nor `error`"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn get_status_request_matches_the_documented_envelope() {
        assert_eq!(
            request(8, "Server.GetStatus", &json!({})),
            json!({"id": 8, "jsonrpc": "2.0", "method": "Server.GetStatus"})
        );
    }

    #[test]
    fn set_volume_request_matches_the_documented_envelope() {
        assert_eq!(
            request(
                8,
                "Client.SetVolume",
                &json!({"id": "00:21:6a:7d:74:fc", "volume": {"muted": false, "percent": 74}})
            ),
            json!({
                "id": 8,
                "jsonrpc": "2.0",
                "method": "Client.SetVolume",
                "params": {"id": "00:21:6a:7d:74:fc", "volume": {"muted": false, "percent": 74}}
            })
        );
    }

    #[test]
    fn set_latency_request_matches_the_documented_envelope() {
        assert_eq!(
            request(7, "Client.SetLatency", &json!({"id": "00:21:6a:7d:74:fc#2", "latency": 10})),
            json!({
                "id": 7,
                "jsonrpc": "2.0",
                "method": "Client.SetLatency",
                "params": {"id": "00:21:6a:7d:74:fc#2", "latency": 10}
            })
        );
    }

    #[test]
    fn set_stream_request_matches_the_documented_envelope() {
        assert_eq!(
            request(4, "Group.SetStream", &json!({"id": "group-a", "stream_id": "MPD"})),
            json!({
                "id": 4,
                "jsonrpc": "2.0",
                "method": "Group.SetStream",
                "params": {"id": "group-a", "stream_id": "MPD"}
            })
        );
    }

    #[test]
    fn a_result_envelope_unwraps() {
        let v = json!({"id": 8, "jsonrpc": "2.0", "result": {"volume": {"muted": false, "percent": 74}}});
        assert_eq!(result_of(v).unwrap(), json!({"volume": {"muted": false, "percent": 74}}));
    }

    #[test]
    fn an_error_envelope_becomes_an_err_not_a_panic() {
        let v = json!({"id": 1, "jsonrpc": "2.0", "error": {"code": -32602, "message": "Invalid params"}});
        let err = result_of(v).unwrap_err().to_string();
        assert!(err.contains("-32602"), "{err}");
        assert!(err.contains("Invalid params"), "{err}");
    }

    #[test]
    fn an_envelope_with_neither_key_is_an_err() {
        assert!(result_of(json!({"id": 1, "jsonrpc": "2.0"})).is_err());
    }
}
