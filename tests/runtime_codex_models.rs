use claude_code_proxy::codex_models::CatalogReader;
use std::fs;

#[test]
fn runtime_model_updates_reach_registry_messages_and_openai_translation() {
    use claude_code_proxy::{
        Registry,
        config::AliasProvider,
        providers::codex::{
            chat_completions::request::translate_request,
            native::validate_native_request_model,
            translate::model_allowlist::{
                assert_allowed_model, resolve_model_request, uses_responses_lite,
            },
        },
    };
    let dir = tempfile::tempdir().unwrap();
    let previous = std::env::var_os("CCP_CONFIG_DIR");
    // Only this test in the separate integration-test binary changes process env.
    unsafe {
        std::env::set_var("CCP_CONFIG_DIR", dir.path());
    }
    struct RestoreEnv(Option<std::ffi::OsString>);
    impl Drop for RestoreEnv {
        fn drop(&mut self) {
            unsafe {
                match &self.0 {
                    Some(value) => std::env::set_var("CCP_CONFIG_DIR", value),
                    None => std::env::remove_var("CCP_CONFIG_DIR"),
                }
            }
        }
    }
    let _restore = RestoreEnv(previous);
    let registry = Registry::new(AliasProvider::Codex);
    assert!(
        registry
            .provider_for_model("gpt-test-future-sol", None)
            .is_none()
    );
    let path = dir.path().join("codex-models.json");
    fs::write(
        &path,
        r#"{"models":[{"id":"gpt-test-future-sol","responsesLite":true}]}"#,
    )
    .unwrap();
    for id in [
        "gpt-test-future-sol",
        "gpt-test-future-sol-fast",
        "gpt-test-future-sol[1m]",
    ] {
        assert_eq!(
            registry.provider_for_model(id, None).unwrap().name(),
            "codex"
        );
    }
    assert!(
        registry
            .supported_models_for("codex")
            .contains(&"gpt-test-future-sol-fast".to_owned())
    );
    assert!(assert_allowed_model("gpt-test-future-sol").is_ok());
    assert!(uses_responses_lite("gpt-test-future-sol"));
    assert_eq!(
        resolve_model_request("gpt-test-future-sol-fast").model,
        "gpt-test-future-sol"
    );
    assert!(
        validate_native_request_model(&serde_json::json!({"model":"gpt-test-future-sol-fast"}))
            .is_ok()
    );
    let chat = translate_request(serde_json::json!({"model":"gpt-test-future-sol-fast","messages":[{"role":"user","content":"test"}]})).unwrap();
    assert_eq!(chat.model, "gpt-test-future-sol");
    assert!(chat.use_responses_lite);
    fs::write(&path, "{bad").unwrap();
    assert!(
        registry
            .provider_for_model("gpt-test-future-sol", None)
            .is_some()
    );
    fs::write(&path, r#"{"models":[]}"#).unwrap();
    assert!(
        registry
            .provider_for_model("gpt-test-future-sol", None)
            .is_none()
    );
    assert!(assert_allowed_model("gpt-test-future-sol").is_err());
}

#[test]
fn invalid_manual_metadata_does_not_widen_the_catalog() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("codex-models.json");
    let mut reader = CatalogReader::default();
    for invalid in [
        r#"{"models":[{"id":"gpt-metadata-missing"}]}"#,
        r#"{"models":[{"id":"gpt-invalid-fast","responsesLite":true}]}"#,
        r#"{"models":[{"id":"claude-unrelated","responsesLite":true}]}"#,
        r#"{"models":[{"id":"gpt-duplicate","responsesLite":true},{"id":"gpt-duplicate","responsesLite":false}]}"#,
    ] {
        fs::write(&path, invalid).unwrap();
        let models = reader.load(&path);
        assert!(!models.contains_key("gpt-metadata-missing"));
        assert!(!models.contains_key("gpt-invalid-fast"));
        assert!(!models.contains_key("claude-unrelated"));
        assert!(!models.contains_key("gpt-duplicate"));
    }
}

#[test]
fn runtime_catalog_reloads_models_and_retains_last_good_on_invalid_update() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("codex-models.json");
    let mut reader = CatalogReader::default();
    let initial = reader.load(&path);
    assert!(initial.contains_key("gpt-6.1-sol"));
    fs::write(
        &path,
        r#"{"models":[{"id":"gpt-future-sol","responsesLite":true}]}"#,
    )
    .unwrap();
    let added = reader.load(&path);
    assert!(added["gpt-future-sol"]);
    fs::write(&path, "{broken").unwrap();
    assert!(reader.load(&path)["gpt-future-sol"]);
    fs::write(
        &path,
        r#"{"models":[{"id":"gpt-future-sol","responsesLite":false}]}"#,
    )
    .unwrap();
    assert!(!reader.load(&path)["gpt-future-sol"]);
    fs::remove_file(&path).unwrap();
    assert!(reader.load(&path).contains_key("gpt-future-sol"));
}

#[test]
fn codex_discovery_imports_visible_models_and_manual_metadata_wins() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("codex-models.json");
    let cache = dir.path().join("models_cache.json");
    fs::write(
        &cache,
        r#"{"models":[
        {"slug":"gpt-future-sol","visibility":"list","use_responses_lite":true},
        {"slug":"gpt-reserve","visibility":"hide","use_responses_lite":true},
        {"slug":"gpt-missing-metadata","visibility":"list"},
        {"slug":"gpt-5.5","visibility":"list","use_responses_lite":true}
    ]}"#,
    )
    .unwrap();
    fs::write(&path, serde_json::json!({"codexCachePath":cache,"models":[{"id":"gpt-5.5","responsesLite":false}]}).to_string()).unwrap();
    let mut reader = CatalogReader::default();
    let models = reader.load(&path);
    assert!(models["gpt-future-sol"]);
    assert!(!models.contains_key("gpt-reserve"));
    assert!(!models.contains_key("gpt-missing-metadata"));
    assert!(!models["gpt-5.5"]);
    fs::write(&cache, "{broken").unwrap();
    assert!(reader.load(&path).contains_key("gpt-future-sol"));
    fs::write(
        &cache,
        r#"{"models":[{"slug":"gpt-newer-sol","visibility":"list","use_responses_lite":false}]}"#,
    )
    .unwrap();
    let refreshed = reader.load(&path);
    assert!(!refreshed["gpt-newer-sol"]);
    assert!(!refreshed.contains_key("gpt-future-sol"));
}
