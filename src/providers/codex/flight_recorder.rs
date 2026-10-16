//! Content-free, bounded failure evidence. No request or event Values are retained.

use std::collections::VecDeque;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Instant, SystemTime};

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::client::{CodexError, CodexErrorOrigin};
use super::events::{self, CodexStreamEventKind};
use super::translate::request::ResponsesRequest;
use crate::provider::RequestContext;

const MAX_EVENTS: usize = 128;
const MAX_FILE_BYTES: usize = 128 * 1024;
const MAX_FILES: usize = 100;
const MAX_TOTAL_BYTES: u64 = 10 * 1024 * 1024;
static WRITER: Mutex<()> = Mutex::new(());
static PENDING_WRITES: AtomicUsize = AtomicUsize::new(0);

pub(super) struct Recorder {
    started: Instant,
    metadata: Value,
    events: VecDeque<Value>,
    seen: u64,
    semantic: bool,
    terminal_success: bool,
    captured: bool,
}

impl Recorder {
    fn new(
        req_id: &str,
        session_id: Option<&str>,
        model: &str,
        transport: &'static str,
        input_items: usize,
        previous_id: Option<&str>,
    ) -> Self {
        Self {
            started: Instant::now(),
            metadata: json!({
                "schema":1, "build":env!("CARGO_PKG_VERSION"),
                "started_utc":time::OffsetDateTime::now_utc().format(&time::format_description::well_known::Rfc3339).ok(),
                "request_fingerprint":fingerprint(req_id),
                "request_id":uuid::Uuid::parse_str(req_id).ok().map(|id|id.to_string()),
                "session_fingerprint":session_id.map(fingerprint),
                "model_fingerprint":fingerprint(model),
                "model":match model {
                    "gpt-6.1-sol" | "gpt-6-astra" | "gpt-6-sol" | "gpt-5.6-sol" | "gpt-5.6-terra" | "gpt-5.6-luna" => model,
                    _ => "other",
                },
                "transport":transport, "input_items":input_items,
                "previous_response_fingerprint":previous_id.map(fingerprint),
                "compact_boundary":null,
            }),
            events: VecDeque::with_capacity(MAX_EVENTS),
            seen: 0,
            semantic: false,
            terminal_success: false,
            captured: false,
        }
    }

    pub(super) fn for_request(
        body: &ResponsesRequest,
        ctx: &RequestContext,
        transport: &'static str,
        previous_id: Option<&str>,
    ) -> Self {
        Self::new(
            &ctx.req_id,
            ctx.session_id.as_deref(),
            &body.model,
            transport,
            body.input.len(),
            previous_id,
        )
    }

    pub(super) fn set_compaction(&mut self, boundary: bool) {
        self.metadata["compact_boundary"] = json!(boundary);
    }

    pub(super) fn set_estimated_input_tokens(&mut self, tokens: u64) {
        self.metadata["estimated_input_tokens"] = json!(tokens);
    }

    pub(super) fn end_of_stream(&mut self) {
        if !self.terminal_success {
            self.fail("missing_terminal", 502);
        }
    }

    pub(super) fn observe(&mut self, payload: &Value) -> Option<u16> {
        let kind = events::classify_stream_event(payload);
        self.semantic |= kind == CodexStreamEventKind::Semantic;
        self.terminal_success |= kind == CodexStreamEventKind::TerminalSuccess;
        // This is intentionally an allowlist, NOT unwrap_or: unknown event
        // names can contain private content and must never be copied verbatim.
        #[allow(clippy::manual_unwrap_or)]
        let name = match payload.get("type").and_then(Value::as_str) {
            Some(
                name @ ("response.created"
                | "response.in_progress"
                | "response.completed"
                | "response.done"
                | "response.failed"
                | "response.incomplete"
                | "error"
                | "keepalive"
                | "codex.rate_limits"
                | "response.output_text.delta"
                | "response.reasoning_summary_text.delta"
                | "response.function_call_arguments.delta"
                | "response.output_item.added"
                | "response.output_item.done"
                | "response.content_part.added"
                | "response.content_part.done"
                | "response.output_text.done"
                | "response.reasoning_summary_text.done"
                | "response.web_search_call.in_progress"
                | "response.web_search_call.searching"
                | "response.web_search_call.completed"),
            ) => name,
            _ => "other",
        };
        let event = json!({
            "elapsed_ms":self.started.elapsed().as_millis() as u64,
            "type":name, "kind":format!("{kind:?}"),
            "sequence":payload.get("sequence_number").and_then(Value::as_u64),
            "upstream_status":payload.get("status").and_then(Value::as_u64).filter(|status|*status <= u16::MAX as u64),
            "delta_bytes":payload.get("delta").and_then(Value::as_str).map(str::len),
            "response_fingerprint":payload.pointer("/response/id").and_then(Value::as_str).map(fingerprint),
            "input_tokens":payload.pointer("/response/usage/input_tokens").and_then(Value::as_u64),
            "output_tokens":payload.pointer("/response/usage/output_tokens").and_then(Value::as_u64),
            "cached_tokens":payload.pointer("/response/usage/input_tokens_details/cached_tokens").and_then(Value::as_u64),
            "error_code":match events::event_error(payload).and_then(|error|error.get("code")).and_then(Value::as_str) {
                Some(code @ ("context_length_exceeded" | "rate_limit_exceeded" | "server_error" | "overloaded" | "invalid_request_error" | "previous_response_not_found" | "model_not_found" | "insufficient_quota")) => code,
                Some(_) => "other", None => "none",
            },
        });
        self.seen = self.seen.saturating_add(1);
        if self.events.len() == MAX_EVENTS {
            self.events.pop_front();
        }
        self.events.push_back(event);
        events::classify_event_failure(payload).map(|failure| failure.status)
    }

