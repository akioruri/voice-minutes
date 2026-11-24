# Repository Guidelines

## Project Overview

`voice-minutes` (display name Voice Minutes / 语音纪要) is a SwiftUI meeting-minutes
app for macOS and iOS: record audio, transcribe (on-device Speech or a cloud AI
provider), mark key moments, and generate LLM minutes plus per-block key-point
analysis. The library syncs across devices through CloudKit. Distribution is
**TestFlight only** — there is no DMG packaging script and no CI.

## Project Structure & Module Organization

`voice-minutes.xcodeproj` is an Xcode 27 **JSON-shaped project**
(`project.xcproj`), with one app target and scheme, both named `voice-minutes`
(Swift 5, no SwiftPM packages, no test target). Sources live under
`voice-minutes/`:

- `App/` — `VoiceMinutesApp.swift`, `AppSettings`, `AIProvider`, `APIKeyStore`
  (Keychain), `InterfaceLanguage`, `UbiquitousSettingsMirror` (KVS settings
  mirror; inert without the ubiquity entitlement, degrades to local settings).
- `Models/` — `MeetingModels.swift` (status, folder, record, transcript types),
  `MinutesPrompt.swift` (prompt library model), `SRTBuilder.swift`.
- `Stores/` — `MeetingStore.swift`, the `@Observable` root store for library and
  pipeline state; owns the on-disk library (`meetings.json`, `Meetings/`).
- `Services/Audio/` — recorder (silence-aware chunking), player.
- `Services/Transcription/` — `LocalSpeechTranscriber`, `CloudAIService`.
- `Services/Export/` — Markdown, SRT, PDF exporters.
- `Services/Sync/` — `CloudSyncController` (CKSyncEngine delegate),
  `LibrarySyncMapping` (record layout + zone), `LibraryMerge`.
- `Views/` — `Library/`, `Settings/` (General / Models / Analysis / Prompts),
  `Components/`.
- `Assets.xcassets`, `voice-minutes.icon`, `Info.plist` (`.srt`/`.md` UTIs), and
  `en`/`ja`/`zh-Hans` `.lproj/` with `Localizable.strings` + `InfoPlist.strings`.

## Build, Run & Distribution Commands

```bash
open voice-minutes.xcodeproj                        # open in Xcode (Cmd+R to run)
xcodebuild -project voice-minutes.xcodeproj -scheme voice-minutes \
  -configuration Debug build                       # CLI build
xcodebuild -project voice-minutes.xcodeproj -scheme voice-minutes \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath ~/Library/Developer/Xcode/Archives/Mac.xcarchive \
  -allowProvisioningUpdates archive
# same with -destination 'generic/platform=iOS' for the iOS archive
```

Upload archives via Xcode Organizer → Distribute App → TestFlight. Bump
`CURRENT_PROJECT_VERSION` for every upload (build numbers must be unique per
platform); `MARKETING_VERSION` is the user-visible version. Keep build
artifacts **outside the repository**: `.gitignore` is intentionally minimal
(`.DS_Store`, `xcuserdata`, `.build/`), so archives, logs, and staging
directories must never be written into the repo tree.

The app is sandboxed (bundle id `com.akioruri.voiceminutes`, team `727SCA59NY`).
Reset local state by deleting
`~/Library/Containers/com.akioruri.voiceminutes/Data/Library/Application Support/VoiceMinutes/`
(includes `meetings.json`, `sync-state.data`, and the zone-migration flag).
On Mac the dev build and the TestFlight build **share this container** — never
run both at once or they overwrite each other's sync state.

CloudKit environments: dev-signed builds talk to **Development**, TestFlight /
App Store builds to **Production**. The schema (record types `Meeting`,
`Folder`, `MeetingAudio`, `schemaVersion` 3) must be deployed to Production in
CloudKit Console before TF sync works. Container:
`iCloud.com.akioruri.voiceminutes`.

## Testing & Verification

