//! One reloadable catalog shared by discovery, routing and request translation.
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
    time::SystemTime,
};

use anyhow::{Result, ensure};
use serde::Deserialize;

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct ModelEntry {
    id: String,
    #[serde(rename = "responsesLite")]
    responses_lite: bool,
}

#[derive(Default, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct CatalogFile {
    models: Vec<ModelEntry>,
    #[serde(rename = "codexCachePath")]
    codex_cache_path: Option<PathBuf>,
}

#[derive(Deserialize)]
struct CodexCache {
    models: Vec<CodexCacheEntry>,
}

#[derive(Deserialize)]
struct CodexCacheEntry {
    slug: String,
    visibility: Option<String>,
    use_responses_lite: Option<bool>,
}

fn valid_id(id: &str) -> bool {
    id.starts_with("gpt-")
        && id.len() > 4
        && !id.ends_with("-fast")
        && !id.ends_with("-ultrafast")
        && id
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"-_.".contains(&c))
}

fn parse_catalog(raw: &str) -> Result<CatalogFile> {
    let catalog: CatalogFile = serde_json::from_str(raw)?;
    let mut ids = std::collections::HashSet::new();
    for entry in &catalog.models {
        ensure!(valid_id(&entry.id), "invalid base GPT model ID");
        ensure!(ids.insert(&entry.id), "duplicate model ID");
    }
    Ok(catalog)
}

fn parse_codex_cache(raw: &str) -> Result<Vec<ModelEntry>> {
    let cache: CodexCache = serde_json::from_str(raw)?;
    Ok(cache
        .models
        .into_iter()
        .filter_map(|entry| {
            if entry.visibility.as_deref() != Some("list") || !valid_id(&entry.slug) {
                return None;
            }
            Some(ModelEntry {
                id: entry.slug,
                responses_lite: entry.use_responses_lite?,
            })
        })
        .collect())
}

// Both source files retain their last successfully parsed data on invalid edits.
struct CachedFile<T> {
    path: Option<PathBuf>,
    stamp: Option<(Option<SystemTime>, u64)>,
    value: T,
}

impl<T: Default> Default for CachedFile<T> {
    fn default() -> Self {
        Self {
            path: None,
            stamp: None,
            value: T::default(),
        }
    }
}

impl<T: Default> CachedFile<T> {
    fn load(&mut self, path: &Path, parse: fn(&str) -> Result<T>) -> &T {
        if self.path.as_deref() != Some(path) {
            *self = Self {
                path: Some(path.to_path_buf()),
                ..Self::default()
            };
        }
        let stamp = fs::metadata(path)
            .ok()
            .map(|meta| (meta.modified().ok(), meta.len()));
        if stamp != self.stamp {
            self.stamp = stamp;
            // Deletion retains last-good data; omission of the cache path disables discovery.
            if stamp.is_some() {
                match fs::read_to_string(path)
                    .map_err(anyhow::Error::from)
                    .and_then(|raw| parse(&raw))
                {
                    Ok(value) => self.value = value,
                    Err(_) => {
                        tracing::warn!(source = %path.display(), "invalid Codex model catalog update; retaining last valid data")
                    }
                }
            }
        }
        &self.value
    }
}

#[derive(Default)]
pub struct CatalogReader {
    local: CachedFile<CatalogFile>,
    discovered: CachedFile<Vec<ModelEntry>>,
}

impl CatalogReader {
    pub fn load(&mut self, path: &Path) -> BTreeMap<String, bool> {
        static DEFAULTS: OnceLock<CatalogFile> = OnceLock::new();
        let defaults = DEFAULTS.get_or_init(|| {
            parse_catalog(include_str!("codex-models.json")).expect("valid bundled Codex catalog")
        });
        let local = self.local.load(path, parse_catalog);
        let mut models: BTreeMap<String, bool> = defaults
            .models
            .iter()
            .map(|entry| (entry.id.clone(), entry.responses_lite))
            .collect();
        if let Some(cache_path) = &local.codex_cache_path {
            let cache_path = if cache_path.is_absolute() {
                cache_path.clone()
            } else {
                path.parent().unwrap_or(Path::new(".")).join(cache_path)
            };
            for entry in self.discovered.load(&cache_path, parse_codex_cache) {
                models.insert(entry.id.clone(), entry.responses_lite);
            }
        }
        for entry in &local.models {
            models.insert(entry.id.clone(), entry.responses_lite);
        }
        models
    }
}

pub fn catalog() -> BTreeMap<String, bool> {
    static READER: OnceLock<Mutex<CatalogReader>> = OnceLock::new();
    READER
        .get_or_init(|| Mutex::new(CatalogReader::default()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .load(&crate::paths::config_dir().join("codex-models.json"))
}

pub fn base_models() -> Vec<String> {
    catalog().into_keys().collect()
}

pub fn supported_models() -> Vec<String> {
    let mut models = Vec::new();
    for id in base_models() {
        models
            .extend(crate::providers::codex::translate::model_allowlist::tier_model_variants(&id));
        models.push(id);
    }
    models.sort_unstable();
    models
}