    fn snapshot(&self, class: &'static str, status: u16, origin: &'static str) -> Value {
        let mut doc = self.metadata.clone();
        doc["elapsed_ms"] = json!(self.started.elapsed().as_millis() as u64);
        doc["failure"] = json!({"class":class,"status":status,"origin":origin});
        doc["events"] = json!(self.events);
        doc["events_seen"] = json!(self.seen);
        doc["events_dropped"] = json!(self.seen.saturating_sub(self.events.len() as u64));
        doc["semantic_output_seen"] = json!(self.semantic);
        doc["terminal_success_seen"] = json!(self.terminal_success);
        doc
    }

    fn error_snapshot(&self, error: &CodexError) -> Value {
        let origin = match error.origin {
            CodexErrorOrigin::Http => "http",
            CodexErrorOrigin::WebSocket => "websocket",
            CodexErrorOrigin::WebSocketHandshake => "websocket_handshake",
            CodexErrorOrigin::Auth => "auth",
            CodexErrorOrigin::BufferedHttp => "buffered_http",
            CodexErrorOrigin::BufferedWebSocket => "buffered_websocket",
        };
        let class = match error.detail.as_deref() {
            Some(super::websocket::WEBSOCKET_MISSING_TERMINAL_DETAIL) => "missing_terminal",
            Some(super::websocket::WEBSOCKET_RESPONSE_START_TIMEOUT_DETAIL) => {
                "response_start_timeout"
            }
            Some(super::websocket::WEBSOCKET_KEEPALIVE_FAILURE_DETAIL) => "keepalive_failure",
            _ if error.status == 401 => "authentication",
            _ if error.status == 429 => "rate_limit",
            _ if error.status == 0 => "transport",
            _ => "upstream",
        };
        let mut doc = self.snapshot(class, error.status, origin);
        // The WebSocket adapter constructs this numeric-only prefix locally.
        // Never serialize a remote message, detail or close reason.
        if let Some(numbers) = error.message.strip_prefix("WebSocket close metadata: ")
            && let Some((code, rest)) = numbers.split_once(' ')
            && let Some(length) = rest.split(' ').next()
            && let (Ok(code), Ok(length)) = (code.parse::<u16>(), length.parse::<u64>())
        {
            doc["failure"]["close_code"] = json!(code);
            doc["failure"]["close_reason_bytes"] = json!(length);
        }
        doc
    }

    pub(super) fn error(&mut self, error: &CodexError) {
        self.save(self.error_snapshot(error));
    }

    pub(super) fn fail(&mut self, class: &'static str, status: u16) {
        let origin = self.metadata["transport"].as_str().unwrap_or("other");
        // Transport values originate exclusively from static call-site strings.
        let origin = match origin {
            "http" => "http",
            "websocket" => "websocket",
            _ => "other",
        };
        self.save(self.snapshot(class, status, origin));
    }

