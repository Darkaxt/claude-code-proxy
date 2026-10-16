//! Fictional policy events only; no OpenAI calls or rejected-operation replay.
use axum::{
    body::Body,
    http::{Request, StatusCode},
    response::Response,
};
use claude_code_proxy::{registry::Registry, server::app};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

async fn turn(session: &str, agent: Option<&str>, stream: bool, text: &str) -> Response {
    let mut request = Request::builder()
        .method("POST")
        .uri("/v1/messages")
        .header("content-type", "application/json")
        .header("x-claude-code-session-id", session);
    if let Some(agent) = agent {
        request = request.header("x-claude-code-agent-id", agent);
    }
    app(Arc::new(Registry::with_default_alias()))
        .oneshot(
            request
                .body(Body::from(
                    json!({
                        "model":"gpt-5.5", "max_tokens":64, "stream":stream,
                        "messages":[{"role":"user","content":text}]
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap()
}

fn success() -> String {
    [
        json!({"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"fixture-message"}}),
        json!({"type":"response.output_text.delta","output_index":0,"delta":"permitted fixture result"}),
        json!({"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"fixture-message","content":[{"type":"output_text","text":"permitted fixture result"}]}}),
        json!({"type":"response.completed","response":{"id":"fixture-response","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"permitted fixture result"}]}]}}),
    ].into_iter().map(|event|format!("data: {event}\n\n")).collect()
}

async fn consume(response: Response, policy: bool) {
    let status = response.status();
    if policy && status != StatusCode::OK {
        assert_eq!(
            response
                .headers()
                .get("x-should-retry")
                .and_then(|v| v.to_str().ok()),
            Some("false")
        );
    }
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    let body = String::from_utf8_lossy(&bytes);
    if policy {
        assert!(
            status == StatusCode::BAD_REQUEST
                || status == StatusCode::INTERNAL_SERVER_ERROR
                || status == StatusCode::UNAUTHORIZED
                || body.contains("event: error")
        );
        assert!(body.contains("fictional policy interruption"), "{body}");
    } else {
        assert_eq!(status, StatusCode::OK, "{body}");
    }
}

#[tokio::test]
async fn policy_notice_reaches_goal_turn_without_replay_and_is_owner_scoped() {
    let scratch = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(scratch.path().join("codex")).unwrap();
    let skill_path = scratch.path().join("SKILL.md");
    std::fs::write(&skill_path, "fictional skill-path delivery fixture").unwrap();
    std::fs::write(scratch.path().join("codex/auth.json"),json!({
        "access":"fixture-access","refresh":"fixture-refresh","expires":4102444800000_i64,"account_id":"fixture-account"
    }).to_string()).unwrap();
    // This integration-test executable has a single env-mutating test.
    unsafe {
        std::env::set_var("CCP_CONFIG_DIR", scratch.path());
        std::env::set_var("XDG_STATE_HOME", scratch.path());
        std::env::set_var("LOCALAPPDATA", scratch.path());
        std::env::set_var("CCP_CODEX_TRANSPORT", "http");
        std::env::set_var("CCP_CODEX_SERVER_COMPACTION", "false");
        std::env::set_var("NO_PROXY", "127.0.0.1,localhost");
        std::env::set_var("CCP_APPROACH_RECOVERY_SKILL_PATH", &skill_path);
    }
    let captured = Arc::new(Mutex::new(Vec::<Value>::new()));
    let mode = Arc::new(AtomicUsize::new(0));
    let captures = captured.clone();
    let http_mode = mode.clone();
    let upstream = axum::Router::new().fallback(move |body: String| {
        let captures = captures.clone();
        let mode = http_mode.clone();
        async move {
            let request: Value = serde_json::from_str(&body).unwrap();
            let mut captures = captures.lock().unwrap();
            let policy = captures.len().is_multiple_of(4);
            captures.push(request);
            if policy && mode.load(Ordering::SeqCst) >= 2 {
                return Response::builder().status(if mode.load(Ordering::SeqCst) == 3 { 401 } else { 500 }).header("content-type","application/json")
                    .body(Body::from(json!({"error":{"code":"cyber_policy","message":"fictional policy interruption"}}).to_string())).unwrap();
            }
            let body = if policy {
                let prefix = if mode.load(Ordering::SeqCst) == 1 {
                    success().split("\n\n").take(2).map(|s|format!("{s}\n\n")).collect::<String>()
                } else { String::new() };
                format!("{prefix}data: {}\n\n",json!({"type":"response.failed","response":{"status":"failed","error":{"code":"cyber_policy","message":"fictional policy interruption"}}}))
            } else { success() };
            Response::builder().header("content-type","text/event-stream").body(Body::from(body)).unwrap()
        }
    });
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    unsafe {
        std::env::set_var(
            "CCP_CODEX_BASE_URL",
            format!("http://{}", listener.local_addr().unwrap()),
        );
    }
    let http_url = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        axum::serve(listener, upstream).await.unwrap();
    });
    let ws_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let ws_url = format!("http://{}", ws_listener.local_addr().unwrap());
    let ws_captures = captured.clone();
    let ws_mode = mode.clone();
    let ws_server = tokio::spawn(async move {
        loop {
            let (socket, _) = ws_listener.accept().await.unwrap();
            let captures = ws_captures.clone();
            let mode = ws_mode.clone();
            tokio::spawn(async move {
                let mut ws = tokio_tungstenite::accept_async(socket).await.unwrap();
                while let Some(Ok(message)) = ws.next().await {
                    let tokio_tungstenite::tungstenite::Message::Text(body) = message else {
                        continue;
                    };
                    let policy = {
                        let mut captures = captures.lock().unwrap();
                        let policy = captures.len().is_multiple_of(4);
                        captures.push(serde_json::from_str(&body).unwrap());
                        policy
                    };
                    let events = if policy {
                        let mut events: Vec<Value> = if mode.load(Ordering::SeqCst) == 1 {
                            success()
                                .split("\n\n")
                                .take(2)
                                .filter_map(|s| s.strip_prefix("data: "))
                                .map(|s| serde_json::from_str(s).unwrap())
                                .collect()
                        } else {
                            Vec::new()
                        };
                        let mut event = json!({"type":"response.failed","response":{"status":"failed","error":{"code":"cyber_policy","message":"fictional policy interruption"}}});
                        if mode.load(Ordering::SeqCst) == 3 {
                            event["status"] = json!(401);
                        }
                        events.push(event);
                        events
                    } else {
                        success()
                            .split("\n\n")
                            .filter_map(|s| s.strip_prefix("data: "))
                            .map(|s| serde_json::from_str(s).unwrap())
                            .collect()
                    };
                    for event in events {
                        if ws
                            .send(tokio_tungstenite::tungstenite::Message::Text(
                                event.to_string(),
                            ))
                            .await
                            .is_err()
                        {
                            return;
                        }
                    }
                }
            });
        }
    });
    for (transport, url, fixture_mode) in [
        ("http", &http_url, 0),
        ("websocket", &ws_url, 0),
        ("http", &http_url, 1),
        ("websocket", &ws_url, 1),
        ("http", &http_url, 2),
        ("http", &http_url, 3),
        ("websocket", &ws_url, 3),
    ] {
        mode.store(fixture_mode, Ordering::SeqCst);
        unsafe {
            std::env::set_var("CCP_CODEX_TRANSPORT", transport);
            std::env::set_var("CCP_CODEX_BASE_URL", url);
        }
        for stream in [false, true] {
            let session = format!("ledger-fixture-{transport}-{fixture_mode}-{stream}");
            let offset = captured.lock().unwrap().len();
            consume(
                turn(&session, None, stream, "fictional read-only task").await,
                true,
            )
            .await;
            assert_eq!(
                captured.lock().unwrap().len(),
                offset + 1,
                "policy must not auto-retry"
            );
            consume(
                turn(
                    &session,
                    Some("other-agent"),
                    stream,
                    "continue independent work",
                )
                .await,
                false,
            )
            .await;
            // Goal's ordinary continuation is still a client-submitted Messages turn.
            consume(turn(&session, None, stream, "continue").await, false).await;
            consume(
                turn(&session, None, stream, "another permitted task").await,
                false,
            )
            .await;
            let requests = captured.lock().unwrap();
            assert!(
                !requests[offset + 1]["instructions"]
                    .as_str()
                    .unwrap_or("")
                    .contains("approach-recovery-ledger")
            );
            let instructions = requests[offset + 2]["instructions"].as_str().unwrap_or("");
            assert!(
                instructions.contains("approach-recovery-ledger"),
                "Goal turn did not receive recovery guidance: {instructions}"
            );
            assert!(instructions.contains("not new authorization"));
            assert!(instructions.contains("pause"));
            assert!(instructions.contains("Completed tool calls remain completed"));
            assert!(instructions.contains(&session));
            assert!(instructions.contains("Configured skill file"));
            assert!(
                !requests[offset + 3]["instructions"]
                    .as_str()
                    .unwrap_or("")
                    .contains("approach-recovery-ledger"),
                "successful terminal response must acknowledge delivery"
            );
        }
    }
    server.abort();
    ws_server.abort();
}
