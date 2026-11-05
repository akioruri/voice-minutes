use std::path::PathBuf;
use thiserror::Error;

/// Top-level error type for the CLI.
///
/// Each variant maps to a fixed exit code at the binary boundary (see
/// `main.rs`); the constructor / payload details are kept here so callers
/// can build rich errors without knowing the exit code.
#[derive(Debug, Error)]
pub enum AppError {
    #[error("config error: {0}")]
    Config(String),

    #[error("splitter error: {0}")]
    Splitter(String),

    #[error("transcribe error: {0}")]
    Transcribe(String),

    #[error("summarize error: {0}")]
    Summarize(String),
}

impl AppError {
    pub fn config<S: Into<String>>(msg: S) -> Self {
        AppError::Config(msg.into())
    }
    pub fn splitter<S: Into<String>>(msg: S) -> Self {
        AppError::Splitter(msg.into())
    }
    pub fn transcribe<S: Into<String>>(msg: S) -> Self {
        AppError::Transcribe(msg.into())
    }
    pub fn summarize<S: Into<String>>(msg: S) -> Self {
        AppError::Summarize(msg.into())
    }

    /// Exit code: 0 for `ConfigError`, 1 for any runtime/transcription/
    /// summarization failure. The CLI never invents other codes.
    pub fn exit_code(&self) -> i32 {
        match self {
            AppError::Config(_) => 2,
            AppError::Splitter(_) | AppError::Transcribe(_) | AppError::Summarize(_) => 1,
        }
    }
}

impl From<std::io::Error> for AppError {
    fn from(e: std::io::Error) -> Self {
        AppError::Splitter(e.to_string())
    }
}

/// Convenience: build a Splitter error describing an ffmpeg failure.
pub fn ffmpeg_not_found() -> AppError {
    AppError::splitter("ffmpeg not found on PATH. Install ffmpeg first.")
}

pub fn ffmpeg_failed(code: i32, stderr_or_stdout: &str) -> AppError {
    AppError::splitter(format!(
        "ffmpeg failed (exit {}): {}",
        code,
        stderr_or_stdout.trim_end()
    ))
}

pub fn ffmpeg_no_segments() -> AppError {
    AppError::splitter("ffmpeg produced no segments.")
}

pub fn input_not_found(p: &PathBuf) -> AppError {
    AppError::splitter(format!("Input file not found: {}", p.display()))
}
