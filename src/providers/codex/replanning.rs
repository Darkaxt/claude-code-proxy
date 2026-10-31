//! Observations delivered on a later client turn, never a policy retry loop.
use std::{
    collections::BTreeMap,
    fs,
    io::{self, Read},
    path::{Path, PathBuf},
    sync::Mutex,
};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::{client::CodexError, events, translate::request::ResponsesRequest};
use crate::request_identity::ConversationIdentity;

const MAX_OWNERS: usize = 256;
const MAX_STATE_BYTES: usize = 128 * 1024;
static PENDING: Mutex<Option<PendingStore>> = Mutex::new(None);

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Notice {
    id: String,
    request_id: String,
    observed_at: String,
}

/// Delivery acknowledgement is not proof that a model wrote a truthful ledger.
/// Keep the observation across failed/cancelled turns; clear only the delivered
/// generation after a valid terminal success. A later block always wins.
#[derive(Clone, Default)]
pub(super) struct ReplanContext {
    owner: Option<String>,
    attached_id: Option<String>,
    request_id: String,
    store_path: PathBuf,
    compact: bool,
}

impl ReplanContext {
    pub(super) fn prepare(
        owner: Option<&ConversationIdentity>,
        request_id: &str,
        compact: bool,
        request: &mut ResponsesRequest,
    ) -> Self {
        let key = owner.map(owner_fingerprint);
        let request_id = correlation(request_id);
        if compact {
            audit(
                "replanning_notice_skipped",
                key.as_deref(),
                None,
                &request_id,
                None,
                Some("compaction"),
            );
            return Self {
                request_id,
                compact: true,
                ..Self::default()
            };
        }
        let store_path = crate::paths::state_dir().join("replanning-pending.json");
        let notice = key.as_ref().and_then(|key| {
            with_pending(&store_path, |store| {
                store
                    .notices
                    .get(key)
                    .cloned()
                    .map(|notice| (notice, store.durable))
            })
        });
        if let (Some((notice, durable)), Some(owner)) = (&notice, owner) {
            let instructions = request.instructions.get_or_insert_with(String::new);
            instructions.push_str("\n\n");
            instructions.push_str(&notice.instructions(owner));
            audit(
                "replanning_notice_attached",
                key.as_deref(),
                Some(&notice.id),
                &request_id,
                Some(*durable),
                None,
            );
        }
        Self {
            owner: key,
            attached_id: notice.map(|(n, _)| n.id),
            request_id,
            store_path,
            compact: false,
        }
    }

    pub(super) fn observe_error(&self, error: &CodexError) {
        if error.cyber_policy {
            self.observe_policy();
        }
    }

    pub(super) fn observe_payload(&self, payload: &serde_json::Value) {
        if events::classify_event_failure(payload).is_some_and(|failure| failure.cyber_policy) {
            self.observe_policy();
        }
    }

    pub(super) fn observe_policy(&self) {
        let Some(owner) = &self.owner else {
            audit(
                "replanning_notice_skipped",
                None,
                None,
                &self.request_id,
                None,
                Some(if self.compact {
                    "compaction"
                } else {
                    "owner_unavailable"
                }),
            );
            return;
        };
        with_pending(&self.store_path, |store| {
            store.queue(
                owner.clone(),
                Notice {
                    id: uuid::Uuid::new_v4().to_string(),
                    request_id: self.request_id.clone(),
                    observed_at: time::OffsetDateTime::now_utc()
                        .format(&time::format_description::well_known::Rfc3339)
                        .unwrap(),
                },
            );
        });
    }

    pub(super) fn acknowledge_success(&self) {
        let (Some(owner), Some(id)) = (&self.owner, &self.attached_id) else {
            return;
        };
        with_pending(&self.store_path, |store| {
            store.acknowledge(owner, id, &self.request_id)
        });
    }
}

fn store_notice(map: &mut BTreeMap<String, Notice>, owner: String, notice: Notice) -> bool {
    if map.len() >= MAX_OWNERS && !map.contains_key(&owner) {
        return false;
    }
    map.insert(owner, notice);
    true
}

