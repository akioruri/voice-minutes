# voice-minutes

A CLI tool that splits a long audio file (e.g. `.m4a`) into fixed-length
segments, transcribes each segment through OpenRouter's
`/audio/transcriptions` endpoint, stitches the results back into a single
transcript, and optionally calls a chat model to produce meeting minutes.

The default transcription model is `microsoft/mai-transcribe-2`; the default
summarization model is `minimax/minimax-m3`. Both can be changed in
`voice-minutes.toml`.

## Requirements

- `ffmpeg` on `PATH` (the tool shells out to it for segmentation).
- An OpenRouter API key — either in `voice-minutes.toml` (`[openrouter].api_key`)
  or in the `OPENROUTER_API_KEY` env var.

## Build

```sh
cargo build --release
./target/release/voice-minutes --help
```

## Usage

```sh
# 1. Just split (no network). Useful for previewing the segments.
voice-minutes split recording.m4a --segment-seconds 300

# 2. Transcribe.
voice-minutes transcribe recording.m4a --language zh

# 3. Transcribe and produce meeting minutes.
voice-minutes summarize recording.m4a
```

### Defaults

For `recording.m4a` next to the input file:

| Output            | Path                                  |
| ----------------- | ------------------------------------- |
| Segments          | `recording.segments/seg_000.wav`, ... |
| Transcript (text) | `recording.transcript.txt`            |
| Transcript (json) | `recording.transcript.json`           |
| Summary           | `recording.summary.md`                |

### Config

`voice-minutes.toml` is searched in order at:

1. `--config PATH` (if given)
2. `./voice-minutes.toml` (cwd)
3. `$XDG_CONFIG_HOME/voice-minutes/config.toml`
4. `~/.config/voice-minutes/config.toml`

All fields are optional — missing fields fall back to documented defaults. See
`config.toml` in the repo for a fully-populated example.