    fn save(&mut self, doc: Value) {
        if self.captured {
            return;
        }
        self.captured = true;
        if PENDING_WRITES
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
                (count < 8).then_some(count + 1)
            })
            .is_err()
        {
            crate::logging::create_logger("codex").warn("flight_recorder_queue_full", None);
            return;
        }
        tokio::task::spawn_blocking(move || {
            struct Permit;
            impl Drop for Permit {
                fn drop(&mut self) {
                    PENDING_WRITES.fetch_sub(1, Ordering::AcqRel);
                }
            }
            let _permit = Permit;
            let directory = crate::paths::state_dir()
                .join("diagnostics")
                .join("codex-flight-recorder");
            match persist_in(&directory, &doc, MAX_FILES, MAX_TOTAL_BYTES) {
                Ok(path) => crate::logging::create_logger("codex").info(
                    "flight_recorder_saved",
                    Some(serde_json::Map::from_iter([("path".into(), json!(path))])),
                ),
                Err(error) => crate::logging::create_logger("codex").warn(
                    "flight_recorder_write_failed",
                    Some(serde_json::Map::from_iter([(
                        "kind".into(),
                        json!(format!("{:?}", error.kind())),
                    )])),
                ),
            }
        });
    }
}

fn fingerprint(value: &str) -> String {
    format!("{:x}", Sha256::digest(value.as_bytes()))
}

fn is_link(metadata: &fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return true;
        }
    }
    metadata.file_type().is_symlink()
}

fn owned_files(directory: &Path) -> io::Result<Vec<(PathBuf, u64, SystemTime)>> {
    let mut files = Vec::new();
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        let name = entry.file_name();
        let Some(id) = name
            .to_str()
            .and_then(|name| name.strip_prefix("ccp-flight-"))
            .and_then(|name| name.strip_suffix(".json"))
        else {
            continue;
        };
        if !uuid::Uuid::parse_str(id).is_ok_and(|uuid| uuid.to_string() == id) {
            continue;
        }
        let metadata = fs::symlink_metadata(entry.path())?;
        if metadata.is_file() && !is_link(&metadata) {
            files.push((entry.path(), metadata.len(), metadata.modified()?));
        }
    }
    files.sort_by_key(|(path, _, modified)| (*modified, path.clone()));
    Ok(files)
}

