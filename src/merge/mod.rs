//! Merge per-segment transcription results into the final text/JSON output.
//!
//! The merge algorithm and the timestamp formatter have specific rules that
//! the surrounding CLI documents elsewhere; the comments in each function
//! call out the exact behavior so it's locally checkable.

use serde_json::Value;

/// Format a seconds value as `HH:MM:SS.mmm`. The `HH:` prefix is omitted
/// when the value is below one hour.
pub fn format_ts(seconds: f64) -> String {
    let total_ms = (seconds * 1000.0).round() as i64;
    let h = total_ms / 3_600_000;
    let rem = total_ms.rem_euclid(3_600_000);
    let m = rem / 60_000;
    let rem = rem.rem_euclid(60_000);
    let s = rem / 1000;
    let ms = rem.rem_euclid(1000);
    if h != 0 {
        format!("{:02}:{:02}:{:02}.{:03}", h, m, s, ms)
    } else {
        format!("{:02}:{:02}.{:03}", m, s, ms)
    }
}

/// Merge a list of per-segment verbose_json responses into a single transcript
/// text.
///
/// `segment_seconds` is the fallback end time used when a response has no
/// `segments` array (or the array is empty).
pub fn merge_text(results: &[Value], segment_seconds: f64) -> String {
    let mut lines: Vec<String> = Vec::new();
    let mut cumulative = 0.0_f64;

    for res in results {
        let segs = res.get("segments").and_then(|v| v.as_array());

        // Determine the actual end of this segment for the cumulative offset.
        // We take the max `end` over the segments; only fall back to
        // segment_seconds when segments is absent or empty.
        let seg_end: f64 = match segs {
            Some(arr) if !arr.is_empty() => arr
                .iter()
                .filter_map(|s| s.get("end").and_then(|e| e.as_f64()))
                .fold(f64::NEG_INFINITY, f64::max),
            _ => segment_seconds,
        };
        let seg_end = if seg_end.is_finite() && seg_end > 0.0 {
            seg_end
        } else {
            segment_seconds
        };

        match segs {
            Some(arr) if !arr.is_empty() => {
                for s in arr {
                    let start = s.get("start").and_then(|v| v.as_f64()).unwrap_or(0.0);
                    let end = s.get("end").and_then(|v| v.as_f64()).unwrap_or(0.0);
                    let text = s.get("text").and_then(|v| v.as_str()).unwrap_or("").trim();
                    let line = format!(
                        "[{} -> {}] {}",
                        format_ts(start + cumulative),
                        format_ts(end + cumulative),
                        text
                    );
                    lines.push(line);
                }
            }
            _ => {
                // No `segments` (or empty): single-line fallback to res["text"].
                let text = res
                    .get("text")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .trim();
                if !text.is_empty() {
                    lines.push(text.to_string());
                }
            }
        }

        cumulative += seg_end;
    }

    // When no lines were produced, return an empty string (not a lone
    // trailing newline) so the caller can distinguish "empty" from
    // "single empty line".
    if lines.is_empty() {
        String::new()
    } else {
        let mut out = lines.join("\n");
        out.push('\n');
        out
    }
}

/// Serialize the per-segment verbose_json responses to the JSON output
/// format. Each top-level element of `results` becomes one element of the
/// output array — no offsets are applied, the original verbose_json is
/// preserved verbatim.
pub fn merge_json(results: &[Value]) -> String {
    // Indent with 2 spaces, write non-ASCII characters verbatim (the
    // hand-rolled emitter below) so the output stays close to what
    // `json.dumps(..., ensure_ascii=False)` would produce in Python.
    let mut out = String::new();
    out.push('[');
    out.push('\n');
    for (i, v) in results.iter().enumerate() {
        if i > 0 {
            out.push(',');
            out.push('\n');
        }
        out.push_str("  ");
        write_json_value(&mut out, v, 1);
    }
    if !results.is_empty() {
        out.push('\n');
    }
    out.push(']');
    out.push('\n');
    out
}

