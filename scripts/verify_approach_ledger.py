"""Fictional, isolated integration fixture for an external ledger skill.

No network, live threads, safety-check provocation, settings edits or model calls.
The caller owns the exact scratch folder and its reviewed cleanup.
"""
import argparse
import copy
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--skill-path", type=Path, required=True)
    parser.add_argument("--scratch", type=Path, required=True)
    args = parser.parse_args()
    bundle = args.skill_path.resolve().parent
    helper = bundle / "scripts/invoke_approach_recovery_ledger.py"
    assert helper.is_file(), "selected installed helper is missing"
    args.scratch.mkdir(parents=True, exist_ok=False)
    ledger = args.scratch / "fictional-ledger.sqlite3"

    def call(*command, failure=None):
        result = subprocess.run(
            [sys.executable, "-B", str(helper), "--ledger", str(ledger), *command],
            text=True, capture_output=True, check=False,
        )
        output = json.loads(result.stdout)
        if failure:
            assert result.returncode != 0 and output.get("failure_kind") == failure, output
        else:
            assert result.returncode == 0 and output.get("ok") is True, output
        return output

    empty = call("search", "--query", "parser reference")
    assert not ledger.exists(), "read-only lookup must not create storage"
    entry = json.loads((bundle / "examples/attempt.json").read_text(encoding="utf-8"))
    entry["attempt_id"] = "fixture-interrupted-001"
    entry["thread_id"] = "fictional-thread-alpha"
    entry["attempt_time_source"] = "event"
    # Real read-only fixture operation completes before the fictional signal.
    fixture = args.scratch / "records.json"
    fixture.write_text(json.dumps({"field": "reference-value"}), encoding="utf-8")
    entry["attempted_at"] = datetime.now(timezone.utc).isoformat()
    read_result = json.loads(fixture.read_text(encoding="utf-8"))
    assert isinstance(read_result, dict)
    entry["interrupted_at"] = datetime.now(timezone.utc).isoformat()
    entry["interruption"].update({
        "kind": "cyber_policy", "code": "cyber_policy",
        "message": "Fictional cyber_policy interruption after completed fixture read",
        "cause_confidence": "unknown", "cause": None,
    })
    original = args.scratch / "attempt.json"
    original.write_text(json.dumps(entry), encoding="utf-8")
    receipt = call("record", "--input", str(original))
    duplicate = call("record", "--input", str(original))
    assert duplicate.get("already_recorded") is True, duplicate
    # Separate helper process represents another thread's shared-history query.
    found = call("search", "--query", "parser reference", "--limit", "10")
    assert "fixture-interrupted-001" in json.dumps(found)
    history = call("show", "--attempt-id", "fixture-interrupted-001")
    raw = json.dumps(history)
    assert '"tool_outcome": "completed"' in raw
    assert '"outcome": "interrupted"' in raw
    assert '"cause": null' in raw and '"cyber_access_program": "unknown"' in raw
    conflict = copy.deepcopy(entry)
    conflict["lesson"] = "Conflicting rewrite must not replace history"
    conflict_path = args.scratch / "conflict.json"
    conflict_path.write_text(json.dumps(conflict), encoding="utf-8")
    call("record", "--input", str(conflict_path), failure="immutable_conflict")
    # A genuinely completed comparison in this inert fixture satisfies all
    # original criteria. No narrower source-only claim or rejected replay.
    comparison_started_at = datetime.now(timezone.utc).isoformat()
    assert read_result == {"field": "reference-value"}
    later = copy.deepcopy(entry)
    later.update({
        "attempt_id": "fixture-completed-002", "thread_id": "fictional-thread-beta",
        "attempted_at": comparison_started_at,
        "interrupted_at": None, "outcome": "completed", "interruption": None,
        "previous_attempt_id": entry["attempt_id"], "relationship": "supersedes",
        "satisfied_criteria": entry["plan"]["acceptance_criteria"], "outstanding_criteria": [],
        "next_decision": {"action": "resolved", "rationale": "Both inert fixture criteria verified", "next_step": "Preserve both historical records"},
    })
    later["execution"].update({"summary": "Read and comparison completed against inert fixture", "evidence": ["fictional-evidence://beta/comparison"]})
    later_path = args.scratch / "completed.json"
    later_path.write_text(json.dumps(later), encoding="utf-8")
    call("record", "--input", str(later_path))
    old = call("show", "--attempt-id", entry["attempt_id"])
    new = call("show", "--attempt-id", later["attempt_id"])
    assert "fixture-completed-002" in json.dumps(old)
    assert "fixture-interrupted-001" in json.dumps(new)
    assert '"outcome": "interrupted"' in json.dumps(old)
    print(json.dumps({"ok": True, "helper": str(helper), "checks": [
        "missing-ledger read is non-mutating", "completed read retained across interruption",
        "exact fictional code and unknown trigger", "cross-process shared-history query",
        "stable-ID idempotency and conflicting rewrite rejection",
        "criteria-preserving linked completion with both historical records readable",
    ], "live_model_compliance_verified": False, "real_inference_requests": 0}))


if __name__ == "__main__":
    main()