There is no test target. Keep the build warning-free and verify changes with a
manual pass in the app. Local Speech throws
`LocalSpeechError.simulatorUnsupported` in the simulator — exercise
transcription and CloudKit on a real device or Mac. Sync failures are
diagnosable in Settings → General (status detail line) and via
`/usr/bin/log show --predicate 'subsystem == "com.akioruri.voiceminutes"'`
(`log` is a zsh builtin; always use the full path).

## Coding Style & Naming Conventions

Four-space indentation, spaces only. Types PascalCase (`MeetingStore`), members
camelCase (`loadLibrary`), enum cases camelCase with lowercase `String` raw
values. Group members with `// MARK: - Section` and document public APIs with
`///`. Failures use `enum <Feature>Error: LocalizedError` with messages resolved
through `InterfaceLanguage.text(...)`.

Strings are **not** SwiftUI `LocalizedStringKey`s: add each key to all three
`Localizable.strings` files and read it with
`InterfaceLanguage.current.text("key")`. Keys use dot-separated domains such as
`audio.pause` and `sync.status.unavailable`.

## Localization & App Naming (do not "fix" these)

- `PRODUCT_NAME` is `Voice Minutes` (with a space) and **must stay equal to the
  base `CFBundleDisplayName`**: Finder only substitutes localized names when
  the bundle filename matches the base display name, otherwise it treats the
  name as a user rename and shows the filename verbatim.
- Per-language names come from `InfoPlist.strings` (zh-Hans = 语音纪要,
  en/ja = Voice Minutes); `LSHasLocalizedDisplayName` is true. Never hardcode
  Chinese into `PRODUCT_NAME` or the base Info.plist.
- `ITSAppUsesNonExemptEncryption` is false (HTTPS / OS crypto only) so uploads
  skip the export-compliance question.

## Sync Architecture Rules

- CKSyncEngine with the custom zone `VoiceMinutesLibrary`
  (`LibrarySyncMapping.recordZoneID`). **Never save into `_defaultZone`**: the
  engine uploads there but never fetches it, which silently breaks downloads
  and reinstall restore.
- `migrateLegacyDefaultZoneRecords` copies pre-fix `_defaultZone` records into
  the custom zone once per device (flag file `sync-zone-migration-v1.done`);
  it addresses records by known local IDs because Production schemas guarantee
  no queryable index for full scans.
- `recordToSend` overlays local fields onto the cached server record to keep
  its change tag; `handleSent` re-queues `serverRecordChanged` failures.
  Preserve this conflict-recovery path.
- Keep `statusDetail` and `Logger` diagnostics on every failure path; they are
  the only window into device-only (TestFlight) sync problems.
- API keys never sync; the KVS settings mirror excludes device-local keys.

## Security & Configuration

API keys belong only in Keychain via `APIKeyStore` — never commit credentials
or `xcuserdata/`. The sandbox enables audio input, networking, user-selected
file access, and iCloud/CloudKit; new capabilities need the matching
`ENABLE_*` build setting / entitlement plus portal registration. The repo must
stay free of secrets and personal data: keys, certificates, provisioning
profiles, and user libraries live outside the tree.

## Commit & Pull Request Guidelines

Short imperative capitalized subjects, no trailing period
(`Add silence-aware audio chunking`). One purpose per PR; explain what changed
and why; flag new localization keys, Keychain/networking/sandbox changes;
attach screenshots for UI work. Branch from `main`; no CI — confirm the build
passes locally first.

## Agent-Specific Instructions

- Prefer the Xcode MCP tools; the workspace identifier changes between
  sessions, so call `XcodeListWorkspaces` first.
- MCP builds use Xcode's in-memory model while CLI `xcodebuild` reads disk;
  reopen the workspace after on-disk project edits.
- Add Swift files through Xcode's Add Files dialog or edit `project.xcproj`
  using its `target-membership` structure; use `AddInfoPlist` /
  `UpdateTargetBuildSetting` for plist keys and build settings.
- Quote paths containing spaces (`Voice Minutes.app`); signing, archiving, and
  keychain commands need escalated permissions.
