use std::path::{Path, PathBuf};
use std::process::Command;

use crate::error::{
    AppError, ffmpeg_failed, ffmpeg_no_segments, ffmpeg_not_found, input_not_found,
};

/// Wipe the directory if it exists, then `mkdir -p` it.
pub fn reset_dir(dir: &Path) -> std::io::Result<()> {
    if dir.exists() {
        std::fs::remove_dir_all(dir)?;
    }
    std::fs::create_dir_all(dir)?;
    Ok(())
}

/// Segment an input audio file using ffmpeg's `segment` muxer.
///
///  - Recursively delete `--segments-dir` (if it exists), then `mkdir -p`.
///  - Invoke ffmpeg with the documented argument set.
///  - Return sorted list of produced `seg_*.wav` paths.
pub fn segment_audio(
    input: &Path,
    segments_dir: &Path,
    segment_seconds: u32,
) -> Result<Vec<PathBuf>, AppError> {
    if !input.exists() {
        return Err(input_not_found(&input.to_path_buf()));
    }

    reset_dir(segments_dir).map_err(|e| AppError::splitter(e.to_string()))?;

    let output_pattern = segments_dir.join("seg_%03d.wav");
    let output_pattern_str = output_pattern.to_str().ok_or_else(|| {
        AppError::splitter(format!(
            "non-utf8 output path: {}",
            output_pattern.display()
        ))
    })?;

    let mut cmd = Command::new("ffmpeg");
    cmd.args(["-hide_banner", "-loglevel", "error", "-y", "-i"])
        .arg(input)
        .args([
            "-ar",
            "16000",
            "-ac",
            "1",
            "-c:a",
            "pcm_s16le",
            "-f",
            "segment",
            "-segment_time",
            &segment_seconds.to_string(),
            "-reset_timestamps",
            "1",
        ])
        .arg(output_pattern_str);

    // Use spawn + wait so we can surface a clean error if ffmpeg is missing
    // (Command::status would also work, but on some platforms it doesn't
    // distinguish "not found" from "exited non-zero" cleanly).
    let output = match cmd.output() {
        Ok(o) => o,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Err(ffmpeg_not_found()),
        Err(e) => return Err(AppError::splitter(e.to_string())),
    };

    if !output.status.success() {
        let code = output.status.code().unwrap_or(-1);
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        let combined = if !stderr.trim().is_empty() {
            stderr.to_string()
        } else {
            stdout.to_string()
        };
        return Err(ffmpeg_failed(code, &combined));
    }

    let mut segments: Vec<PathBuf> = std::fs::read_dir(segments_dir)
        .map_err(|e| AppError::splitter(e.to_string()))?
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| {
            p.is_file()
                && p.extension().and_then(|s| s.to_str()) == Some("wav")
                && p.file_name()
                    .and_then(|s| s.to_str())
                    .is_some_and(|n| n.starts_with("seg_"))
        })
        .collect();

    if segments.is_empty() {
        return Err(ffmpeg_no_segments());
    }

    // Sort by filename so the caller can rely on a stable, lexicographic
    // order (seg_000.wav, seg_001.wav, ...).
    segments.sort_by(|a, b| {
        a.file_name()
            .and_then(|s| s.to_str())
            .cmp(&b.file_name().and_then(|s| s.to_str()))
    });

    Ok(segments)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reset_dir_wipes_existing() {
        let tmp = tempfile::tempdir().unwrap();
        let d = tmp.path().join("sub");
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join("leftover.txt"), "old").unwrap();
        reset_dir(&d).unwrap();
        assert!(d.exists());
        assert!(std::fs::read_dir(&d).unwrap().next().is_none());
    }
}
