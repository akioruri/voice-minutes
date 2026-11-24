import SwiftUI

struct FolderSidebarView: View {
    @Environment(MeetingStore.self) private var store
    @Environment(CloudSyncController.self) private var sync

    let isRecording: Bool
    let onSettings: () -> Void

    @State private var folderEditor: FolderEditorState?
    @State private var folderNameDraft = ""
    @State private var folderPendingDeletion: MeetingFolder?

    var body: some View {
        List(
            selection: Binding(
                get: { store.selectedLibrary },
                set: { store.selectLibrary($0) }
            )
        ) {
            Section {
                Label("library.allMinutes", systemImage: "tray.full")
                    .badge(store.allMeetings.count)
                    .tag(LibrarySelection.all)

                Label("library.recentlyDeleted", systemImage: "trash")
                    .badge(store.recentlyDeletedMeetings.count)
                    .tag(LibrarySelection.recentlyDeleted)
            }

            Section("folder.section") {
                ForEach(store.folders) { folder in
                    FolderRow(
                        folder: folder,
                        count: store.meetingCount(in: folder.id),
                        onRename: { beginRenaming(folder) },
                        onDelete: { requestDelete(folder) },
                        onDropMeetings: { moveDroppedMeetings($0, to: folder.id) }
                    )
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            syncStatusBar
        }
        .navigationTitle("library.navigationTitle")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    beginCreating()
                } label: {
                    Label("folder.new", systemImage: "folder.badge.plus")
                }

                #if os(iOS)
                Button(action: onSettings) {
                    Label("settings.action", systemImage: "gearshape")
                }
                #endif
            }
        }
        .alert(
            folderEditor?.folderID == nil
                ? "folder.new"
                : "folder.renameTitle",
            isPresented: Binding(
                get: { folderEditor != nil },
                set: { isPresented in
                    if !isPresented {
                        folderEditor = nil
                    }
                }
            )
        ) {
            TextField("folder.namePlaceholder", text: $folderNameDraft)
            Button("common.cancel", role: .cancel) {
                folderEditor = nil
            }
            Button("common.save") {
                saveFolderEditor()
            }
        }
        .confirmationDialog(
            "folder.deleteTitle",
            isPresented: Binding(
                get: { folderPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        folderPendingDeletion = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: folderPendingDeletion
        ) { folder in
            Button("folder.deleteAction", role: .destructive) {
                store.deleteFolder(folder.id)
                folderPendingDeletion = nil
            }
            Button("common.cancel", role: .cancel) {
                folderPendingDeletion = nil
            }
        } message: { folder in
            Text(
                InterfaceLanguage.current.format(
                    "folder.deleteMessage",
                    folder.name,
                    store.meetingCount(in: folder.id)
                )
            )
        }
    }

    // MARK: - Sync status

    private var syncStatusBar: some View {
        Group {
            #if os(macOS)
            SettingsLink {
                syncStatusContent
            }
            .buttonStyle(.plain)
            #else
            Button(action: onSettings) {
                syncStatusContent
            }
            .buttonStyle(.plain)
            #endif
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var syncStatusContent: some View {
        let language = InterfaceLanguage.current
        let symbol: String
        let text: String
        switch sync.status {
        case .disabled:
            symbol = "icloud.slash"
            text = language.text("sync.status.disabled")
        case .unavailable:
            symbol = "exclamationmark.icloud"
            text = language.text("sync.status.unavailable")
        case .noAccount:
            symbol = "icloud.slash"
            text = language.text("sync.status.noAccount")
        case .idle:
            symbol = "checkmark.icloud"
            text = language.text("sync.status.synced")
        case .syncing:
            symbol = "arrow.triangle.2.circlepath"
            text = language.text("sync.status.syncing")
        case .error:
            symbol = "exclamationmark.icloud"
            text = language.text("sync.status.error")
        }
        return HStack(spacing: 6) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
            Text(text)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityLabel(Text(verbatim: text))
    }

    // MARK: - Folder editing

    private func beginCreating() {
        folderNameDraft = ""
        folderEditor = FolderEditorState(folderID: nil)
    }

    private func beginRenaming(_ folder: MeetingFolder) {
        folderNameDraft = folder.name
        folderEditor = FolderEditorState(folderID: folder.id)
    }

    private func saveFolderEditor() {
        guard let folderEditor else {
            return
        }

        if let folderID = folderEditor.folderID {
            store.renameFolder(folderID, name: folderNameDraft)
        } else {
            store.createFolder(name: folderNameDraft)
        }
        self.folderEditor = nil
    }

    private func requestDelete(_ folder: MeetingFolder) {
        guard !isRecording else {
            store.lastError = InterfaceLanguage.current.text(
                "error.cannotDeleteFolderWhileRecording"
            )
            return
        }
        folderPendingDeletion = folder
    }

    /// Accepts meeting IDs dragged in from the task list and files them here.
    private func moveDroppedMeetings(_ identifiers: [String], to folderID: UUID) {
        for identifier in identifiers {
            guard let meetingID = UUID(uuidString: identifier) else {
                continue
            }
            store.moveMeeting(meetingID, to: folderID)
        }
    }
}

// MARK: - Folder row

/// A single sidebar folder. TEMPORARY DIAGNOSTIC: all drop handling removed
/// (no dropDestination / isTargeted / listRowBackground / hit-area shaping) to
/// check whether the sidebar's native highlight renders uniformly with no
/// drop region present. Drag-and-drop into folders is disabled in this build.
private struct FolderRow: View {
    @Environment(MeetingStore.self) private var store
    @Environment(AppSettings.self) private var settings

    let folder: MeetingFolder
    let count: Int
    let onRename: () -> Void
    let onDelete: () -> Void
    let onDropMeetings: ([String]) -> Void

    var body: some View {
        Label(folder.name, systemImage: "folder.fill")
            .badge(count)
            .tag(LibrarySelection.folder(folder.id))
            .contextMenu {
                Button("folder.rename", action: onRename)
                Menu {
                    Button {
                        store.setFolderPrompt(folder.id, promptID: nil)
                    } label: {
                        if folder.promptID == nil {
                            Label("folder.useGlobalPrompt", systemImage: "checkmark")
                        } else {
                            Text("folder.useGlobalPrompt")
                        }
                    }
                    ForEach(settings.minutesPrompts) { prompt in
                        Button {
                            store.setFolderPrompt(folder.id, promptID: prompt.id)
                        } label: {
                            if folder.promptID == prompt.id {
                                Label(prompt.name, systemImage: "checkmark")
                            } else {
                                Text(prompt.name)
                            }
                        }
                    }
                } label: {
                    Label("folder.promptMenu", systemImage: "text.quote")
                }
                Button("common.delete", role: .destructive, action: onDelete)
            }
            .swipeActions(edge: .trailing) {
                Button("common.delete", role: .destructive, action: onDelete)
            }
    }
}

private struct FolderEditorState {
    let folderID: UUID?
}
