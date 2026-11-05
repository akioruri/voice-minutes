use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::error::AppError;

const DEFAULT_BASE_URL: &str = "https://openrouter.ai/api/v1";
const DEFAULT_MODEL: &str = "microsoft/mai-transcribe-2";
const DEFAULT_SEGMENT_SECONDS: u32 = 3600;
const DEFAULT_RESPONSE_FORMAT: &str = "verbose_json";
const DEFAULT_TIMEOUT_SECONDS: f64 = 120.0;
const DEFAULT_MAX_RETRIES: u32 = 3;
const DEFAULT_MAX_CONCURRENT: u32 = 4;
const DEFAULT_SUMMARY_MODEL: &str = "minimax/minimax-m3";
const DEFAULT_SUMMARY_MAX_TOKENS: u32 = 16384;
const DEFAULT_SUMMARY_PROMPT: &str =
    "你是一名专业的会议纪要整理助手。请阅读用户提供的会议转写文本，输出一份结构化的会议���要";

#[derive(Debug, Clone, Deserialize, Default)]
#[serde(default)]
struct RawOpenRouter {
    api_key: Option<String>,
    base_url: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Default)]
#[serde(default)]
struct RawTranscription {
    model: Option<String>,
    segment_seconds: Option<u32>,
    language: Option<String>,
    response_format: Option<String>,
    timestamp_granularities: Option<Vec<String>>,
}

#[derive(Debug, Clone, Deserialize, Default)]
#[serde(default)]
struct RawHttp {
    timeout_seconds: Option<f64>,
    max_retries: Option<u32>,
    max_concurrent: Option<u32>,
}

#[derive(Debug, Clone, Deserialize, Default)]
#[serde(default)]
struct RawSummary {
    model: Option<String>,
    max_tokens: Option<u32>,
    prompt: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Default)]
#[serde(default)]
struct RawApp {
    openrouter: Option<RawOpenRouter>,
    transcription: RawTranscription,
    http: RawHttp,
    summary: RawSummary,
}

#[derive(Debug, Clone)]
pub struct OpenRouterConfig {
    pub api_key: Option<String>,
    pub base_url: String,
}

#[derive(Debug, Clone)]
pub struct TranscriptionConfig {
    pub model: String,
    pub segment_seconds: u32,
    pub language: Option<String>,
    pub response_format: String,
    pub timestamp_granularities: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct HttpConfig {
    pub timeout_seconds: f64,
    pub max_retries: u32,
    pub max_concurrent: u32,
}

#[derive(Debug, Clone)]
pub struct SummaryConfig {
    pub model: String,
    pub max_tokens: u32,
    pub prompt: String,
}

#[derive(Debug, Clone)]
pub struct AppConfig {
    pub openrouter: OpenRouterConfig,
    pub transcription: TranscriptionConfig,
    pub http: HttpConfig,
    pub summary: SummaryConfig,
    /// Path the config was loaded from (for diagnostics).
    pub source_path: Option<PathBuf>,
}

impl Default for TranscriptionConfig {
    fn default() -> Self {
        Self {
            model: DEFAULT_MODEL.to_string(),
            segment_seconds: DEFAULT_SEGMENT_SECONDS,
            language: None,
            response_format: DEFAULT_RESPONSE_FORMAT.to_string(),
            timestamp_granularities: vec!["segment".to_string()],
        }
    }
}

impl Default for OpenRouterConfig {
    fn default() -> Self {
        Self {
            api_key: None,
            base_url: DEFAULT_BASE_URL.to_string(),
        }
    }
}

impl Default for HttpConfig {
    fn default() -> Self {
        Self {
            timeout_seconds: DEFAULT_TIMEOUT_SECONDS,
            max_retries: DEFAULT_MAX_RETRIES,
            max_concurrent: DEFAULT_MAX_CONCURRENT,
        }
    }
}

impl Default for SummaryConfig {
    fn default() -> Self {
        Self {
            model: DEFAULT_SUMMARY_MODEL.to_string(),
            max_tokens: DEFAULT_SUMMARY_MAX_TOKENS,
            prompt: DEFAULT_SUMMARY_PROMPT.to_string(),
        }
    }
}

impl AppConfig {
    /// Load configuration from the first existing path in the search order:
    /// explicit `--config` arg, then `./voice-minutes.toml`, then the XDG
    /// config dir, then `~/.config/voice-minutes/config.toml`. If none
    /// exist, returns the full default configuration with no source path.
    pub fn load(explicit: Option<&Path>) -> Result<Self, AppError> {
        let candidates: Vec<PathBuf> = candidate_paths(explicit);

        for path in &candidates {
            if !path.exists() {
                continue;
            }
            let text = std::fs::read_to_string(path).map_err(|e| {
                AppError::config(format!("failed to read {}: {}", path.display(), e))
            })?;
            let raw: RawApp = toml::from_str(&text).map_err(|e| {
                AppError::config(format!("failed to parse {}: {}", path.display(), e))
            })?;
            return Ok(Self::from_raw(raw, Some(path.clone())));
        }

        Ok(Self::from_raw(RawApp::default(), None))
    }