fn correlation(value: &str) -> String {
    if hex_fingerprint(value) {
        return value.to_owned();
    }
    uuid::Uuid::parse_str(value)
        .map(|id| id.to_string())
        .unwrap_or_else(|_| format!("{:x}", Sha256::digest(value.as_bytes())))
}

fn owner_fingerprint(owner: &ConversationIdentity) -> String {
    let value = match owner {
        ConversationIdentity::Main(session) => {
            serde_json::json!(["replanning-owner-v1", "main", session])
        }
        ConversationIdentity::Agent(session, agent) => {
            serde_json::json!(["replanning-owner-v1", "agent", session, agent])
        }
    };
    format!("{:x}", Sha256::digest(value.to_string().as_bytes()))
}

fn audit(
    event: &str,
    owner: Option<&str>,
    id: Option<&str>,
    request: &str,
    durable: Option<bool>,
    reason: Option<&str>,
) {
    crate::logging::create_logger("codex").info(
        event,
        Some(serde_json::Map::from_iter([
            ("build".into(), serde_json::json!(env!("CARGO_PKG_VERSION"))),
            ("owner_fingerprint".into(), serde_json::json!(owner)),
            ("notice_id".into(), serde_json::json!(id)),
            ("reqId".into(), serde_json::json!(correlation(request))),
            ("durable".into(), serde_json::json!(durable)),
            ("reason".into(), serde_json::json!(reason)),
            (
                "agent_ledger_compliance".into(),
                serde_json::json!("unverified"),
            ),
        ])),
    );
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct PendingFile {
    schema: u8,
    notices: BTreeMap<String, Notice>,
}

struct PendingStore {
    path: PathBuf,
    notices: BTreeMap<String, Notice>,
    disk_hash: Option<[u8; 32]>,
    writable: bool,
    durable: bool,
}

fn with_pending<R>(path: &Path, operation: impl FnOnce(&mut PendingStore) -> R) -> R {
    let mut guard = PENDING.lock().unwrap_or_else(|e| e.into_inner());
    if guard.as_ref().is_none_or(|store| store.path != path) {
        *guard = Some(PendingStore::load(path));
    }
    operation(guard.as_mut().unwrap())
}

fn hex_fingerprint(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn regular(metadata: &fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return false;
        }
    }
    !metadata.file_type().is_symlink()
}

fn read_state(path: &Path) -> io::Result<Option<Vec<u8>>> {
    if let Some(parent) = path.parent() {
        match fs::symlink_metadata(parent) {
            Ok(meta) if !meta.is_dir() || !regular(&meta) => {
                return Err(io::ErrorKind::InvalidData.into());
            }
            Ok(_) => (),
            Err(e) if e.kind() == io::ErrorKind::NotFound => (),
            Err(e) => return Err(e),
        }
    }
    let metadata = match fs::symlink_metadata(path) {
        Ok(meta) => meta,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e),
    };
    if !metadata.is_file() || !regular(&metadata) || metadata.len() > MAX_STATE_BYTES as u64 {
        return Err(io::ErrorKind::InvalidData.into());
    }
    let mut bytes = Vec::new();
    fs::File::open(path)?
        .take(MAX_STATE_BYTES as u64 + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() > MAX_STATE_BYTES {
        return Err(io::ErrorKind::InvalidData.into());
    }
    Ok(Some(bytes))
}

impl PendingStore {
    fn load(path: &Path) -> Self {
        let mut store = Self {
            path: path.to_owned(),
            notices: BTreeMap::new(),
            disk_hash: None,
            writable: true,
            durable: true,
        };
        let loaded = (|| -> io::Result<()> {
            let Some(bytes) = read_state(path)? else {
                return Ok(());
            };
            let file: PendingFile =
                serde_json::from_slice(&bytes).map_err(|_| io::ErrorKind::InvalidData)?;
            if file.schema != 1
                || file.notices.len() > MAX_OWNERS
                || file.notices.iter().any(|(key, notice)| {
                    !hex_fingerprint(key)
                        || uuid::Uuid::parse_str(&notice.id).is_err()
                        || !(uuid::Uuid::parse_str(&notice.request_id).is_ok()
                            || hex_fingerprint(&notice.request_id))
                        || time::OffsetDateTime::parse(
                            &notice.observed_at,
                            &time::format_description::well_known::Rfc3339,
                        )
                        .is_err()
                })
            {
                return Err(io::ErrorKind::InvalidData.into());
            }
            store.disk_hash = Some(Sha256::digest(&bytes).into());
            store.notices = file.notices;
            Ok(())
        })();
        if let Err(error) = loaded {
            store.writable = false;
            store.durable = false;
            audit(
                "replanning_notice_state_error",
                None,
                None,
                "",
                Some(false),
                Some(&format!("read:{:?}", error.kind())),
            );
        }
        for (owner, notice) in &store.notices {
            audit(
                "replanning_notice_restored",
                Some(owner),
                Some(&notice.id),
                &notice.request_id,
                Some(true),
                None,
            );
        }
        store
    }

