//! Minimal `text/event-stream` reader (PRD-6 §4.5).
//!
//! The Elixir plug commits to SSE when a handler outlives `sse_commit_after`,
//! so a synchronous client must be able to read the upgraded stream. This reader
//! is deliberately small: accumulate `data:` lines per event, dispatch on a
//! blank line, stop at the first JSON-RPC message whose `id` matches. No
//! resume, no reconnect, no `Last-Event-ID` replay (PRD-6 §9 Q3).

use crate::errors::{McpError, McpResult};
use serde_json::Value;
use std::io::{BufRead, BufReader, Read};
use std::time::{Duration, Instant};

/// One decoded SSE frame.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Event {
    pub event: Option<String>,
    pub id: Option<String>,
    pub data: String,
}

/// Called between events so a long stream stays cancelable (FR-6.14).
pub trait Interrupts {
    fn check(&self) -> McpResult<()>;
}

/// Interrupt hook used by unit tests and the byte-slice helper: never cancels.
pub struct NoInterrupts;
impl Interrupts for NoInterrupts {
    fn check(&self) -> McpResult<()> {
        Ok(())
    }
}

/// Read the stream until a JSON-RPC message carrying `want_id` arrives.
///
/// `deadline` is a **total** budget across the whole stream, not per read
/// (PRD-6 §4.5, FR-6.12). Non-matching frames (progress notifications, log
/// messages, replies to other ids) are skipped. Reaching end-of-stream without a
/// match is `08006`.
pub fn read_until_id<R: Read, I: Interrupts>(
    reader: R,
    want_id: i64,
    timeout: Duration,
    interrupts: &I,
) -> McpResult<Value> {
    let started = Instant::now();
    let mut buffered = BufReader::new(reader);
    let mut pending = Event::default();
    let mut data_lines: Vec<String> = Vec::new();
    let mut line = String::new();

    loop {
        if started.elapsed() >= timeout {
            return Err(McpError::Transport(format!(
                "MCP request timed out after {}ms while reading the event stream",
                timeout.as_millis()
            )));
        }

        line.clear();
        let read = buffered.read_line(&mut line).map_err(|e| {
            McpError::Transport(format!("event stream read failed: {}", io_kind(&e)))
        })?;

        if read == 0 {
            // End of stream with no matching id.
            return Err(McpError::Transport(
                "MCP event stream ended before the response arrived".to_string(),
            ));
        }

        let trimmed = line.trim_end_matches(['\r', '\n']);

        if trimmed.is_empty() {
            // Blank line dispatches the accumulated event.
            interrupts.check()?;

            if !data_lines.is_empty() {
                pending.data = data_lines.join("\n");
                if let Some(value) = match_frame(&pending, want_id)? {
                    return Ok(value);
                }
            }
            pending = Event::default();
            data_lines.clear();
            continue;
        }

        // A leading ':' is a comment (the plug's keepalives). Ignore.
        if trimmed.starts_with(':') {
            continue;
        }

        let (field, value) = match trimmed.split_once(':') {
            Some((f, v)) => (f, v.strip_prefix(' ').unwrap_or(v)),
            // A bare field name with no colon has an empty value.
            None => (trimmed, ""),
        };

        match field {
            "data" => data_lines.push(value.to_string()),
            // Retained for a future Last-Event-ID resume; unused today.
            "id" => pending.id = Some(value.to_string()),
            "event" => pending.event = Some(value.to_string()),
            // "retry" and anything unknown are ignored per the SSE spec.
            _ => {}
        }
    }
}

/// Does this frame carry the JSON-RPC reply we are waiting for?
fn match_frame(event: &Event, want_id: i64) -> McpResult<Option<Value>> {
    let parsed: Value = match serde_json::from_str(&event.data) {
        Ok(v) => v,
        // A frame that is not JSON is not our reply; a malformed *stream* is
        // caught by the end-of-stream and deadline branches instead.
        Err(_) => return Ok(None),
    };

    match parsed.get("id").and_then(json_id) {
        Some(id) if id == want_id => Ok(Some(parsed)),
        _ => Ok(None),
    }
}

/// JSON-RPC ids may be numbers or strings; pg_mcp only ever sends numbers, so
/// accept a numeric string too rather than missing a reply on a server that
/// stringifies ids.
fn json_id(value: &Value) -> Option<i64> {
    match value {
        Value::Number(n) => n.as_i64(),
        Value::String(s) => s.parse().ok(),
        _ => None,
    }
}

fn io_kind(e: &std::io::Error) -> String {
    // Never surface the OS message verbatim; it can contain the request URL and
    // therefore, on a malformed server, query material. Kind is enough.
    format!("{:?}", e.kind())
}

#[cfg(any(test, feature = "pg_test"))]
#[pgrx::pg_schema]
mod tests {
    use super::*;