    fn from_raw(raw: RawApp, source_path: Option<PathBuf>) -> Self {
        let openrouter_raw = raw.openrouter.unwrap_or_default();
        let transcription = TranscriptionConfig {
            model: raw
                .transcription
                .model
                .unwrap_or_else(|| DEFAULT_MODEL.to_string()),
            segment_seconds: raw
                .transcription
                .segment_seconds
                .unwrap_or(DEFAULT_SEGMENT_SECONDS),
            language: raw.transcription.language,
            response_format: raw
                .transcription
                .response_format
                .unwrap_or_else(|| DEFAULT_RESPONSE_FORMAT.to_string()),
            timestamp_granularities: raw
                .transcription
                .timestamp_granularities
                .unwrap_or_else(|| vec!["segment".to_string()]),
        };
        let http = HttpConfig {
            timeout_seconds: raw.http.timeout_seconds.unwrap_or(DEFAULT_TIMEOUT_SECONDS),
            max_retries: raw.http.max_retries.unwrap_or(DEFAULT_MAX_RETRIES),
            max_concurrent: raw
                .http
                .max_concurrent
                .unwrap_or(DEFAULT_MAX_CONCURRENT)
                .max(1),
        };
        let summary = SummaryConfig {
            model: raw
                .summary
                .model
                .unwrap_or_else(|| DEFAULT_SUMMARY_MODEL.to_string()),
            max_tokens: raw.summary.max_tokens.unwrap_or(DEFAULT_SUMMARY_MAX_TOKENS),
            prompt: raw
                .summary
                .prompt
                .unwrap_or_else(|| DEFAULT_SUMMARY_PROMPT.to_string()),
        };
        Self {
            openrouter: OpenRouterConfig {
                api_key: openrouter_raw.api_key,
                base_url: openrouter_raw
                    .base_url
                    .unwrap_or_else(|| DEFAULT_BASE_URL.to_string()),
            },
            transcription,
            http,
            summary,
            source_path,
        }
    }

    /// Resolve the effective API key: config first, then env. Returns `None`
    /// if neither is set.
    pub fn effective_api_key(&self) -> Option<String> {
        self.openrouter
            .api_key
            .clone()
            .or_else(|| std::env::var("OPENROUTER_API_KEY").ok())
    }
}

fn candidate_paths(explicit: Option<&Path>) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = Vec::new();
    if let Some(p) = explicit {
        out.push(p.to_path_buf());
    }
    out.push(PathBuf::from("voice-minutes.toml"));
    if let Some(xdg) = std::env::var_os("XDG_CONFIG_HOME") {
        if !xdg.is_empty() {
            out.push(PathBuf::from(xdg).join("voice-minutes").join("config.toml"));
        }
    }
    if let Some(home) = dirs::home_dir() {
        out.push(
            home.join(".config")
                .join("voice-minutes")
                .join("config.toml"),
        );
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn candidate_order_starts_with_explicit() {
        // SAFETY: tests in this module don't run in parallel; safe to mutate env.
        unsafe {
            std::env::remove_var("XDG_CONFIG_HOME");
        }
        let p = std::env::temp_dir().join("vm-not-relevant.toml");
        let cands = candidate_paths(Some(&p));
        assert_eq!(cands[0], p);
        assert_eq!(cands[1], PathBuf::from("voice-minutes.toml"));
    }

    #[test]
    fn empty_toml_uses_all_defaults() {
        let raw: RawApp = toml::from_str("").unwrap();
        let cfg = AppConfig::from_raw(raw, None);
        assert_eq!(cfg.transcription.model, DEFAULT_MODEL);
        assert_eq!(cfg.transcription.segment_seconds, DEFAULT_SEGMENT_SECONDS);
        assert!(cfg.transcription.language.is_none());
        assert_eq!(
            cfg.transcription.timestamp_granularities,
            vec!["segment".to_string()]
        );
        assert_eq!(cfg.openrouter.base_url, DEFAULT_BASE_URL);
        assert!(cfg.openrouter.api_key.is_none());
        assert_eq!(cfg.http.timeout_seconds, DEFAULT_TIMEOUT_SECONDS);
        assert_eq!(cfg.http.max_retries, DEFAULT_MAX_RETRIES);
        assert_eq!(cfg.http.max_concurrent, DEFAULT_MAX_CONCURRENT);
        assert_eq!(cfg.summary.model, DEFAULT_SUMMARY_MODEL);
        assert_eq!(cfg.summary.max_tokens, DEFAULT_SUMMARY_MAX_TOKENS);
        assert_eq!(cfg.summary.prompt, DEFAULT_SUMMARY_PROMPT);
    }

    #[test]
    fn partial_toml_fills_gaps_with_defaults() {
        let raw: RawApp = toml::from_str(
            r#"
            [openrouter]
            base_url = "https://example.test/v1"

            [transcription]
            language = "en"
            "#,
        )
        .unwrap();
        let cfg = AppConfig::from_raw(raw, None);
        assert_eq!(cfg.openrouter.base_url, "https://example.test/v1");
        assert_eq!(cfg.transcription.language.as_deref(), Some("en"));
        // Unspecified fields stay at defaults.
        assert_eq!(cfg.transcription.model, DEFAULT_MODEL);
        assert_eq!(cfg.transcription.segment_seconds, DEFAULT_SEGMENT_SECONDS);
    }

    #[test]
    fn empty_toml_does_not_set_language() {
        let cfg = AppConfig::from_raw(RawApp::default(), None);
        assert!(cfg.transcription.language.is_none());
    }

    #[test]
    fn max_concurrent_zero_clamps_to_one() {
        let raw: RawApp = toml::from_str(
            r#"
            [http]
            max_concurrent = 0
            "#,
        )
        .unwrap();
        let cfg = AppConfig::from_raw(raw, None);
        assert_eq!(cfg.http.max_concurrent, 1);
    }
}
