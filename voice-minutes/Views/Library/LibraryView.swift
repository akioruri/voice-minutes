import SwiftUI
import UniformTypeIdentifiers

/// Root navigation container for folders, meeting lists, and meeting details.
struct LibraryView: View {
    @Environment(MeetingStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(CloudSyncController.self) private var sync

    @State private var recorder = AudioRecorder()
    @State private var isImporting = false
    @State private var isShowingSettings = false
    @State private var recordingMeetingID: UUID?
    @State private var importFolderID: UUID?

    var body: some View {
        NavigationSplitView {
            FolderSidebarView(
                isRecording: recorder.isRecording,
                onSettings: {
                    isShowingSettings = true
                }
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } content: {
            MeetingListPane(
                selection: store.selectedLibrary,
                isRecording: recorder.isRecording,
                recordingDuration: recorder.duration,
                onImport: beginImport,
                onToggleRecording: toggleRecording,
                onMark: {
                    if let meetingID = recordingMeetingID {
                        store.addMark(to: meetingID, time: recorder.duration)
                    }
                }
            )
            .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 420)
        } detail: {
            if let meeting = store.selectedMeeting {
                MeetingDetailView(
                    meetingID: meeting.id,
                    // Only the meeting being recorded shows the recording
                    // state; browsing another meeting stays neutral.
                    isRecording: recorder.isRecording
                        && meeting.id == recordingMeetingID,
                    recordingDuration: recorder.duration,
                    onToggleRecording: toggleRecording,
                    onImport: {
                        importFolderID = meeting.folderID
                            ?? store.selectedFolderID
                            ?? store.folders.first?.id
                        isImporting = true
                    }
                )
            } else {
                ContentUnavailableView(
                    "meeting.select.title",
                    systemImage: "text.document",
                    description: Text("meeting.select.description")
                )
                .toolbar {
                    // Keep the same action buttons as a populated detail column
                    // so export and import stay reachable.
                    DetailToolbar(
                        isExportEnabled: false,
                        isImportEnabled: !store.isBusy,
                        onExport: { _ in },
                        onImport: beginImport
                    )
                }
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        #if os(iOS)
        // macOS opens Settings from the App menu (Command-Comma) through the
        // `Settings` scene, so only the phone and tablet builds need a sheet.
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
                .environment(settings)
                .environment(sync)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        #endif
        .alert(
            "error.operationFailed",
            isPresented: Binding(
                get: { store.lastError != nil },
                set: { isPresented in
                    if !isPresented {
                        store.clearError()
                    }
                }
            )
        ) {
            Button("common.ok", role: .cancel) {
                store.clearError()
            }
        } message: {
            Text(
                store.lastError
                    ?? InterfaceLanguage.current.text("error.unknown")
            )
        }
        .navigationSplitViewStyle(.balanced)
        #if os(iOS)
        // Choosing a folder on iPhone should land on that folder's list, not
        // push the previously selected meeting's detail: clear the meeting
        // selection whenever the library selection changes. Recording is
        // exempt: beginRecording also switches the library, and its new
        // meeting must stay selected so the detail auto-opens.
        .onChange(of: store.selectedLibrary) { _, _ in
            if recordingMeetingID == nil {
                store.selectedMeetingID = nil
            }
        }
        #endif
        // Lets the menu bar drive recording and import without reaching into
        // the view hierarchy for a recorder instance.
        .focusedSceneValue(\.toggleRecordingAction, toggleRecording)
        .focusedSceneValue(\.importAudioAction, beginImport)
        .focusedSceneValue(\.isRecording, recorder.isRecording)
    }

    // MARK: - Recording and importing

    private func beginImport() {
        importFolderID = store.selectedFolderID ?? store.folders.first?.id
        isImporting = true
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                return
            }
            Task {
                let targetFolderID = importFolderID
                    ?? store.selectedFolderID
                    ?? store.folders.first?.id
                await store.importAudio(
                    from: url,
                    title: nil,
                    folderID: targetFolderID,
                    settings: settings
                )
                importFolderID = nil
            }
        case .failure(let error):
            importFolderID = nil
            store.lastError = error.localizedDescription
        }
    }

    private func startRecording() {
        // New recordings default to no folder unless the user is already
        // browsing inside a specific folder. The meeting is created up front
        // so its detail view opens immediately and accepts key notes while
        // the recording is still running.
        let meetingID = store.beginRecording(folderID: store.selectedFolderID)
        recordingMeetingID = meetingID

        Task {
            do {
                try await recorder.start()
            } catch {
                store.cancelRecording(meetingID: meetingID)
                recordingMeetingID = nil
                store.lastError = error.localizedDescription
            }
        }
    }

    private func stopRecording() {
        let meetingID = recordingMeetingID
        recordingMeetingID = nil

        guard let meetingID, let url = recorder.stop() else {
            // Recording never produced audio; drop the placeholder meeting.
            if let meetingID {
                store.cancelRecording(meetingID: meetingID)
            }
            return
        }

        Task {
            await store.finishRecording(
                meetingID: meetingID,
                recordingURL: url,
                settings: settings
            )
        }
    }

    private func toggleRecording() {
        if recorder.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }
}

#Preview {
    let store = MeetingStore()
    let settings = AppSettings()
    LibraryView()
        .environment(store)
        .environment(settings)
        .environment(CloudSyncController(store: store, settings: settings))
}
