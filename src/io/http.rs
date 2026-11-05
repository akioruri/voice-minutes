use std::path::Path;
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use reqwest::Client;
use reqwest::header::{AUTHORIZATION, CONTENT_TYPE};
use serde_json::{Value, json};
use tokio::time::sleep;

use crate::config::AppConfig;
use crate::error::AppError;

const USER_AGENT: &str = concat!("voice-minutes/", env!("CARGO_PKG_VERSION"));

/// Per-attempt classification of the response.
struct AttemptOutcome {
    status: Option<u16>,
    body: String,
    permanent: bool,
    transport_err: Option<String>,
}

async fn perform_attempt(
    client: &Client,
    url: &str,
    api_key: &str,
    body: &Value,
) -> AttemptOutcome {
    let resp = client
        .post(url)
        .header(AUTHORIZATION, format!("Bearer {}", api_key))
        .header(CONTENT_TYPE, "application/json")
        .json(body)
        .send()
        .await;
    match resp {
        Err(e) => AttemptOutcome {
            status: None,
            body: String::new(),
            permanent: false,
            transport_err: Some(e.to_string()),
        },
        Ok(r) => {
            let status = r.status().as_u16();
            let body = r.text().await.unwrap_or_default();
            let permanent = matches!(status, 400..=428) || matches!(status, 430..=499);
            AttemptOutcome {
                status: Some(status),
                body,
                permanent,
                transport_err: None,
            }
        }
    }
}

fn audio_format_for(path: &Path) -> String {
    const ALLOWED: &[&str] = &["wav", "mp3", "m4a", "flac", "ogg", "webm", "aac"];
    let ext = path
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_lowercase();
    if ALLOWED.contains(&ext.as_str()) {
        ext
    } else {
        "wav".to_string()
    }
}

/// Transcribe a single audio segment with retries.
pub async fn transcribe_segment(
    cfg: &AppConfig,
    segment_path: &Path,
    api_key: &str,
) -> Result<Value, AppError> {
    let bytes = tokio::fs::read(segment_path)
        .await
        .map_err(|e| AppError::transcribe(e.to_string()))?;
    let b64 = BASE64.encode(&bytes);
    let fmt = audio_format_for(segment_path);

    let mut body = json!({
        "model": cfg.transcription.model,
        "input_audio": {
            "data": b64,
            "format": fmt,
        },
        "response_format": cfg.transcription.response_format,
    });
    if let Some(lang) = &cfg.transcription.language {
        body["language"] = json!(lang);
    }
    if cfg.transcription.response_format == "verbose_json"
        && !cfg.transcription.timestamp_granularities.is_empty()
    {
        body["timestamp_granularities"] = json!(cfg.transcription.timestamp_granularities);
    }

    let url = format!(
        "{}/audio/transcriptions",
        cfg.openrouter.base_url.trim_end_matches('/')
    );
    let name = crate::merge::basename(segment_path).to_string();

    let client = Client::builder()
        .user_agent(USER_AGENT)
        .timeout(Duration::from_secs_f64(cfg.http.timeout_seconds))
        .build()
        .map_err(|e| AppError::transcribe(e.to_string()))?;

    let total_attempts = cfg.http.max_retries + 1;
    let mut last_err = String::new();
    for attempt in 0..total_attempts {
        let outcome = perform_attempt(&client, &url, api_key, &body).await;
        if let Some(status) = outcome.status {
            if outcome.permanent {
                let preview: String = outcome.body.chars().take(500).collect();
                return Err(AppError::transcribe(format!(
                    "HTTP {} for {}: {}",
                    status, name, preview
                )));
            }
            if (200..300).contains(&status) {
                return serde_json::from_str(&outcome.body)
                    .map_err(|e| AppError::transcribe(format!("invalid JSON from server: {}", e)));
            }
            last_err = format!("HTTP {} (retryable)", status);
        } else if let Some(te) = outcome.transport_err {
            last_err = te;
        } else {
            last_err = "unknown transport failure".to_string();
        }
        if attempt + 1 < total_attempts {
            let backoff_secs = std::cmp::min(1u32 << attempt, 8);
            sleep(Duration::from_secs(backoff_secs as u64)).await;
        }
    }
    Err(AppError::transcribe(format!(
        "failed to transcribe {} after {} attempts: {}",
        name, total_attempts, last_err
    )))
}