fn persist_in(
    directory: &Path,
    doc: &Value,
    max_files: usize,
    max_bytes: u64,
) -> io::Result<PathBuf> {
    let bytes = serde_json::to_vec_pretty(doc)?;
    if bytes.len() > MAX_FILE_BYTES || bytes.len() as u64 > max_bytes || max_files == 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "diagnostic capture exceeds budget",
        ));
    }
    let _guard = WRITER
        .lock()
        .map_err(|_| io::Error::other("diagnostic writer poisoned"))?;
    // Refuse a substituted diagnostics directory or recorder directory.
    for dir in [directory.parent(), Some(directory)].into_iter().flatten() {
        match fs::symlink_metadata(dir) {
            Ok(metadata) if is_link(&metadata) || !metadata.is_dir() => {
                return Err(io::Error::other(
                    "diagnostic directory is not a regular directory",
                ));
            }
            Ok(_) => (),
            Err(error) if error.kind() == io::ErrorKind::NotFound => fs::create_dir_all(dir)?,
            Err(error) => return Err(error),
        }
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(directory, fs::Permissions::from_mode(0o700))?;
    }
    let id = uuid::Uuid::new_v4();
    let temporary = directory.join(format!("ccp-flight-{id}.tmp"));
    let destination = directory.join(format!("ccp-flight-{id}.json"));
    let result = (|| {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temporary, &destination)?;
        let files = owned_files(directory)?;
        let mut count = files.len();
        let mut total = files.iter().map(|(_, size, _)| size).sum::<u64>();
        for (path, size, _) in files {
            if count <= max_files && total <= max_bytes {
                break;
            }
            if path == destination {
                continue;
            }
            fs::remove_file(path)?;
            count -= 1;
            total -= size;
        }
        Ok(destination)
    })();
    if result.is_err() {
        let _ = fs::remove_file(temporary);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn ring_retains_last_events_and_never_free_form_content() {
        let mut recorder = Recorder::new(
            "secret request",
            Some("secret session"),
            "secret model",
            "websocket",
            7,
            Some("secret continuation"),
        );
        for i in 0..200 {
            recorder.observe(&json!({"type":"response.output_text.delta", "delta":"PRIVATE_CANARY", "sequence_number":i}));
        }
        recorder.observe(&json!({"type":"PRIVATE_CANARY", "error":{"message":"PRIVATE_CANARY"}}));
        let doc = recorder.snapshot("translator", 502, "websocket");
        let serialized = serde_json::to_string(&doc).unwrap();
        assert!(!serialized.contains("PRIVATE_CANARY"));
        assert!(!serialized.contains("secret"));
        assert_eq!(doc["events"].as_array().unwrap().len(), 128);
        assert_eq!(doc["events_dropped"], 73);
        assert!(serialized.len() < MAX_FILE_BYTES);
        assert_eq!(doc["semantic_output_seen"], true);
    }

    #[test]
    fn usage_and_terminal_state_are_preserved_without_output() {
        let mut recorder = Recorder::new("r", None, "m", "http", 1, None);
        recorder.observe(&json!({"type":"response.completed","response":{"id":"PRIVATE_CANARY", "usage":{"input_tokens":351678,"output_tokens":800}, "output":[{"text":"PRIVATE_CANARY"}]}}));
        let doc = recorder.snapshot("empty_completion", 502, "http");
        assert_eq!(doc["terminal_success_seen"], true);
        assert_eq!(doc["events"][0]["input_tokens"], 351678);
        assert!(!doc.to_string().contains("PRIVATE_CANARY"));
    }

    #[test]
    fn persistence_is_bounded_and_preserves_unrelated_files() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("keep.json"), "user evidence").unwrap();
        let doc = serde_json::json!({"safe":true});
        for _ in 0..6 {
            persist_in(dir.path(), &doc, 3, 1024).unwrap();
        }
        assert_eq!(owned_files(dir.path()).unwrap().len(), 3);
        assert_eq!(
            std::fs::read_to_string(dir.path().join("keep.json")).unwrap(),
            "user evidence"
        );
        let large = json!({"safe":"a".repeat(600)});
        persist_in(dir.path(), &large, 100, 1024).unwrap();
        persist_in(dir.path(), &large, 100, 1024).unwrap();
        assert_eq!(owned_files(dir.path()).unwrap().len(), 1);
        assert!(
            persist_in(
                dir.path(),
                &json!({"large":"a".repeat(MAX_FILE_BYTES)}),
                100,
                10 * 1024 * 1024
            )
            .is_err()
        );
    }

    #[test]
    fn successful_completion_is_discarded_and_cancellation_does_not_create_failure() {
        let mut recorder = Recorder::new("r", None, "m", "http", 1, None);
        recorder.observe(&json!({"type":"response.completed"}));
        recorder.end_of_stream();
        assert!(!recorder.captured);
        drop(recorder);
        // Dropping a partial/cancelled request is deliberately not an error dump.
        drop(Recorder::new("r", None, "m", "http", 1, None));
    }

    #[test]
    fn close_snapshot_preserves_only_numeric_details_and_errors_remain_private() {
        let recorder = Recorder::new("r", None, "m", "websocket", 1, None);
        let mut error =
            CodexError::new(0, "WebSocket close metadata: 1008 14 PRIVATE_CANARY".into());
        error.detail = Some(super::super::websocket::WEBSOCKET_MISSING_TERMINAL_DETAIL.into());
        error.origin = CodexErrorOrigin::WebSocket;
        let doc = recorder.error_snapshot(&error);
        assert_eq!(doc["failure"]["close_code"], 1008);
        assert_eq!(doc["failure"]["close_reason_bytes"], 14);
        assert_eq!(doc["failure"]["class"], "missing_terminal");
        assert!(!doc.to_string().contains("PRIVATE_CANARY"));
        error.message = "PRIVATE_CANARY".into();
        error.detail = Some("PRIVATE_CANARY".into());
        assert!(
            !recorder
                .error_snapshot(&error)
                .to_string()
                .contains("PRIVATE_CANARY")
        );
    }

    #[test]
    fn write_failure_does_not_modify_existing_evidence() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("not-a-directory");
        fs::write(&file, "keep").unwrap();
        assert!(persist_in(&file, &json!({"safe":true}), 100, MAX_TOTAL_BYTES).is_err());
        assert_eq!(fs::read_to_string(file).unwrap(), "keep");
    }

    #[cfg(unix)]
    #[test]
    fn retention_does_not_follow_links() {
        let dir = tempfile::tempdir().unwrap();
        let external = tempfile::tempdir().unwrap();
        let file = external.path().join("keep");
        fs::write(&file, "keep").unwrap();
        std::os::unix::fs::symlink(
            &file,
            dir.path()
                .join(format!("ccp-flight-{}.json", uuid::Uuid::new_v4())),
        )
        .unwrap();
        persist_in(dir.path(), &json!({"safe":true}), 1, 1024).unwrap();
        assert_eq!(fs::read_to_string(file).unwrap(), "keep");
        let link = dir.path().join("linked");
        std::os::unix::fs::symlink(external.path(), &link).unwrap();
        assert!(persist_in(&link, &json!({"safe":true}), 1, 1024).is_err());
    }
}
