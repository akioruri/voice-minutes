# Voice Minutes

English | [中文文档](README.zh.md)

Voice Minutes (Chinese display name: 语音纪要) turns meeting recordings into
searchable transcripts and actionable minutes on macOS and iOS: record →
transcribe → mark key moments → AI minutes and key-point analysis, synced
across your devices through iCloud.

## Features

- **Recording** — pause/resume, silence-aware chunking; files stay in the app
  sandbox.
- **Transcription** — Apple on-device Speech (offline, timestamped) or your own
  cloud AI provider.
- **Key-moment marks** — one tap while recording; marks appear in the transcript
  and can be analyzed by the LLM automatically (customizable prompt, on by
  default).
- **Key-point blocks** — add manually (button / Cmd+Enter) or convert from a
  time mark; each block is independent and can be analyzed on its own; manual
  and generated content are visually distinguished.
- **Minutes** — generate and regenerate with a prompt library: multiple custom
  prompts, a global default, per-folder defaults, and AI-assisted prompt
  generation (title included).
- **Export** — Markdown, SRT subtitles, PDF.
- **iCloud sync** — folders, minutes, transcripts, and key points across
  devices; recordings download on demand when you press play.
- **Localized UI** — Simplified Chinese, English, Japanese; AI output follows
  the UI language.

## Requirements

- macOS 26 / iOS 26 or later
- Xcode 27 to build from source

## Install

- **TestFlight** (recommended): install through the invite link provided by the
  developer, on macOS and iOS.
- **From source**: `open voice-minutes.xcodeproj`, then Cmd+R in Xcode.

## Getting Started

1. **Settings → Models**: choose transcription/summary providers and enter API
   keys (stored only in the local Keychain), or enable Apple on-device
   transcription.
2. **Settings → Analysis**: tune the key-point and mark-analysis prompts.
   **Settings → Prompts**: manage the minutes prompt library.
3. **Settings → General**: enable iCloud sync. All devices must sign in to the
   **same iCloud account**; TestFlight builds use the CloudKit production
   environment.
4. After recording, open the meeting to review the transcript, marks, and
   key-point blocks, generate minutes, or export.

## Privacy

- Recordings and transcripts live in the app sandbox; with sync enabled they
  are stored in **your own iCloud private database** — the developer cannot
  access them.
- API keys stay in each device's Keychain and never sync.
- AI requests go only to the provider you configure. No analytics, no tracking.

## Development

Repository conventions, sync architecture, and the distribution flow are
documented in [AGENTS.md](AGENTS.md).

```bash
# Archive for TestFlight (then Organizer → Distribute App)
xcodebuild -project voice-minutes.xcodeproj -scheme voice-minutes \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath ~/Library/Developer/Xcode/Archives/Mac.xcarchive \
  -allowProvisioningUpdates archive
```

- UI strings go through `InterfaceLanguage.text("key")`; add new keys to all
  three `Localizable.strings` files.
- Bump `CURRENT_PROJECT_VERSION` before every TestFlight upload.
- Sync diagnostics: the status detail line in Settings → General, or
  `/usr/bin/log show --predicate 'subsystem == "com.akioruri.voiceminutes"'`.