fn write_json_value(out: &mut String, v: &Value, indent: usize) {
    match v {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => out.push_str(&n.to_string()),
        Value::String(s) => write_json_string(out, s),
        Value::Array(arr) => {
            if arr.is_empty() {
                out.push_str("[]");
            } else {
                out.push('[');
                out.push('\n');
                for (i, item) in arr.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                        out.push('\n');
                    }
                    for _ in 0..=indent {
                        out.push_str("  ");
                    }
                    write_json_value(out, item, indent + 1);
                }
                out.push('\n');
                for _ in 0..indent {
                    out.push_str("  ");
                }
                out.push(']');
            }
        }
        Value::Object(obj) => {
            if obj.is_empty() {
                out.push_str("{}");
            } else {
                out.push('{');
                out.push('\n');
                let mut keys: Vec<&String> = obj.keys().collect();
                keys.sort();
                for (i, k) in keys.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                        out.push('\n');
                    }
                    for _ in 0..=indent {
                        out.push_str("  ");
                    }
                    write_json_string(out, k);
                    out.push_str(": ");
                    write_json_value(out, &obj[*k], indent + 1);
                }
                out.push('\n');
                for _ in 0..indent {
                    out.push_str("  ");
                }
                out.push('}');
            }
        }
    }
}

fn write_json_string(out: &mut String, s: &str) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\x08' => out.push_str("\\b"),
            '\x0c' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

/// Extract the basename of a path (file name with extension) as &str.
pub fn basename(p: &std::path::Path) -> &str {
    p.file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("<unknown>")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn ts_zero() {
        assert_eq!(format_ts(0.0), "00:00.000");
    }

    #[test]
    fn ts_just_under_one_hour() {
        // 3599.999s -> 59:59.999
        assert_eq!(format_ts(3599.999), "59:59.999");
    }

    #[test]
    fn ts_exactly_one_hour() {
        // 3600s -> 01:00:00.000
        assert_eq!(format_ts(3600.0), "01:00:00.000");
    }

    #[test]
    fn ts_over_one_hour() {
        // 3601.5s -> 01:00:01.500
        assert_eq!(format_ts(3601.5), "01:00:01.500");
    }

    #[test]
    fn ts_millisecond_rounding() {
        // 1.2344 -> 1.234; 1.2345 -> 1.235 (banker's rounding is *not* what
        // round() gives — Rust's f64::round rounds half-away-from-zero, so
        // 1.2345 -> 1.235).
        assert_eq!(format_ts(1.2344), "00:01.234");
    }

    #[test]
    fn merge_simple_two_segments() {
        let r1 = json!({
            "segments": [
                {"start": 0.0, "end": 1.5, "text": " hello "},
                {"start": 1.5, "end": 3.0, "text": " world"}
            ]
        });
        let r2 = json!({
            "segments": [
                {"start": 0.0, "end": 2.0, "text": "next"}
            ]
        });
        // seg_end for r1 = 3.0; cumulative offset for r2 = 3.0.
        let out = merge_text(&[r1, r2], 5.0);
        let expected = "\
[00:00.000 -> 00:01.500] hello
[00:01.500 -> 00:03.000] world
[00:03.000 -> 00:05.000] next
";
        assert_eq!(out, expected);
    }

    #[test]
    fn merge_uses_actual_seg_end_not_segment_seconds() {
        // seg_end is max(s["end"]), NOT the configured segment_seconds.
        // r1 ends at 2.7, segment_seconds=10 -> r2's offset must be 2.7, not 10.
        let r1 = json!({
            "segments": [{"start": 0.0, "end": 2.7, "text": "a"}]
        });
        let r2 = json!({
            "segments": [{"start": 0.0, "end": 1.0, "text": "b"}]
        });
        let out = merge_text(&[r1, r2], 10.0);
        assert!(
            out.contains("[00:02.700 -> 00:03.700] b"),
            "expected r2 start to be offset by 2.7, got:\n{}",
            out
        );
    }

    #[test]
    fn merge_falls_back_to_text_when_no_segments() {
        let r1 = json!({"text": "plain old text"});
        let out = merge_text(&[r1], 5.0);
        assert_eq!(out, "plain old text\n");
    }

    #[test]
    fn merge_falls_back_to_text_when_segments_empty() {
        let r1 = json!({"segments": [], "text": "fallback line"});
        let out = merge_text(&[r1], 5.0);
        assert_eq!(out, "fallback line\n");
    }

    #[test]
    fn merge_empty_results_returns_empty_string() {
        let out = merge_text(&[], 5.0);
        // Empty input -> "" (not "\n"): the caller can tell "no transcript"
        // apart from "a transcript with one empty line".
        assert_eq!(out, "");
    }

    #[test]
    fn merge_lines_format_exact_whitespace() {
        // The line format is "[start -> end] text" with single spaces
        // around the `->` arrow.
        let r1 = json!({
            "segments": [{"start": 0.0, "end": 1.0, "text": "x"}]
        });
        let out = merge_text(&[r1], 5.0);
        assert!(out.contains("[00:00.000 -> 00:01.000] x"));
    }
}
