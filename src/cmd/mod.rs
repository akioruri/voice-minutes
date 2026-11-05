use std::path::{Path, PathBuf};

use clap::{Args, Parser, Subcommand};
use futures::stream::StreamExt;

use crate::config::AppConfig;
use crate::error::AppError;
use crate::io::http;
use crate::io::splitter;
use crate::merge;

/// Top-level CLI definition.
#[derive(Debug, Parser)]
#[command(
    name = "voice-minutes",
    version,
    about = "Transcribe long audio via OpenRouter and optionally summarize it.",
    disable_help_subcommand = true
)]
pub struct Cli {
    /// Explicit path to the config file. Overrides the default search order.
    #[arg(long, global = true)]
    pub config: Option<PathBuf>,

    #[command(subcommand)]
    pub command: Command,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    /// Split an audio file into segments without calling the API.
    Split(SplitArgs),
    /// Split an audio file and transcribe each segment.
    Transcribe(TranscribeArgs),
    /// Split, transcribe, and summarize.
    Summarize(SummarizeArgs),
}

#[derive(Debug, Args)]
pub struct SplitArgs {
    /// Input audio file.
    pub input: PathBuf,
    /// Where to write segment files. Default: `<input stem>.segments/` next to the input.
    #[arg(long)]
    pub segments_dir: Option<PathBuf>,
    /// Override the segment length (seconds) from the config.
    #[arg(long)]
    pub segment_seconds: Option<u32>,
}

#[derive(Debug, Args)]
pub struct TranscribeArgs {
    pub input: PathBuf,
    #[arg(long)]
    pub segments_dir: Option<PathBuf>,
    #[arg(long)]
    pub transcript: Option<PathBuf>,
    #[arg(long)]
    pub segment_seconds: Option<u32>,
    #[arg(long)]
    pub language: Option<String>,
    /// `text` (default) or `json`.
    #[arg(long, default_value = "text")]
    pub format: OutputFormat,
}

#[derive(Debug, Args)]
pub struct SummarizeArgs {
    pub input: PathBuf,
    #[arg(long)]
    pub segments_dir: Option<PathBuf>,
    #[arg(long)]
    pub transcript: Option<PathBuf>,
    #[arg(long)]
    pub summary: Option<PathBuf>,
    #[arg(long)]
    pub segment_seconds: Option<u32>,
    #[arg(long)]
    pub language: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutputFormat {
    Text,
    Json,
}

impl std::str::FromStr for OutputFormat {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "text" => Ok(Self::Text),
            "json" => Ok(Self::Json),
            other => Err(format!(
                "invalid format: {} (expected 'text' or 'json')",
                other
            )),
        }
    }
}

impl std::fmt::Display for OutputFormat {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Text => f.write_str("text"),
            Self::Json => f.write_str("json"),
        }
    }
}

// ---- Default path helpers -------------------------------------------------

/// `<input stem>.segments/` next to the input file.
pub fn default_segments_dir(input: &Path) -> PathBuf {
    let stem = input
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("output");
    let parent = input.parent().unwrap_or_else(|| Path::new("."));
    parent.join(format!("{}.segments", stem))
}

/// `<input stem>.transcript.txt` next to the input file.
pub fn default_transcript_path(input: &Path) -> PathBuf {
    let stem = input
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("output");
    let parent = input.parent().unwrap_or_else(|| Path::new("."));
    parent.join(format!("{}.transcript.txt", stem))
}

/// `<input stem>.summary.md` next to the input file.
pub fn default_summary_path(input: &Path) -> PathBuf {
    let stem = input
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("output");
    let parent = input.parent().unwrap_or_else(|| Path::new("."));
    parent.join(format!("{}.summary.md", stem))
}

/// Replace (or append) the extension of a path.
pub fn with_ext(path: &Path, ext: &str) -> PathBuf {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let stem = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("output");
    parent.join(format!("{}.{}", stem, ext))
}

// ---- Per-command implementations -----------------------------------------

fn require_api_key(cfg: &AppConfig) -> Result<String, AppError> {
    match cfg.effective_api_key() {
        Some(k) => Ok(k),
        None => Err(AppError::config(
            "OpenRouter API key is not set. Add it to voice-minutes.toml under ...",
        )),
    }
}

/// Run `split`: segment only, no API.
pub fn run_split(cfg: &AppConfig, args: &SplitArgs) -> Result<(), AppError> {
    let segments_dir = args
        .segments_dir
        .clone()
        .unwrap_or_else(|| default_segments_dir(&args.input));
    let segment_seconds = args
        .segment_seconds
        .unwrap_or(cfg.transcription.segment_seconds);

    let segments = splitter::segment_audio(&args.input, &segments_dir, segment_seconds)?;

    for s in &segments {
        println!("{}", s.display());
    }
    eprintln!(
        "wrote {} segment(s) to {}",
        segments.len(),
        segments_dir.display()
    );
    Ok(())
}

/// Resolve the output path for the transcript, honoring `--transcript` and
/// the chosen output format.
fn resolve_transcript_path(
    args_transcript: Option<&PathBuf>,
    format: OutputFormat,
    default_text: &Path,
) -> PathBuf {
    match format {
        OutputFormat::Text => args_transcript
            .cloned()
            .unwrap_or_else(|| default_text.to_path_buf()),
        OutputFormat::Json => {
            let base = args_transcript
                .cloned()
                .unwrap_or_else(|| default_text.to_path_buf());
            with_ext(&base, "json")
        }
    }
}