/// Call the chat completions endpoint with retries to summarize a transcript.
pub async fn summarize_transcript(
    cfg: &AppConfig,
    transcript: &str,
    api_key: &str,
) -> Result<String, AppError> {
    let messages = build_summary_messages(&cfg.summary.prompt, transcript);

    let body = json!({
        "model": cfg.summary.model,
        "messages": messages,
        "temperature": 0.3,
        "max_tokens": cfg.summary.max_tokens,
    });

    let url = format!(
        "{}/chat/completions",
        cfg.openrouter.base_url.trim_end_matches('/')
    );

    let client = Client::builder()
        .user_agent(USER_AGENT)
        .timeout(Duration::from_secs_f64(cfg.http.timeout_seconds))
        .build()
        .map_err(|e| AppError::summarize(e.to_string()))?;

    let total_attempts = cfg.http.max_retries + 1;
    let mut last_err = String::new();
    for attempt in 0..total_attempts {
        let outcome = perform_attempt(&client, &url, api_key, &body).await;
        if let Some(status) = outcome.status {
            if outcome.permanent {
                let preview: String = outcome.body.chars().take(500).collect();
                return Err(AppError::summarize(format!("HTTP {}: {}", status, preview)));
            }
            if (200..300).contains(&status) {
                return parse_chat_response(&outcome.body, cfg.summary.max_tokens);
            }
            last_err = format!("HTTP {} (retryable)", status);
        } else if let Some(te) = outcome.transport_err {
            last_err = te;
        } else {
            last_err = "unknown transport failure".to_string();
        }
        if attempt + 1 < total_attempts {
            let backoff_secs = std::cmp::min(1u32 << attempt, 8);
            sleep(Duration::from_secs(backoff_secs as u64)).await;
        }
    }
    Err(AppError::summarize(format!(
        "failed to summarize after {} attempts: {}",
        total_attempts, last_err
    )))
}

fn build_summary_messages(prompt: &str, transcript: &str) -> Value {
    if prompt.contains("{{transcript}}") {
        let content = prompt.replace("{{transcript}}", transcript);
        json!([{"role": "user", "content": content}])
    } else {
        json!([
            {"role": "system", "content": prompt},
            {"role": "user", "content": transcript}
        ])
    }
}

fn parse_chat_response(body: &str, max_tokens: u32) -> Result<String, AppError> {
    let v: Value = serde_json::from_str(body)
        .map_err(|e| AppError::summarize(format!("invalid JSON from server: {}", e)))?;
    let choices = v
        .get("choices")
        .and_then(|c| c.as_array())
        .ok_or_else(|| AppError::summarize(format!("unexpected response shape: {}", v)))?;
    let first = choices
        .first()
        .ok_or_else(|| AppError::summarize(format!("unexpected response shape: {}", v)))?;
    let content = first
        .get("message")
        .and_then(|m| m.get("content"))
        .and_then(|c| c.as_str())
        .ok_or_else(|| AppError::summarize(format!("unexpected response shape: {}", v)))?
        .to_string();
    if let Some(fr) = first.get("finish_reason").and_then(|x| x.as_str()) {
        match fr {
            "length" => eprintln!(
                "warning: response truncated by max_tokens={}; raise [summary].max_tokens in voice-minutes.toml if the output is cut off",
                max_tokens
            ),
            "content_filter" => {
                eprintln!("warning: response stopped by the provider's content filter")
            }
            _ => {}
        }
    }
    Ok(content)
}
