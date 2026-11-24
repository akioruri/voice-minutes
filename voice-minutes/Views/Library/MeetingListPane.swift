import SwiftUI

struct MeetingListPane: View {
    @Environment(MeetingStore.self) private var store

    let selection: LibrarySelection?
    let isRecording: Bool
    let recordingDuration: TimeInterval
    let onImport: () -> Void
    let onToggleRecording: () -> Void
    let onMark: () -> Void
    @State private var meetingPendingRename: MeetingRecord?
    @State private var renameDraft = ""
    @State private var searchText = ""
    @State private var isConfirmingEmptyTrash = false
    @State private var isSearching = false

    private var visibleMeetings: [MeetingRecord] {
        let meetings = store.meetings(for: selection)

        guard !searchText.isEmpty else {
            return meetings
        }

        return meetings.filter { meeting in
            meeting.title.localizedCaseInsensitiveContains(searchText)
                || meeting.notesMarkdown.localizedCaseInsensitiveContains(searchText)
                || meeting.minutesMarkdown.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var isShowingTrash: Bool {
        selection == .recentlyDeleted
    }

    private var pageTitle: String {
        let language = InterfaceLanguage.current

        switch selection {
        case .all:
            return language.text("library.allMinutes")
        case .recentlyDeleted:
            return language.text("library.recentlyDeleted")
        case .folder:
            return store.selectedFolder?.name ?? language.text("meeting.tasks")
        case nil:
            return language.text("meeting.tasks")
        }
    }

    @ViewBuilder
    private func rowContextMenu(for meeting: MeetingRecord) -> some View {
        if meeting.isDeleted {
            Button("meeting.restore") {
                store.restoreMeeting(meeting.id)
            }

            Button("meeting.deletePermanently", role: .destructive) {
                store.permanentlyDeleteMeeting(meeting.id)
            }
        } else {
            Button("meeting.rename") {
                renameDraft = meeting.title
                meetingPendingRename = meeting
            }

            moveMenu(for: meeting)

            Button("common.delete", role: .destructive) {
                store.deleteMeeting(meeting.id)
            }
        }
    }

    private func moveMenu(for meeting: MeetingRecord) -> some View {
        Menu("meeting.moveToFolder") {
            ForEach(store.folders) { folder in
                Button(folder.name) {
                    store.moveMeeting(meeting.id, to: folder.id)
                }
                .disabled(meeting.folderID == folder.id)
            }
        }
    }

    /// Single deletion path shared by the iOS swipe action and the macOS
    /// Delete key: trash rows are purged, live rows move to Recently Deleted.
    private func delete(_ meeting: MeetingRecord) {
        if isShowingTrash {
            store.permanentlyDeleteMeeting(meeting.id)
        } else {
            store.deleteMeeting(meeting.id)
        }
    }

    var body: some View {
        @Bindable var store = store

        Group {
            if selection == nil {
                ContentUnavailableView(
                    "list.selectContentTitle",
                    systemImage: "tray.full",
                    description: Text("list.selectContentDescription")
                )
            } else if visibleMeetings.isEmpty {
                emptyState
            } else {
                List(selection: $store.selectedMeetingID) {
                    ForEach(visibleMeetings) { meeting in
                        MeetingRowView(meeting: meeting)
                            .tag(meeting.id)
                            .modifier(
                                MeetingDraggable(
                                    payload: meeting.isDeleted ? nil : meeting.id.uuidString
                                )
                            )
                            .contextMenu { rowContextMenu(for: meeting) }
                    }
                    .onDelete { offsets in
                        for offset in offsets where visibleMeetings.indices.contains(offset) {
                            delete(visibleMeetings[offset])
                        }
                    }
                }
                // Native inset list: the system draws the selection highlight
                // and the row separators. Swipe-to-delete stays on both
                // platforms; the Delete key works via onDeleteCommand below.
                .listStyle(.inset)
                #if os(macOS)
                // Delete key deletion is a macOS convention; iOS deletes via
                // swipe actions and the context menu.
                .onDeleteCommand {
                    if let id = store.selectedMeetingID,
                       let meeting = visibleMeetings.first(where: { $0.id == id }) {
                        delete(meeting)
                    }
                }
                #endif
            }
        }
        .navigationTitle(pageTitle)
        #if os(iOS)
        // Search is a top-right button opening a dedicated search sheet; the
        // list itself keeps no expanding search bar, so the bottom belongs to
        // the glass record button alone.
        .sheet(isPresented: $isSearching) {
            MeetingSearchSheet(selection: selection) { meetingID in
                store.selectedMeetingID = meetingID
                isSearching = false
            }
        }
        #else
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: Text(verbatim: InterfaceLanguage.current.text("list.searchPrompt"))
        )
        #endif
        .alert(
            "meeting.renameTitle",
            isPresented: Binding(
                get: { meetingPendingRename != nil },
                set: { isPresented in
                    if !isPresented {
                        meetingPendingRename = nil
                    }
                }
            )
        ) {
            TextField("meeting.renamePlaceholder", text: $renameDraft)
            Button("common.cancel", role: .cancel) {
                meetingPendingRename = nil
            }
            Button("common.save") {
                if let meetingPendingRename {
                    store.renameMeeting(meetingPendingRename.id, title: renameDraft)
                }
                meetingPendingRename = nil
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if isShowingTrash {
                    Button("trash.emptyAction", role: .destructive) {
                        isConfirmingEmptyTrash = true
                    }
                    .disabled(store.recentlyDeletedMeetings.isEmpty || store.isBusy)
                }

                #if os(iOS)
                if !isShowingTrash {
                    Button(action: onImport) {
                        Label("meeting.importRecording", systemImage: "doc.badge.plus")
                    }
                    .disabled(store.isBusy || isRecording)
                }

                Button {
                    isSearching = true
                } label: {
                    Label(
                        InterfaceLanguage.current.text("list.searchPrompt"),
                        systemImage: "magnifyingglass"
                    )
                }
                #endif
            }
        }
        .confirmationDialog(
            InterfaceLanguage.current.text("trash.emptyConfirmTitle"),
            isPresented: $isConfirmingEmptyTrash,
            titleVisibility: .visible
        ) {
            // The action was chosen deliberately, so the confirm button keeps
            // the plain style and only Cancel is marked as the safe way out.
            Button(InterfaceLanguage.current.text("trash.emptyAction")) {
                store.emptyTrash()
            }

            Button("common.cancel", role: .cancel) {}
        } message: {
            Text(verbatim: InterfaceLanguage.current.text("trash.emptyConfirmMessage"))
        }
        // Keep the last rows clear of the floating record button.
        .contentMargins(.bottom, 96, for: .scrollContent)
        // Glass record control floats above the bottom of the list on every
        // platform, keeping the toolbar free for list actions.
        .overlay(alignment: .bottom) {
            if !isShowingTrash {
                HStack(spacing: 12) {
                    #if os(macOS)
                    if isRecording {
                        markButton
                    }
                    #endif
                    RecordFloatingButton(
                        isRecording: isRecording,
                        duration: recordingDuration,
                        action: onToggleRecording
                    )
                }
                .padding(.bottom, 24)
                .animation(.snappy(duration: 0.24), value: isRecording)
            }
        }
    }

    /// Yellow glass companion to the red record capsule: drops a time mark
    /// at the current recording position without stopping the recording.
    private var markButton: some View {
        Button(action: onMark) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 20, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .glassEffect(.regular.tint(.yellow).interactive(), in: .capsule)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(InterfaceLanguage.current.text("recording.mark"))
        .accessibilityLabel(Text("recording.mark"))
        .transition(.scale.combined(with: .opacity))
    }

    /// Empty states invite the next step and hand the reader a button for it.
    @ViewBuilder
    private var emptyState: some View {
        if isShowingTrash {
            ContentUnavailableView(
                "trash.emptyTitle",
                systemImage: "trash",
                description: Text("trash.emptyDescription")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !searchText.isEmpty {
            ContentUnavailableView(
                "list.noResultsTitle",
                systemImage: "magnifyingglass",
                description: Text(
                    InterfaceLanguage.current.format("list.noResultsDescription", searchText)
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Empty library: recording and import stay reachable from the
            // floating glass button and the toolbar, so the empty state keeps
            // only its explanation instead of duplicating those actions.
            ContentUnavailableView(
                "meeting.emptyTitle",
                systemImage: "waveform",
                description: Text("meeting.emptyDescription")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Makes a task row draggable only while a payload is available, so meetings in
/// Recently Deleted cannot be dragged into folders.
private struct MeetingDraggable: ViewModifier {
    let payload: String?

    func body(content: Content) -> some View {
        if let payload {
            content.draggable(payload)
        } else {
            content
        }
    }
}

#if os(iOS)
/// Dedicated search page opened from the list's top-right search button on
/// iPhone: a plain list with an always-visible search field, so the library
/// itself never grows an expanding search bar.
private struct MeetingSearchSheet: View {
    @Environment(MeetingStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let selection: LibrarySelection?
    let onSelect: (UUID) -> Void

    @State private var text = ""

    private var results: [MeetingRecord] {
        let meetings = store.meetings(for: selection)

        guard !text.isEmpty else {
            return meetings
        }

        return meetings.filter { meeting in
            meeting.title.localizedCaseInsensitiveContains(text)
                || meeting.notesMarkdown.localizedCaseInsensitiveContains(text)
                || meeting.minutesMarkdown.localizedCaseInsensitiveContains(text)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(results) { meeting in
                    Button {
                        onSelect(meeting.id)
                    } label: {
                        MeetingRowView(meeting: meeting)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .overlay {
                if results.isEmpty {
                    ContentUnavailableView(
                        "list.searchEmpty",
                        systemImage: "magnifyingglass",
                        description: Text(verbatim: text)
                    )
                }
            }
            .searchable(
                text: $text,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text(verbatim: InterfaceLanguage.current.text("list.searchPrompt"))
            )
            .navigationTitle(Text(verbatim: InterfaceLanguage.current.text("list.searchPrompt")))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}
#endif