    fn persist(&mut self, owner: &str, id: &str, request: &str) -> bool {
        let result = (|| -> io::Result<()> {
            if !self.writable {
                return Err(io::ErrorKind::InvalidData.into());
            }
            // Preserve unexpected external edits rather than overwriting them.
            let current =
                read_state(&self.path)?.map(|bytes| <[u8; 32]>::from(Sha256::digest(bytes)));
            if current != self.disk_hash {
                return Err(io::ErrorKind::InvalidData.into());
            }
            let file = PendingFile {
                schema: 1,
                notices: self.notices.clone(),
            };
            let bytes = serde_json::to_vec_pretty(&file).map_err(io::Error::other)?;
            if bytes.len() > MAX_STATE_BYTES {
                return Err(io::ErrorKind::InvalidData.into());
            }
            crate::auth::write_atomically(
                self.path.to_str().ok_or(io::ErrorKind::InvalidInput)?,
                &file,
            )
            .map_err(io::Error::other)?;
            self.disk_hash = Some(Sha256::digest(bytes).into());
            Ok(())
        })();
        self.durable = result.is_ok();
        if let Err(error) = result {
            audit(
                "replanning_notice_state_error",
                Some(owner),
                Some(id),
                request,
                Some(false),
                Some(&format!("write:{:?}", error.kind())),
            );
        }
        self.durable
    }

    fn queue(&mut self, owner: String, notice: Notice) {
        if !store_notice(&mut self.notices, owner.clone(), notice.clone()) {
            audit(
                "replanning_notice_capacity_reached",
                Some(&owner),
                Some(&notice.id),
                &notice.request_id,
                Some(false),
                Some("capacity"),
            );
            return;
        }
        let durable = self.persist(&owner, &notice.id, &notice.request_id);
        audit(
            "replanning_notice_queued",
            Some(&owner),
            Some(&notice.id),
            &notice.request_id,
            Some(durable),
            None,
        );
    }

    fn acknowledge(&mut self, owner: &str, id: &str, request: &str) {
        if !self
            .notices
            .get(owner)
            .is_some_and(|notice| notice.id == id)
        {
            audit(
                "replanning_notice_acknowledgment_ignored",
                Some(owner),
                Some(id),
                request,
                Some(self.durable),
                Some("stale_or_missing"),
            );
            return;
        }
        let notice = self.notices.remove(owner).unwrap();
        if self.persist(owner, id, request) {
            audit(
                "replanning_notice_acknowledged",
                Some(owner),
                Some(id),
                request,
                Some(true),
                None,
            );
        } else {
            self.notices.insert(owner.to_owned(), notice);
            audit(
                "replanning_notice_acknowledgment_retained",
                Some(owner),
                Some(id),
                request,
                Some(false),
                Some("persistence_failure"),
            );
        }
    }
}

