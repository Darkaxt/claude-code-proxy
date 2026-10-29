//! Observations delivered on a later client turn, never a policy retry loop.
use std::{collections::HashMap, sync::Mutex};

use super::{client::CodexError, events, translate::request::ResponsesRequest};
use crate::request_identity::ConversationIdentity;

const MAX_OWNERS: usize = 256;
static PENDING: Mutex<Option<HashMap<ConversationIdentity, Notice>>> = Mutex::new(None);

#[derive(Clone)]
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
    owner: Option<ConversationIdentity>,
    attached_id: Option<String>,
    request_id: String,
}

impl ReplanContext {
    pub(super) fn prepare(
        owner: Option<&ConversationIdentity>,
        request_id: &str,
        compact: bool,
        request: &mut ResponsesRequest,
    ) -> Self {
        if compact {
            return Self::default();
        }
        let notice = owner.and_then(|owner| {
            PENDING
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .as_ref()
                .and_then(|map| map.get(owner))
                .cloned()
        });
        if let (Some(notice), Some(owner)) = (&notice, owner) {
            let instructions = request.instructions.get_or_insert_with(String::new);
            instructions.push_str("\n\n");
            instructions.push_str(&notice.instructions(owner));
        }
        Self {
            owner: owner.cloned(),
            attached_id: notice.map(|n| n.id),
            request_id: request_id.to_owned(),
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
            return;
        };
        let mut pending = PENDING.lock().unwrap_or_else(|e| e.into_inner());
        let map = pending.get_or_insert_with(HashMap::new);
        if !store_notice(
            map,
            owner.clone(),
            Notice {
                id: uuid::Uuid::new_v4().to_string(),
                request_id: self.request_id.clone(),
                observed_at: time::OffsetDateTime::now_utc()
                    .format(&time::format_description::well_known::Rfc3339)
                    .unwrap(),
            },
        ) {
            crate::logging::create_logger("codex").warn("replanning_notice_capacity_reached", None);
        }
    }

    pub(super) fn acknowledge_success(&self) {
        let (Some(owner), Some(id)) = (&self.owner, &self.attached_id) else {
            return;
        };
        let mut pending = PENDING.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(map) = pending.as_mut()
            && map.get(owner).is_some_and(|notice| &notice.id == id)
        {
            map.remove(owner);
        }
    }
}

fn store_notice(
    map: &mut HashMap<ConversationIdentity, Notice>,
    owner: ConversationIdentity,
    notice: Notice,
) -> bool {
    if map.len() >= MAX_OWNERS && !map.contains_key(&owner) {
        return false;
    }
    map.insert(owner, notice);
    true
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
        assert!(cancelled.instructions.unwrap().contains("blocked-1"));
        let old = ReplanContext::prepare(Some(&owner), "old", false, &mut request());
        old.observe_error(&CodexError::new(502, "fictional transport failure".into()));
        let mut after_failure = request();
        ReplanContext::prepare(Some(&owner), "after-failure", false, &mut after_failure);
        assert!(after_failure.instructions.unwrap().contains("blocked-1"));
        old.observe_policy();
        old.acknowledge_success();
        let mut next = request();
        let current = ReplanContext::prepare(Some(&owner), "next", false, &mut next);
        assert!(
            next.instructions
                .unwrap()
                .contains("\"request_correlation\":\"old\"")
        );
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
        let mut map = HashMap::new();
        let notice = Notice {
            id: "first".into(),
            request_id: "fixture".into(),
            observed_at: "unknown-fixture-time".into(),
        };
        for i in 0..MAX_OWNERS {
            assert!(store_notice(
                &mut map,
                ConversationIdentity::Main(i.to_string()),
                notice.clone()
            ));
        }
        assert!(!store_notice(
            &mut map,
            ConversationIdentity::Main("overflow".into()),
            notice.clone()
        ));
        let mut newer = notice.clone();
        newer.id = "newer".into();
        assert!(store_notice(
            &mut map,
            ConversationIdentity::Main("0".into()),
            newer
        ));
        assert_eq!(map.len(), MAX_OWNERS);
        assert_eq!(map[&ConversationIdentity::Main("0".into())].id, "newer");
    }
}
