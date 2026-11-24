import SwiftUI

@main
struct VoiceMinutesApp: App {
    @State private var store: MeetingStore
    @State private var settings: AppSettings
    @State private var sync: CloudSyncController
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = MeetingStore()
        let settings = AppSettings()
        _store = State(initialValue: store)
        _settings = State(initialValue: settings)
        _sync = State(initialValue: CloudSyncController(store: store, settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(store)
                .environment(settings)
                .environment(sync)
                .environment(\.locale, settings.interfaceLanguage.locale)
                .task {
                    await sync.refresh()
                }
                .onChange(of: settings.syncEnabled) { _, _ in
                    Task { await sync.refresh() }
                }
                .onChange(of: settings.syncAudioEnabled) { _, _ in
                    sync.audioSyncPreferenceChanged()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await sync.refresh() }
                    }
                }
        }

        #if os(macOS)
        .defaultSize(width: 1_100, height: 760)
        .commands {
            LibraryCommands()
        }
        #endif

        // A settings window, opened from the App menu with Command-Comma,
        // instead of a modal sheet with its own Save and Cancel buttons.
        #if os(macOS)
        Settings {
            SettingsView()
                .environment(settings)
                .environment(sync)
        }
        #endif
    }
}

// MARK: - Menu bar commands

/// Recording and import are window-level commands, so they are also listed in
/// the menu bar where they can be reached with the keyboard alone.
struct LibraryCommands: Commands {
    @FocusedValue(\.toggleRecordingAction) private var toggleRecording
    @FocusedValue(\.importAudioAction) private var importAudio
    @FocusedValue(\.isRecording) private var isRecording

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(InterfaceLanguage.current.text("menu.importAudio")) {
                importAudio?()
            }
            .disabled(importAudio == nil)

            Button(
                InterfaceLanguage.current.text(
                    isRecording == true
                        ? "menu.stopRecording"
                        : "menu.startRecording"
                )
            ) {
                toggleRecording?()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(toggleRecording == nil)
        }
    }
}

// MARK: - Focused values

private struct ToggleRecordingActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct ImportAudioActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct IsRecordingKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var toggleRecordingAction: (() -> Void)? {
        get { self[ToggleRecordingActionKey.self] }
        set { self[ToggleRecordingActionKey.self] = newValue }
    }

    var importAudioAction: (() -> Void)? {
        get { self[ImportAudioActionKey.self] }
        set { self[ImportAudioActionKey.self] = newValue }
    }

    var isRecording: Bool? {
        get { self[IsRecordingKey.self] }
        set { self[IsRecordingKey.self] = newValue }
    }
}