    fn read(bytes: &str, id: i64) -> McpResult<Value> {
        read_until_id(bytes.as_bytes(), id, Duration::from_secs(5), &NoInterrupts)
    }

    #[pgrx::pg_test]
    fn single_event() {
        let out = read(
            "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}\n\n",
            1,
        )
        .unwrap();
        assert_eq!(out["result"]["ok"], serde_json::json!(true));
    }

    #[pgrx::pg_test]
    fn multi_line_data_is_joined_with_newlines() {
        let stream =
            "data: {\"jsonrpc\":\"2.0\",\ndata: \"id\":2,\ndata: \"result\":\"split\"}\n\n";
        let out = read(stream, 2).unwrap();
        assert_eq!(out["result"], serde_json::json!("split"));
    }

    #[pgrx::pg_test]
    fn ignores_comments_event_and_id_lines() {
        let stream = concat!(
            ": keepalive\n",
            "\n",
            "event: message\n",
            "id: 7\n",
            "data: {\"jsonrpc\":\"2.0\",\"id\":3,\"result\":\"fine\"}\n",
            "\n"
        );
        assert_eq!(
            read(stream, 3).unwrap()["result"],
            serde_json::json!("fine")
        );
    }

    #[pgrx::pg_test]
    fn skips_frames_for_other_ids_and_notifications() {
        let stream = concat!(
            "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}\n",
            "\n",
            "data: {\"jsonrpc\":\"2.0\",\"id\":99,\"result\":\"someone else\"}\n",
            "\n",
            "data: {\"jsonrpc\":\"2.0\",\"id\":4,\"result\":\"mine\"}\n",
            "\n"
        );
        assert_eq!(
            read(stream, 4).unwrap()["result"],
            serde_json::json!("mine")
        );
    }

    #[pgrx::pg_test]
    fn string_ids_still_match() {
        let out = read(
            "data: {\"jsonrpc\":\"2.0\",\"id\":\"5\",\"result\":\"str\"}\n\n",
            5,
        )
        .unwrap();
        assert_eq!(out["result"], serde_json::json!("str"));
    }

    #[pgrx::pg_test]
    fn truncated_stream_is_08006() {
        // No terminating blank line: the frame never dispatches.
        let err = read("data: {\"jsonrpc\":\"2.0\",\"id\":6,\"result\":1}", 6).unwrap_err();
        assert_eq!(err.sqlstate(), "08006");
    }

    #[pgrx::pg_test]
    fn stream_without_the_wanted_id_is_08006() {
        let err = read("data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":1}\n\n", 42).unwrap_err();
        assert_eq!(err.sqlstate(), "08006");
        assert!(err.message().contains("ended before"));
    }

    #[pgrx::pg_test]
    fn non_json_frames_are_skipped_not_fatal() {
        let stream = concat!(
            "data: not json at all\n",
            "\n",
            "data: {\"jsonrpc\":\"2.0\",\"id\":8,\"result\":\"after garbage\"}\n",
            "\n"
        );
        assert_eq!(
            read(stream, 8).unwrap()["result"],
            serde_json::json!("after garbage")
        );
    }

    #[pgrx::pg_test]
    fn deadline_is_total_across_the_stream() {
        // A reader that blocks forever: an expired deadline must win.
        struct Never;
        impl Read for Never {
            fn read(&mut self, _buf: &mut [u8]) -> std::io::Result<usize> {
                std::thread::sleep(Duration::from_millis(50));
                Ok(0)
            }
        }
        let err = read_until_id(Never, 1, Duration::from_millis(0), &NoInterrupts).unwrap_err();
        assert_eq!(err.sqlstate(), "08006");
        assert!(err.message().contains("timed out"));
    }

    #[pgrx::pg_test]
    fn interrupt_hook_runs_between_events() {
        use std::cell::Cell;
        struct Counting(Cell<u32>);
        impl Interrupts for Counting {
            fn check(&self) -> McpResult<()> {
                self.0.set(self.0.get() + 1);
                Ok(())
            }
        }
        let stream = concat!(
            "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":1}\n\n",
            "data: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":2}\n\n",
            "data: {\"jsonrpc\":\"2.0\",\"id\":3,\"result\":3}\n\n"
        );
        let counter = Counting(Cell::new(0));
        read_until_id(stream.as_bytes(), 3, Duration::from_secs(5), &counter).unwrap();
        assert_eq!(counter.0.get(), 3, "one check per dispatched event");
    }

    #[pgrx::pg_test]
    fn a_cancelling_interrupt_hook_aborts_the_read() {
        struct Cancel;
        impl Interrupts for Cancel {
            fn check(&self) -> McpResult<()> {
                Err(McpError::Transport("cancelled".into()))
            }
        }
        let stream = "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":1}\n\ndata: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":2}\n\n";
        assert!(read_until_id(stream.as_bytes(), 2, Duration::from_secs(5), &Cancel).is_err());
    }
}