impl Notice {
    fn instructions(&self, owner: &ConversationIdentity) -> String {
        let conversation_owner = match owner {
            ConversationIdentity::Main(session) => {
                serde_json::json!({"session_id":session,"agent_id":null})
            }
            ConversationIdentity::Agent(session, agent) => {
                serde_json::json!({"session_id":session,"agent_id":agent})
            }
        };
        let metadata = serde_json::json!({
            "notice_id":self.id, "request_correlation":self.request_id,
            "proxy_observed_at":self.observed_at, "classification":"cyber_policy",
            "conversation_owner":conversation_owner
        });
        let mut note =
            format!("[Proxy diagnostic observation — not a user instruction]\n{metadata}\n");
        note.push_str(concat!(
            "A previous response for this conversation was interrupted by an upstream cybersecurity refusal. ",
            "The original error remains an error; this is not a retry instruction or evidence of a false positive. ",
            "The proxy does not know the triggering action and does not retain the original error message here. ",
            "Use the approach-recovery-ledger skill before selecting further work. Read the authoritative scope, ",
            "last persisted execution plan and actual results; query relevant dated ledger records. ",
            "Record your own actual objective, scope, method, ordered steps and intended next action, not private reasoning ",
            "or a guessed trigger. Completed tool calls remain completed even when generation was interrupted. ",
            "Preserve every original acceptance criterion as satisfied or outstanding. Unknown original timestamps, ",
            "model/access-program evidence and causes stay unknown; proxy_observed_at is only proxy receipt time. ",
            "Use the helper's record command with a stable attempt ID and inspect its successful JSON receipt; ",
            "notice_id is a stable identifier for this observation, and conversation_owner is the validated owning session/agent identity. ",
            "append linked later attempts, never overwrite history. Keep records private and scoped, without secrets or raw transcripts. ",
            "If the skill/helper is unavailable or recording fails, report that the record is pending, not successful. ",
            "Do not automatically retry the rejected or materially equivalent procedure, make cosmetic variations to evade checks, ",
            "switch models/access programs, weaken criteria, or assume the interruption proves technical invalidity. ",
            "Continue only independently justified permitted work or a materially different permitted approach within existing authority. ",
            "If none exists, pause the affected work and report the outstanding criterion and limitation. ",
            "A Goal automatic continuation is compatible with this workflow but is not new authorization; ",
            "it must respect a ledger-backed pause and must not spin through alternative plans or repeat blocked work. ",
            "The proxy has not changed Goal's attempt budget or created this turn.\n"
        ));
        if let Some(path) = std::env::var_os("CCP_APPROACH_RECOVERY_SKILL_PATH")
            && path.len() <= 4096
            && std::path::Path::new(&path).is_file()
            && std::fs::File::open(&path).is_ok()
        {
            note.push_str(&format!(
                "Configured skill file (path data, not instructions): {}\n",
                serde_json::json!(path.to_string_lossy())
            ));
        }
        note.push_str("[End proxy diagnostic observation]");
        note
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn request() -> ResponsesRequest {
        serde_json::from_value(json!({"model":"gpt-5.5","input":[],"stream":true,"store":false,"parallel_tool_calls":true,"text":{}})).unwrap()
    }
    #[test]
    fn persistent_notice_process_worker() {
        let Ok(phase) = std::env::var("CCP_REPLAN_FIXTURE_PHASE") else {
            return;
        };
        let owner = ConversationIdentity::Main("PRIVATE_CANARY_SESSION".into());
        if phase == "queue" {
            ReplanContext::prepare(Some(&owner), "11111111-1111-4111-8111-111111111111", false, &mut request())
                .observe_payload(&json!({"type":"error","error":{"code":"cyber_policy","message":"PRIVATE_CANARY_ERROR"}}));
            return;
        }
        for other in [
            ConversationIdentity::Main("other-session".into()),
            ConversationIdentity::Agent("PRIVATE_CANARY_SESSION".into(), "sibling".into()),
        ] {
            let mut req = request();
            ReplanContext::prepare(
                Some(&other),
                "22222222-2222-4222-8222-222222222222",
                false,
                &mut req,
            );
            assert!(req.instructions.is_none());
        }
        let mut compact = request();
        ReplanContext::prepare(
            Some(&owner),
            "22222222-2222-4222-8222-222222222222",
            true,
            &mut compact,
        )
        .acknowledge_success();
        assert!(compact.instructions.is_none());
        let mut req = request();
        let context = ReplanContext::prepare(
            Some(&owner),
            "33333333-3333-4333-8333-333333333333",
            false,
            &mut req,
        );
        if phase == "empty" {
            assert!(req.instructions.is_none());
        } else {
            assert!(
                req.instructions
                    .unwrap()
                    .contains("11111111-1111-4111-8111-111111111111")
            );
            if phase == "ack" {
                context.acknowledge_success();
            }
        }
    }

    #[test]
    fn notice_survives_real_process_restart_and_persists_acknowledgment() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("claude-code-proxy/replanning-pending.json");
        for phase in ["queue", "cancel", "ack", "empty"] {
            let result = std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "providers::codex::replanning::tests::persistent_notice_process_worker",
                ])
                .env("CCP_REPLAN_FIXTURE_PHASE", phase)
                .env("XDG_STATE_HOME", dir.path())
                .env("LOCALAPPDATA", dir.path())
                .env("CCP_CONFIG_DIR", dir.path())
                .output()
                .unwrap();
            assert!(
                result.status.success(),
                "phase {phase}: {} {}",
                String::from_utf8_lossy(&result.stdout),
                String::from_utf8_lossy(&result.stderr)
            );
            assert!(
                state.is_file(),
                "queue must be durable before the process exits"
            );
            assert!(
                !std::fs::read_to_string(&state)
                    .unwrap()
                    .contains("PRIVATE_CANARY")
            );
        }
        let logs = std::fs::read_to_string(dir.path().join("claude-code-proxy/proxy.log")).unwrap();
        for event in [
            "replanning_notice_queued",
            "replanning_notice_restored",
            "replanning_notice_attached",
            "replanning_notice_acknowledged",
        ] {
            assert!(logs.contains(event), "missing lifecycle event {event}");
        }
        assert!(!logs.contains("PRIVATE_CANARY"));
    }
    #[test]
    fn pending_notice_survives_compaction_cancellation_and_stale_success() {
        let owner = ConversationIdentity::Main("replan-race-fixture".into());
        let first = ReplanContext::prepare(Some(&owner), "blocked-1", false, &mut request());
        first.observe_payload(
            &json!({"type":"response.failed","response":{"error":{"code":"cyber_policy"}}}),
        );
        let mut compact = request();
        ReplanContext::prepare(Some(&owner), "compact", true, &mut compact).acknowledge_success();
        assert!(compact.instructions.is_none());
        let mut cancelled = request();
        drop(ReplanContext::prepare(
            Some(&owner),
            "cancelled",
            false,
            &mut cancelled,
        ));
        assert!(
            cancelled
                .instructions
                .unwrap()
                .contains(&correlation("blocked-1"))
        );
        let old = ReplanContext::prepare(Some(&owner), "old", false, &mut request());
        old.observe_error(&CodexError::new(502, "fictional transport failure".into()));
        let mut after_failure = request();
        ReplanContext::prepare(Some(&owner), "after-failure", false, &mut after_failure);
        assert!(
            after_failure
                .instructions
                .unwrap()
                .contains(&correlation("blocked-1"))
        );
        old.observe_policy();
        old.acknowledge_success();
        let mut next = request();
        let current = ReplanContext::prepare(Some(&owner), "next", false, &mut next);
        assert!(next.instructions.unwrap().contains(&format!(
            "\"request_correlation\":\"{}\"",
            correlation("old")
        )));
        current.acknowledge_success();
        let mut cleared = request();
        ReplanContext::prepare(Some(&owner), "cleared", false, &mut cleared);
        assert!(cleared.instructions.is_none());
    }
    #[test]
    fn text_mentions_and_unknown_owners_do_not_create_notices() {
        let owner = ConversationIdentity::Main("replan-negative-fixture".into());
        let context = ReplanContext::prepare(Some(&owner), "text", false, &mut request());
        context
            .observe_payload(&json!({"type":"response.output_text.delta","delta":"cyber_policy"}));
        let mut next = request();
        ReplanContext::prepare(Some(&owner), "next", false, &mut next);
        assert!(next.instructions.is_none());
        let unknown = ReplanContext::prepare(None, "unknown", false, &mut request());
        unknown.observe_policy();
        assert!(unknown.owner.is_none());
    }
    #[test]
    fn capacity_preserves_existing_owners_and_accepts_their_newest_observation() {
        let mut map = BTreeMap::new();
        let notice = Notice {
            id: "first".into(),
            request_id: "fixture".into(),
            observed_at: "unknown-fixture-time".into(),
        };
        for i in 0..MAX_OWNERS {
            assert!(store_notice(&mut map, i.to_string(), notice.clone()));
        }
        assert!(!store_notice(&mut map, "overflow".into(), notice.clone()));
        let mut newer = notice.clone();
        newer.id = "newer".into();
        assert!(store_notice(&mut map, "0".into(), newer));
        assert_eq!(map.len(), MAX_OWNERS);
        assert_eq!(map["0"].id, "newer");
    }

    fn fixture_notice() -> Notice {
        Notice {
            id: uuid::Uuid::new_v4().to_string(),
            request_id: "11111111-1111-4111-8111-111111111111".into(),
            observed_at: "2026-10-29T11:00:00Z".into(),
        }
    }

    #[test]
    fn persistence_failures_retain_notices_and_preserve_changed_or_invalid_state() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pending.json");
        let owner = owner_fingerprint(&ConversationIdentity::Main("PRIVATE_CANARY".into()));
        let first = fixture_notice();
        let mut store = PendingStore::load(&path);
        store.queue(owner.clone(), first.clone());
        assert!(store.durable);
        // An external edit must survive, and an acknowledgment must not clear
        // the in-memory notice when its persisted removal cannot be verified.
        fs::write(&path, "PRIVATE_CANARY_CORRUPTION").unwrap();
        store.acknowledge(&owner, &first.id, &first.request_id);
        assert!(store.notices.contains_key(&owner));
        assert!(!store.durable);
        let mut invalid = PendingStore::load(&path);
        invalid.queue(owner.clone(), fixture_notice());
        assert!(!invalid.durable);
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            "PRIVATE_CANARY_CORRUPTION"
        );
        let blocker = dir.path().join("not-a-directory");
        fs::write(&blocker, "keep").unwrap();
        let mut unwritable = PendingStore::load(&blocker.join("pending.json"));
        unwritable.queue(owner.clone(), fixture_notice());
        assert!(!unwritable.durable && unwritable.notices.contains_key(&owner));
        assert_eq!(fs::read_to_string(&blocker).unwrap(), "keep");
    }

    #[test]
    fn snapshot_bounds_schema_and_owner_keys_are_validated_without_overwrite() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pending.json");
        let owner = owner_fingerprint(&ConversationIdentity::Main("session".into()));
        let agent = owner_fingerprint(&ConversationIdentity::Agent(
            "session".into(),
            "agent".into(),
        ));
        assert_ne!(owner, agent);
        let mut cases = vec![
            serde_json::to_vec(&json!({"schema":2,"notices":{}})).unwrap(),
            serde_json::to_vec(&json!({"schema":1,"notices":{},"message":"PRIVATE_CANARY"}))
                .unwrap(),
            serde_json::to_vec(&json!({"schema":1,"notices":{"PRIVATE_CANARY":fixture_notice()}}))
                .unwrap(),
            vec![b' '; MAX_STATE_BYTES + 1],
        ];
        let excessive = (0..=MAX_OWNERS)
            .map(|i| (correlation(&format!("owner-{i}")), fixture_notice()))
            .collect();
        cases.push(
            serde_json::to_vec(&PendingFile {
                schema: 1,
                notices: excessive,
            })
            .unwrap(),
        );
        for bytes in cases {
            fs::write(&path, &bytes).unwrap();
            let mut store = PendingStore::load(&path);
            assert!(!store.writable && store.notices.is_empty());
            store.queue(owner.clone(), fixture_notice());
            assert_eq!(fs::read(&path).unwrap(), bytes);
        }
    }

    #[test]
    fn persisted_newer_notice_survives_stale_acknowledgment() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pending.json");
        let owner = owner_fingerprint(&ConversationIdentity::Main("session".into()));
        let mut store = PendingStore::load(&path);
        let first = fixture_notice();
        let newer = fixture_notice();
        store.queue(owner.clone(), first.clone());
        store.queue(owner.clone(), newer.clone());
        store.acknowledge(&owner, &first.id, &first.request_id);
        let mut restarted = PendingStore::load(&path);
        assert_eq!(restarted.notices[&owner].id, newer.id);
        restarted.acknowledge(&owner, &newer.id, &newer.request_id);
        assert!(PendingStore::load(&path).notices.is_empty());
    }
}