/// Apply CLI overrides to a config clone.
fn apply_overrides(cfg: &AppConfig, segment_seconds: u32, language: Option<&str>) -> AppConfig {
    let mut effective = cfg.clone();
    effective.transcription.segment_seconds = segment_seconds;
    if let Some(lang) = language {
        effective.transcription.language = Some(lang.to_string());
    }
    effective
}

/// Transcribe every segment concurrently and return the results in segment
/// order (not completion order). Concurrency is bounded by
/// `http.max_concurrent`. Progress is emitted to stderr as each segment
/// starts and finishes.
pub async fn transcribe_all(
    cfg: &AppConfig,
    api_key: &str,
    segments: Vec<PathBuf>,
) -> Result<Vec<serde_json::Value>, AppError> {
    let total = segments.len();
    let max_concurrent = cfg.http.max_concurrent as usize;

    eprintln!(
        "transcribing {} segment(s) (concurrency={})",
        total, max_concurrent
    );
    for (i, seg) in segments.iter().enumerate() {
        eprintln!("[{}/{}] queued {}", i + 1, total, merge::basename(seg));
    }

    // Pre-allocate slots so results land in their original index even when
    // the futures complete out of order.
    let mut slots: Vec<Option<serde_json::Value>> = (0..total).map(|_| None).collect();

    let stream = futures::stream::iter(segments.into_iter().enumerate().map(
        |(idx, seg)| async move {
            // Hold the segment path as a String (Sized) so the future type is
            // easy to pin. We re-parse into PathBuf inside the call.
            let seg_str = seg.to_string_lossy().into_owned();
            let result = http::transcribe_segment(cfg, &seg, api_key).await;
            (idx, seg_str, result)
        },
    ))
    // Bounded concurrency: at most `max_concurrent` requests in flight.
    .buffered(max_concurrent.max(1));

    futures::pin_mut!(stream);
    while let Some((idx, seg_str, result)) = stream.next().await {
        eprintln!("[{}/{}] finished {}", idx + 1, total, seg_str);
        match result {
            Ok(v) => slots[idx] = Some(v),
            Err(e) => return Err(e),
        }
    }

    Ok(slots.into_iter().map(|s| s.unwrap()).collect())
}

/// Run `transcribe`: segment + per-segment API (concurrent) + merge + write.
pub async fn run_transcribe(cfg: &AppConfig, args: &TranscribeArgs) -> Result<String, AppError> {
    let api_key = require_api_key(cfg)?;
    let segments_dir = args
        .segments_dir
        .clone()
        .unwrap_or_else(|| default_segments_dir(&args.input));
    let segment_seconds = args
        .segment_seconds
        .unwrap_or(cfg.transcription.segment_seconds);

    let effective = apply_overrides(cfg, segment_seconds, args.language.as_deref());
    let segments = splitter::segment_audio(&args.input, &segments_dir, segment_seconds)?;

    let default_text = default_transcript_path(&args.input);
    let transcript_path =
        resolve_transcript_path(args.transcript.as_ref(), args.format, &default_text);

    let results = transcribe_all(&effective, &api_key, segments).await?;

    match args.format {
        OutputFormat::Text => {
            let txt = merge::merge_text(&results, segment_seconds as f64);
            write_output(&transcript_path, &txt)?;
            Ok(txt)
        }
        OutputFormat::Json => {
            let js = merge::merge_json(&results);
            write_output(&transcript_path, &js)?;
            Ok(String::new())
        }
    }
}

/// Run `summarize`: segment + transcribe (concurrent) + summarize + write.
pub async fn run_summarize(cfg: &AppConfig, args: &SummarizeArgs) -> Result<(), AppError> {
    let api_key = require_api_key(cfg)?;
    let segments_dir = args
        .segments_dir
        .clone()
        .unwrap_or_else(|| default_segments_dir(&args.input));
    let segment_seconds = args
        .segment_seconds
        .unwrap_or(cfg.transcription.segment_seconds);

    let effective = apply_overrides(cfg, segment_seconds, args.language.as_deref());
    let segments = splitter::segment_audio(&args.input, &segments_dir, segment_seconds)?;

    let transcript_path = args
        .transcript
        .clone()
        .unwrap_or_else(|| default_transcript_path(&args.input));

    let results = transcribe_all(&effective, &api_key, segments).await?;

    let merged = merge::merge_text(&results, segment_seconds as f64);
    write_output(&transcript_path, &merged)?;

    if merged.trim().is_empty() {
        eprintln!("warning: empty transcript, skipping summary");
        return Ok(());
    }

    let summary_path = args
        .summary
        .clone()
        .unwrap_or_else(|| default_summary_path(&args.input));

    eprintln!("summarizing via {} ...", effective.summary.model);
    let summary_text = http::summarize_transcript(&effective, &merged, &api_key).await?;
    write_output(&summary_path, &summary_text)?;
    Ok(())
}

fn write_output(path: &Path, contents: &str) -> Result<(), AppError> {
    std::fs::write(path, contents)
        .map_err(|e| AppError::splitter(format!("write {}: {}", path.display(), e)))?;
    eprintln!("wrote {}", path.display());
    Ok(())
}
