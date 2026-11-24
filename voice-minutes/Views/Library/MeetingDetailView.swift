import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct MeetingDetailView: View {
    @Environment(MeetingStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(CloudSyncController.self) private var sync

    let meetingID: UUID
    let isRecording: Bool
    let recordingDuration: TimeInterval
    let onToggleRecording: () -> Void
    let onImport: () -> Void

    @State private var selectedContent: DetailContent = .minutes
    @State private var audioPlayer = MeetingAudioPlayer()
    @State private var noteFocusRequest: UUID?
    @State private var renameDraft = ""
    @State private var isRenaming = false
    @FocusState private var isTitleFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var meeting: MeetingRecord? {
        store.meetings.first { $0.id == meetingID }
    }

    var body: some View {
        Group {
            if let meeting {
                VStack(spacing: 0) {
                    header(for: meeting)
                    content(for: meeting)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                #if os(macOS)
                // Keep the last lines of scrollable content clear of the
                // floating glass switcher.
                .contentMargins(.bottom, 72, for: .scrollContent)
                // Floating Liquid Glass switcher pinned above the bottom edge;
                // content scrolls underneath it.
                .overlay(alignment: .bottom) {
                    if meeting.status == .completed {
                        contentPicker
                            .padding(.bottom, 20)
                    }
                }
                #endif
            } else {
                ContentUnavailableView(
                    "meeting.deletedTitle",
                    systemImage: "trash",
                    description: Text("meeting.deletedDescription")
                )
            }
        }
        #if os(macOS)
        // Titles the window with the meeting, like Notes titles its window
        // with the note, so multiple windows stay distinguishable.
        .navigationTitle(meeting?.title ?? "")
        #else
        // On iPhone the title lives in the navigation bar (inline, so the bar
        // is not an empty strip); the content header keeps only metadata to
        // avoid printing the name twice. Renaming stays reachable through the
        // list row's context menu.
        .navigationTitle(meeting?.title ?? "")
        .toolbarTitleDisplayMode(.inline)
        // Metadata rides under the title as the navigation subtitle (small
        // secondary text), so it costs no content space on iPhone.
        .navigationSubtitle(
            Text(verbatim: meeting.map { metadataLine(for: $0) } ?? "")
        )
        #endif
        .toolbar {
            #if os(iOS)
            if isRecording {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        dropMark()
                    } label: {
                        Label(
                            InterfaceLanguage.current.text("recording.mark"),
                            systemImage: "bookmark"
                        )
                        .labelStyle(.iconOnly)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        addNoteWhileRecording()
                    } label: {
                        Label(
                            InterfaceLanguage.current.text("recording.addNote"),
                            systemImage: "square.and.pencil"
                        )
                        .labelStyle(.iconOnly)
                    }
                }
                // Stop takes export's top-right slot while recording: far from
                // the keyboard, so typing key notes cannot mis-tap it.
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onToggleRecording) {
                        Label(
                            InterfaceLanguage.current.text("recording.stop"),
                            systemImage: "stop.fill"
                        )
                        .labelStyle(.titleAndIcon)
                    }
                    .tint(.red)
                    .buttonStyle(.borderedProminent)
                }
            } else {
                // Completed meetings play from the tab bar's MiniPlayer
                // accessory; failed meetings have no tab bar, so their play
                // action stays in the toolbar.
                if meeting?.status == .failed && (meeting?.duration ?? 0) > 0 {
                    playbackToolbarItem
                }
                if meeting?.status == .completed {
                    regenerationToolbarItem
                }
                detailToolbar
            }
            #else
            if isRecording {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        addNoteWhileRecording()
                    } label: {
                        Label(
                            InterfaceLanguage.current.text("recording.addNote"),
                            systemImage: "square.and.pencil"
                        )
                    }
                    .help(InterfaceLanguage.current.text("recording.addNote"))
                }
            }
            if meeting?.status == .completed {
                regenerationToolbarItem
            }
            detailToolbar
            #endif
        }
        // Key on the meeting ID, not the audio file name: every meeting stores
        // its audio as "audio.m4a", so the file name never changes when the
        // selection switches and this task would not reload the player.
        .task(id: meetingID) {
            if let meeting {
                audioPlayer.load(url: store.audioURL(for: meeting))
            }
        }
        .onChange(of: meeting?.duration) { _, duration in
            // A recording in progress has no audio file yet. Once it is
            // saved the duration lands on the record, so load the bar then.
            if let meeting, (duration ?? 0) > 0 {
                audioPlayer.load(url: store.audioURL(for: meeting))
            }
        }
        .onDisappear {
            audioPlayer.stop()
            cancelRename()
            store.flushPendingLibrarySave()
        }
        // The inline title field owns focus while it is open, so losing focus
        // commits the rename exactly like pressing Return.
        .onChange(of: isTitleFocused) { _, isFocused in
            if !isFocused, isRenaming {
                commitRename()
            }
        }
        .onChange(of: isRenaming) { _, isActive in
            isTitleFocused = isActive
        }
        .onChange(of: meetingID) { _, _ in
            cancelRename()
        }
    }

    // MARK: - Content picker

    /// Export and import stay put in every state so the toolbar never
    /// disappears; the content picker lives at the bottom of the page.
    private var detailToolbar: some ToolbarContent {
        DetailToolbar(
            isExportEnabled: meeting?.status == .completed,
            isImportEnabled: !store.isBusy,
            onExport: { kind in
                if let meeting {
                    prepareExport(kind, meeting: meeting)
                }
            },
            onImport: onImport,
        )
    }

    /// macOS-only segmented switcher for minutes / transcript / notes (iPhone
    /// uses the native Liquid Glass tab bar instead). A single native Liquid
    /// Glass capsule (`.glassEffect`) holds the three options; the selected
    /// option is itself a tinted Liquid Glass capsule, so both the container
    /// and the selection carry glass texture.
    private var contentPicker: some View {
        HStack(spacing: 0) {
            ForEach(DetailContent.allCases) { content in
                Button {
                    selectedContent = content
                } label: {
                    Text(content.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(
                            selectedContent == content ? .white : .primary
                        )
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .glassEffect(
                            selectedContent == content
                                ? .regular.tint(.accentColor)
                                : .identity,
                            in: .capsule
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .glassEffect(.regular, in: .capsule)
    }

    // MARK: - Renaming

    /// Swaps the header title for an inline field so a meeting is renamed by
    /// clicking its name, without a separate rename button.
    private func beginRenaming(_ meeting: MeetingRecord) {
        renameDraft = meeting.title
        isRenaming = true
    }

    private func commitRename() {
        guard isRenaming else {
            return
        }

        if let meeting {
            store.renameMeeting(meeting.id, title: renameDraft)
        }
        isRenaming = false
        isTitleFocused = false
    }

    private func cancelRename() {
        isRenaming = false
        isTitleFocused = false
    }

    /// The header title doubles as the rename field: tapping the name swaps it
    /// for an inline editor that commits on Return or on losing focus.
    /// An invisible Text owns the layout height in both states — sized to the
    /// draft while editing — and the TextField draws on top of it. A plain
    /// TextField is a few points taller than a Text at the same font, so
    /// swapping the views directly used to push the metadata below down.
    private func titleField(for meeting: MeetingRecord) -> some View {
        Text(isRenaming ? renameDraft : meeting.title)
            .font(.title2.bold())
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(isRenaming ? 0 : 1)
            .accessibilityHidden(isRenaming)
            .overlay(alignment: .topLeading) {
                if isRenaming {
                    TextField(
                        InterfaceLanguage.current.text("meeting.renamePlaceholder"),
                        text: $renameDraft,
                        axis: .vertical
                    )
                    .font(.title2.bold())
                    .textFieldStyle(.plain)
                    .lineLimit(3)
                    .focused($isTitleFocused)
                    .onSubmit(commitRename)
                    #if os(macOS)
                    // Escape cancels the inline rename on macOS; iOS has no exit key.
                    .onExitCommand(perform: cancelRename)
                    #endif
                    .accessibilityLabel(InterfaceLanguage.current.text("meeting.rename"))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if !isRenaming {
                    beginRenaming(meeting)
                }
            }
            .help(InterfaceLanguage.current.text("meeting.rename"))
            .accessibilityAddTraits(.isButton)
    }

    private func header(for meeting: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            #if os(macOS)
            // The player sits beside the title while the column is wide
            // enough for both; once it narrows, ViewThatFits drops the player
            // below the title block so the name never gets squeezed into a
            // tall wrap.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    titleBlock(for: meeting)
                    Spacer(minLength: 16)
                    MeetingAudioPlayerView(
                        player: audioPlayer,
                        recordDuration: meeting.duration,
                        isDownloading: sync.downloadingMeetingIDs.contains(meeting.id),
                        onPlay: { togglePlayback(for: meeting) }
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    titleBlock(for: meeting)
                    MeetingAudioPlayerView(
                        player: audioPlayer,
                        recordDuration: meeting.duration,
                        isDownloading: sync.downloadingMeetingIDs.contains(meeting.id),
                        onPlay: { togglePlayback(for: meeting) }
                    )
                }
            }
            // ViewThatFits centers the candidate it picks; pin the chosen
            // layout to the leading edge so the narrow header stays
            // left-aligned like the rest of the page.
            .frame(maxWidth: .infinity, alignment: .leading)
            #endif

            if let errorMessage = meeting.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 20)
        #if os(macOS)
        .padding(.vertical, 18)
        #else
        // On iPhone the title and metadata live in the navigation bar; the
        // header only surfaces errors and otherwise collapses to zero height
        // so the content starts immediately.
        .padding(.vertical, meeting.errorMessage == nil ? 0 : 12)
        #endif
    }

    /// Title plus metadata for the macOS header; iPhone carries both in the
    /// navigation bar (title + subtitle) instead.
    private func titleBlock(for meeting: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            titleField(for: meeting)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    metadataItems(for: meeting)
                }

                VStack(alignment: .leading, spacing: 4) {
                    metadataItems(for: meeting)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func metadataItems(for meeting: MeetingRecord) -> some View {
        Label(
            meeting.createdAt.formatted(
                .dateTime.year().month().day().hour().minute()
            ),
            systemImage: "calendar"
        )

        if meeting.duration > 0 {
            Label(
                MeetingRowView.formatDuration(meeting.duration),
                systemImage: "clock"
            )
        }

        if let folder = store.folders.first(where: { $0.id == meeting.folderID }) {
            Label(folder.name, systemImage: "folder")
        }

        if isRecording {
            Label("recording.inProgress", systemImage: "record.circle.fill")
                .foregroundStyle(.red)
        } else {
            Label(meeting.status.title, systemImage: statusSymbol(for: meeting))
                .foregroundStyle(statusColor(for: meeting))
        }
    }

    /// Compact one-line metadata for the iPhone navigation subtitle: date,
    /// duration, folder and status joined as small secondary text.
    private func metadataLine(for meeting: MeetingRecord) -> String {
        var parts = [
            meeting.createdAt.formatted(
                .dateTime.year().month().day().hour().minute()
            ),
        ]

        if meeting.duration > 0 {
            parts.append(MeetingRowView.formatDuration(meeting.duration))
        }

        if let folder = store.folders.first(where: { $0.id == meeting.folderID }) {
            parts.append(folder.name)
        }

        parts.append(
            isRecording
                ? InterfaceLanguage.current.text("recording.inProgress")
                : meeting.status.title
        )

        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func content(for meeting: MeetingRecord) -> some View {
        switch meeting.status {
        case .pending, .processing:
            // A meeting that is not the one being processed is a recording in
            // progress: show the key-notes editor so points can be typed
            // while the meeting is still running.
            if store.processingMeetingID == meeting.id {
                processingState(for: meeting)
            } else {
                notesState(for: meeting)
            }
        case .failed:
            // Retry is the most likely action on a failed meeting, so it sits
            // in the empty state right under the explanation (feedback.md:
            // keep status feedback near the item it describes) and takes the
            // prominent style (buttons.md: one preferred action per view).
            ContentUnavailableView {
                Label(
                    "meeting.processingFailedTitle",
                    systemImage: "exclamationmark.triangle"
                )
            } description: {
                Text("meeting.processingFailedDescription")
            } actions: {
                Button {
                    Task {
                        await store.retry(
                            meetingID: meeting.id,
                            settings: settings
                        )
                    }
                } label: {
                    Label("common.retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(store.isBusy)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .completed:
            completedContent(for: meeting)
        }
    }

    /// Progress card shown while this meeting is being transcribed. Keeping the
    /// progress inside the detail column leaves the rest of the app usable.
    @ViewBuilder
    private func processingState(for meeting: MeetingRecord) -> some View {
        let isActive = store.processingMeetingID == meeting.id
        let message = isActive && !store.processingMessage.isEmpty
            ? store.processingMessage
            : InterfaceLanguage.current.text("meeting.processing")

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(meeting.status.title)
                        .font(.headline)
                        .lineLimit(1)

                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                if isActive {
                    Text("\(Int(store.progress * 100))%")
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }

            if isActive {
                ProgressView(value: store.progress)
                    .tint(.accentColor)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        // A standard material, not Liquid Glass: this card is content, and
        // glass belongs to the layer of controls that floats above it.
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal)
        .padding(.top, 4)
    }

    /// Manually typed key points. They live on the meeting record and are sent
    /// to the summary model together with the transcript.
    @ViewBuilder
    private func notesState(for meeting: MeetingRecord) -> some View {
        // Keyed by meeting so block drafts reload whenever the selection
        // switches.
        KeyNotesBlocksView(
            meeting: meeting,
            focusRequest: $noteFocusRequest,
            onSeek: { time in seekAudio(to: time) }
        )
        .id(meeting.id)
    }

    // MARK: - Recording marks & quick notes

    /// Drops a time mark at the current recording position without leaving
    /// the current tab; the mark shows in the transcript and the notes page.
    private func dropMark() {
        guard let meeting else {
            return
        }
        store.addMark(to: meeting.id, time: recordingDuration)
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    /// Adds an empty block and jumps straight into typing it.
    private func addNoteWhileRecording() {
        guard let meeting else {
            return
        }
        if let blockID = store.addBlock(to: meeting.id) {
            selectedContent = .notes
            noteFocusRequest = blockID
        }
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    private func seekAudio(to time: TimeInterval) {
        guard let meeting else {
            return
        }
        if audioPlayer.duration <= 0, store.hasLocalAudio(for: meeting) {
            audioPlayer.load(url: store.audioURL(for: meeting))
        }
        audioPlayer.seek(to: time)
    }

    private func transcriptMarkers(for meeting: MeetingRecord) -> [TranscriptMarker] {
        let marks = meeting.marks.map {
            TranscriptMarker(id: $0.id, time: $0.time, text: $0.label, isMark: true)
        }
        let anchors = meeting.keyNoteBlocks.compactMap { block in
            block.anchorTime.map {
                TranscriptMarker(id: block.id, time: $0, text: block.text, isMark: false)
            }
        }
        return marks + anchors
    }

    // MARK: - Regeneration

    private var canRetranscribe: Bool {
        guard let meeting, meeting.duration > 0 else {
            return false
        }
        return store.hasLocalAudio(for: meeting) || settings.syncEnabled
    }

    private var regenerationToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    regenerate(retranscribe: false)
                } label: {
                    Label(
                        InterfaceLanguage.current.text("regen.summarizeOnly"),
                        systemImage: "doc.text"
                    )
                }
                .disabled(meeting?.transcriptSRT.isEmpty ?? true)

                Button {
                    regenerate(retranscribe: true)
                } label: {
                    Label(
                        InterfaceLanguage.current.text("regen.full"),
                        systemImage: "waveform"
                    )
                }
                .disabled(!canRetranscribe)
            } label: {
                Label(
                    InterfaceLanguage.current.text("regen.title"),
                    systemImage: "arrow.clockwise"
                )
                .labelStyle(.iconOnly)
            }
            .menuIndicator(.hidden)
            .disabled(store.isBusy)
            .help(InterfaceLanguage.current.text("regen.title"))
        }
    }

    private func regenerate(retranscribe: Bool) {
        guard let meeting else {
            return
        }
        Task {
            if retranscribe, !store.hasLocalAudio(for: meeting), settings.syncEnabled {
                do {
                    try await sync.downloadAudio(for: meeting)
                } catch {
                    store.lastError = error.localizedDescription
                    return
                }
            }
            await store.regenerateMinutes(
                meetingID: meeting.id,
                retranscribe: retranscribe,
                settings: settings
            )
        }
    }

    @ViewBuilder
    private func completedContent(for meeting: MeetingRecord) -> some View {
        #if os(iOS)
        // Native Liquid Glass tab bar: navigation only (tab-bars.md: a tab bar
        // supports navigation, not actions), one row, icons plus labels as the
        // guideline recommends. Playback lives in the toolbar instead.
        TabView(selection: $selectedContent) {
            minutesScroll(for: meeting)
                .tabItem {
                    Label(DetailContent.minutes.title, systemImage: DetailContent.minutes.systemImage)
                }
                .tag(DetailContent.minutes)

            TranscriptView(
                cues: SRTBuilder.cues(from: meeting.transcriptSRT),
                player: audioPlayer,
                markers: transcriptMarkers(for: meeting),
                onConvertMark: { markID in
                    store.convertMark(markID: markID, meetingID: meeting.id)
                },
                onDeleteMark: { markID in
                    store.deleteMark(markID: markID, meetingID: meeting.id)
                },
                onPlay: { togglePlayback(for: meeting) }
            )
            .tabItem {
                Label(DetailContent.transcript.title, systemImage: DetailContent.transcript.systemImage)
            }
            .tag(DetailContent.transcript)

            notesState(for: meeting)
                .tabItem {
                    Label(DetailContent.notes.title, systemImage: DetailContent.notes.systemImage)
                }
                .tag(DetailContent.notes)
        }
        #else
        switch selectedContent {
        case .minutes:
            minutesScroll(for: meeting)
        case .transcript:
            TranscriptView(
                cues: SRTBuilder.cues(from: meeting.transcriptSRT),
                player: audioPlayer,
                markers: transcriptMarkers(for: meeting),
                onConvertMark: { markID in
                    store.convertMark(markID: markID, meetingID: meeting.id)
                },
                onDeleteMark: { markID in
                    store.deleteMark(markID: markID, meetingID: meeting.id)
                }
            )
        case .notes:
            notesState(for: meeting)
        }
        #endif
    }

    /// Playback is an action, so it lives in the toolbar (toolbars.md), not in
    /// the tab bar. Availability keys off the record's duration (not the loaded
    /// player's), so the button never vanishes while the player reloads;
    /// tapping loads the audio on demand if the player was stopped.
    private var playbackToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                if let meeting {
                    togglePlayback(for: meeting)
                }
            } label: {
                if let meeting, sync.downloadingMeetingIDs.contains(meeting.id) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .symbolRenderingMode(.hierarchical)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .disabled((meeting?.duration ?? 0) <= 0)
            .accessibilityLabel(
                Text(verbatim: InterfaceLanguage.current.text(
                    audioPlayer.isPlaying ? "audio.pause" : "audio.play"
                ))
            )
        }
    }

    /// Loads the audio on demand (the player may have been stopped) and toggles
    /// play/pause. Shared by the toolbar item, the MiniPlayer and the merged bar.
    private func togglePlayback(for meeting: MeetingRecord) {
        if audioPlayer.duration <= 0 {
            if store.hasLocalAudio(for: meeting) {
                audioPlayer.load(url: store.audioURL(for: meeting))
            } else if settings.syncEnabled {
                downloadAndPlay(meeting)
                return
            } else {
                store.lastError = InterfaceLanguage.current.text("sync.audio.notSynced")
                return
            }
        }
        audioPlayer.togglePlayback()
    }

    /// Pulls a recording that only exists in iCloud, then plays it. The play
    /// buttons show a spinner while the download is in flight.
    private func downloadAndPlay(_ meeting: MeetingRecord) {
        Task {
            do {
                try await sync.downloadAudio(for: meeting)
                audioPlayer.load(url: store.audioURL(for: meeting))
                audioPlayer.togglePlayback()
            } catch {
                store.lastError = error.localizedDescription
            }
        }
    }

    private func minutesScroll(for meeting: MeetingRecord) -> some View {
        ScrollView {
            MarkdownView(markdown: meeting.minutesMarkdown)
                .textSelection(.enabled)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private func prepareExport(
        _ kind: MeetingExportKind,
        meeting: MeetingRecord
    ) {
        do {
            let data: Data

            switch kind {
            case .markdown:
                data = Data(meeting.minutesMarkdown.utf8)
            case .srt:
                data = Data(meeting.transcriptSRT.utf8)
            case .pdf:
                let date = meeting.createdAt.formatted(
                    date: .abbreviated,
                    time: .shortened
                )
                let duration = MeetingRowView.formatDuration(meeting.duration)
                data = try MeetingPDFExporter.makePDF(
                    title: meeting.title,
                    metadata: "\(date)  ·  \(duration)",
                    markdown: meeting.minutesMarkdown
                )
            }

            let filename = sanitizedFilename(
                kind.filename(for: meeting.title)
            )
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(filename)

            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            try data.write(to: fileURL, options: .atomic)

            SystemFileExporter.save(
                fileURL: fileURL,
                suggestedFilename: filename
            ) { result in
                try? FileManager.default.removeItem(at: fileURL)

                if case .failure(let error) = result {
                    store.lastError = error.localizedDescription
                }
            }
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func sanitizedFilename(_ filename: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\\\?%*|\"<>")
            .union(.controlCharacters)
        let cleaned = filename
            .components(separatedBy: invalid)
            .filter { !$0.isEmpty }
            .joined(separator: "-")

        return cleaned.isEmpty
            ? InterfaceLanguage.current.text("content.minutes")
            : cleaned
    }
}

/// Block-based key-notes editor: independent blocks with optional time
/// anchors, per-block LLM analysis, and a marks section for unconverted
/// recording marks. Each text field keeps a local draft so Chinese IME
/// composition is never cancelled by store round-trips.
private struct KeyNotesBlocksView: View {
    let meeting: MeetingRecord
    @Binding var focusRequest: UUID?
    let onSeek: (TimeInterval) -> Void

    @Environment(MeetingStore.self) private var store
    @FocusState private var focusedBlock: UUID?
    @State private var blockPendingDeletion: KeyNoteBlock?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !meeting.marks.isEmpty {
                    marksSection
                }

                if meeting.keyNoteBlocks.isEmpty {
                    Text("notes.placeholder")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    ForEach(meeting.keyNoteBlocks) { block in
                        KeyNoteBlockCard(
                            meeting: meeting,
                            block: block,
                            focusedBlock: $focusedBlock,
                            onSeek: onSeek,
                            onDelete: { requestDelete(block) }
                        )
                    }
                }

                Button {
                    if let blockID = store.addBlock(to: meeting.id) {
                        focusedBlock = blockID
                    }
                } label: {
                    Label("notes.block.add", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            if let focusRequest {
                focusedBlock = focusRequest
                self.focusRequest = nil
            }
        }
        .onChange(of: focusRequest) { _, newValue in
            if let newValue {
                focusedBlock = newValue
                focusRequest = nil
            }
        }
        .confirmationDialog(
            "notes.block.deleteTitle",
            isPresented: Binding(
                get: { blockPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        blockPendingDeletion = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: blockPendingDeletion
        ) { block in
            Button("notes.block.delete", role: .destructive) {
                store.deleteBlock(blockID: block.id, meetingID: meeting.id)
                blockPendingDeletion = nil
            }
            Button("common.cancel", role: .cancel) {
                blockPendingDeletion = nil
            }
        } message: { _ in
            Text("notes.block.deleteMessage")
        }
        .onDisappear {
            store.flushPendingLibrarySave()
        }
    }

    private var marksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("mark.section")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(meeting.marks) { mark in
                MarkRow(
                    meeting: meeting,
                    mark: mark,
                    onSeek: onSeek,
                    onConvert: {
                        if let blockID = store.convertMark(
                            markID: mark.id,
                            meetingID: meeting.id
                        ) {
                            focusedBlock = blockID
                        }
                    }
                )
                .padding(12)
                .background(
                    .quaternary.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }
        }
    }

    private func requestDelete(_ block: KeyNoteBlock) {
        let isEmpty = block.text
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && block.analysis.isEmpty
        if isEmpty {
            store.deleteBlock(blockID: block.id, meetingID: meeting.id)
        } else {
            blockPendingDeletion = block
        }
    }
}

/// Tinted inset panel that visually separates LLM-generated analysis from
/// the user's manually entered text above it.
private struct GeneratedAnalysisPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("analysis.generatedLabel", systemImage: "sparkles")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.accentColor.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }
}

/// One unconverted time mark: seek chip, editable label, convert and delete.
private struct MarkRow: View {
    let meeting: MeetingRecord
    let mark: MeetingMark
    let onSeek: (TimeInterval) -> Void
    let onConvert: () -> Void

    @Environment(MeetingStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var draft: String

    init(
        meeting: MeetingRecord,
        mark: MeetingMark,
        onSeek: @escaping (TimeInterval) -> Void,
        onConvert: @escaping () -> Void
    ) {
        self.meeting = meeting
        self.mark = mark
        self.onSeek = onSeek
        self.onConvert = onConvert
        _draft = State(initialValue: mark.label)
    }

    private var isAnalyzing: Bool {
        store.analyzingMarkIDs.contains(mark.id)
    }

    private var canAnalyze: Bool {
        meeting.status == .completed
            && !meeting.transcriptSRT.isEmpty
            && settings.isSummaryConfigured
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row
            GeneratedAnalysisPanel {
                analysisSection
            }
        }
    }

    private var row: some View {
        HStack(spacing: 10) {
            Button {
                onSeek(mark.time)
            } label: {
                Label(
                    MeetingRowView.formatDuration(mark.time),
                    systemImage: "bookmark.fill"
                )
                .font(.caption.monospacedDigit())
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            TextField("mark.labelPlaceholder", text: Binding(
                get: { draft },
                set: { newValue in
                    draft = newValue
                    store.updateMarkLabel(
                        newValue,
                        markID: mark.id,
                        meetingID: meeting.id
                    )
                }
            ))
            .textFieldStyle(.plain)

            Button(action: onConvert) {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .help(InterfaceLanguage.current.text("mark.convert"))
            .accessibilityLabel(Text("mark.convert"))

            Button(role: .destructive) {
                store.deleteMark(markID: mark.id, meetingID: meeting.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("mark.delete"))
        }
    }

    @ViewBuilder
    private var analysisSection: some View {
        if isAnalyzing {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("analysis.running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let error = store.markAnalysisErrors[mark.id] {
            VStack(alignment: .leading, spacing: 6) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Button {
                    analyze()
                } label: {
                    Label("common.retry", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } else if !mark.analysis.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                MarkdownView(markdown: mark.analysis)
                Button {
                    analyze()
                } label: {
                    Label("analysis.markRegenerate", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canAnalyze)
            }
        } else {
            Button {
                analyze()
            } label: {
                Label("analysis.markAction", systemImage: "sparkles")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canAnalyze)
        }
    }

    private func analyze() {
        Task {
            await store.analyzeMark(
                meetingID: meeting.id,
                markID: mark.id,
                settings: settings
            )
        }
    }
}

/// One key-note block: anchor chip, auto-growing IME-safe editor, LLM
/// analysis with regenerate, and delete. Cmd+Enter inserts a sibling block.
private struct KeyNoteBlockCard: View {
    let meeting: MeetingRecord
    let block: KeyNoteBlock
    let focusedBlock: FocusState<UUID?>.Binding
    let onSeek: (TimeInterval) -> Void
    let onDelete: () -> Void

    @Environment(MeetingStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var draft: String

    init(
        meeting: MeetingRecord,
        block: KeyNoteBlock,
        focusedBlock: FocusState<UUID?>.Binding,
        onSeek: @escaping (TimeInterval) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.meeting = meeting
        self.block = block
        self.focusedBlock = focusedBlock
        self.onSeek = onSeek
        self.onDelete = onDelete
        _draft = State(initialValue: block.text)
    }

    private var isAnalyzing: Bool {
        store.analyzingBlockIDs.contains(block.id)
    }

    private var canAnalyze: Bool {
        meeting.status == .completed
            && !meeting.transcriptSRT.isEmpty
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && settings.isSummaryConfigured
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Anchored blocks keep a chip row; unanchored blocks start straight
            // with their text and float the delete button in the corner, so no
            // empty header line sits above a one-line note.
            if block.anchorTime != nil {
                header
            }
            editor
                .padding(.trailing, block.anchorTime == nil ? 26 : 0)
            GeneratedAnalysisPanel {
                analysisSection
            }
        }
        .padding(12)
        .overlay(alignment: .topTrailing) {
            if block.anchorTime == nil {
                deleteButton
                    .padding(10)
            }
        }
        .background(
            .quaternary.opacity(0.35),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("notes.block.delete", systemImage: "trash")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let anchorTime = block.anchorTime {
                Button {
                    onSeek(anchorTime)
                } label: {
                    Label(
                        MeetingRowView.formatDuration(anchorTime),
                        systemImage: "bookmark.fill"
                    )
                    .font(.caption.monospacedDigit())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer(minLength: 0)

            deleteButton
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive, action: onDelete) {
            Image(systemName: "trash")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel(Text("notes.block.delete"))
    }

    private var editor: some View {
        // Vertical-axis TextField sizes itself to its content exactly, so a
        // one-line note takes one line — no fixed box, no measuring twin.
        TextField(
            InterfaceLanguage.current.text("notes.block.placeholder"),
            text: Binding(
                get: { draft },
                set: { newValue in
                    draft = newValue
                    store.updateBlockText(
                        newValue,
                        blockID: block.id,
                        meetingID: meeting.id
                    )
                }
            ),
            axis: .vertical
        )
        .textFieldStyle(.plain)
        .font(.body)
        .focused(focusedBlock, equals: block.id)
        .onKeyPress(phases: .down) { press in
            guard press.key == .return, press.modifiers.contains(.command) else {
                return .ignored
            }
            if let newID = store.addBlock(to: meeting.id, after: block.id) {
                focusedBlock.wrappedValue = newID
            }
            return .handled
        }
    }

    @ViewBuilder
    private var analysisSection: some View {
        if isAnalyzing {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("analysis.running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let error = store.blockAnalysisErrors[block.id] {
            VStack(alignment: .leading, spacing: 6) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Button {
                    analyze()
                } label: {
                    Label("common.retry", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } else if !block.analysis.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                MarkdownView(markdown: block.analysis)
                Button {
                    analyze()
                } label: {
                    Label("analysis.regenerate", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canAnalyze)
            }
        } else {
            Button {
                analyze()
            } label: {
                Label("analysis.action", systemImage: "sparkles")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canAnalyze)
        }
    }

    private func analyze() {
        Task {
            await store.analyzeBlock(
                meetingID: meeting.id,
                blockID: block.id,
                settings: settings
            )
        }
    }
}

/// Toolbar content shared by the detail column so export and import stay
/// pinned to the top-right in every state, including when no meeting is
/// selected.
struct DetailToolbar: ToolbarContent {
    let isExportEnabled: Bool
    let isImportEnabled: Bool
    let onExport: (MeetingExportKind) -> Void
    let onImport: () -> Void

    var body: some ToolbarContent {
        // Import leads the pair, export follows: bringing audio in is the
        // first step of the workflow, sending results out is the last.
        #if os(macOS)
        ToolbarItem(placement: .primaryAction) {
            Button(action: onImport) {
                Label(
                    InterfaceLanguage.current.text("meeting.importAudio"),
                    systemImage: "doc.badge.plus"
                )
                .labelStyle(.iconOnly)
                .symbolRenderingMode(.hierarchical)
            }
            .disabled(!isImportEnabled)
            .help(InterfaceLanguage.current.text("meeting.importAudio"))
        }
        #endif

        ToolbarItem(placement: .primaryAction) {
            // One export button with a menu of formats keeps three
            // near-identical document icons out of the toolbar. Standard
            // toolbar metrics center each glyph and size the shared capsule;
            // no custom frames or padding (toolbars.md: prefer standard
            // components and system-provided symbols).
            Menu {
                ForEach([MeetingExportKind.pdf, .markdown, .srt]) { kind in
                    Button {
                        onExport(kind)
                    } label: {
                        Label(kind.title, systemImage: kind.systemImage)
                    }
                }
            } label: {
                Label(
                    InterfaceLanguage.current.text("common.export"),
                    systemImage: "square.and.arrow.up"
                )
                .labelStyle(.iconOnly)
                .symbolRenderingMode(.hierarchical)
            }
            // Icon-only toolbar menu: hide the chevron so the glyph matches
            // the import button's optical box; the menu affordance is carried
            // by the help tooltip and the menu itself.
            .menuIndicator(.hidden)
            .disabled(!isExportEnabled)
            .help(InterfaceLanguage.current.text("common.export"))
        }
    }
}

/// Line-by-line transcript that highlights the cue currently being played and
/// lets the listener tap a line to jump the audio to it.
private struct TranscriptView: View {
    let cues: [TranscriptCue]
    let player: MeetingAudioPlayer
    var markers: [TranscriptMarker] = []
    var onConvertMark: ((UUID) -> Void)? = nil
    var onDeleteMark: ((UUID) -> Void)? = nil
    var onPlay: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Cues and time markers merged into one chronological timeline.
    private enum Row: Identifiable {
        case cue(TranscriptCue)
        case marker(TranscriptMarker)

        var id: UUID {
            switch self {
            case .cue(let cue):
                return cue.id
            case .marker(let marker):
                return marker.id
            }
        }

        var time: TimeInterval {
            switch self {
            case .cue(let cue):
                return cue.start
            case .marker(let marker):
                return marker.time
            }
        }
    }

    private var rows: [Row] {
        (cues.map(Row.cue) + markers.map(Row.marker))
            .sorted { $0.time < $1.time }
    }

    private var activeCueID: UUID? {
        guard player.duration > 0 else {
            return nil
        }
        return cues.last { $0.start <= player.currentTime + 0.05 }?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(rows) { row in
                        switch row {
                        case .cue(let cue):
                            cueRow(cue)
                                .id(cue.id)
                        case .marker(let marker):
                            markerRow(marker)
                                .id(marker.id)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .onChange(of: activeCueID) { _, newValue in
                if let newValue {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
        .overlay {
            if cues.isEmpty {
                ContentUnavailableView(
                    "meeting.transcriptEmptyTitle",
                    systemImage: "captions.bubble",
                    description: Text("meeting.transcriptEmptyDescription")
                )
            }
        }
        #if os(iOS)
        .safeAreaInset(edge: .top, spacing: 0) {
            playerBar
        }
        #endif
    }

    #if os(iOS)
    /// Fixed playback transport pinned above the transcript cues. Playback
    /// lives only here on iOS — no floating bottom bar.
    private var playerBar: some View {
        HStack(spacing: 12) {
            Button {
                if let onPlay {
                    onPlay()
                } else {
                    player.togglePlayback()
                }
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 28, height: 28)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: InterfaceLanguage.current.text(
                player.isPlaying ? "audio.pause" : "audio.play"
            )))

            Button {
                player.skip(by: -15)
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("audio.skipBackward"))

            Button {
                player.skip(by: 15)
            } label: {
                Image(systemName: "goforward.15")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("audio.skipForward"))

            Slider(
                value: Binding(
                    get: { min(player.currentTime, max(player.duration, 0.1)) },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.duration, 0.1)
            )
            .controlSize(.mini)

            Text(
                MeetingRowView.formatDuration(player.currentTime)
                    + " / " + MeetingRowView.formatDuration(player.duration)
            )
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
    #endif

    private func markerRow(_ marker: TranscriptMarker) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(MeetingRowView.formatDuration(marker.time))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)

            Label {
                Text(
                    marker.text.isEmpty
                        ? InterfaceLanguage.current.text("mark.emptyLabel")
                        : marker.text
                )
                .font(.callout)
                .lineLimit(2)
            } icon: {
                Image(systemName: "bookmark.fill")
                    .symbolRenderingMode(.hierarchical)
            }
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.accentColor.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            player.seek(to: marker.time)
        }
        .contextMenu {
            if marker.isMark {
                Button {
                    onConvertMark?(marker.id)
                } label: {
                    Label("mark.convert", systemImage: "square.and.pencil")
                }
                Button(role: .destructive) {
                    onDeleteMark?(marker.id)
                } label: {
                    Label("mark.delete", systemImage: "trash")
                }
            }
        }
        .accessibilityLabel(
            Text(verbatim: "\(MeetingRowView.formatDuration(marker.time)) \(marker.text)")
        )
    }

    private func cueRow(_ cue: TranscriptCue) -> some View {
        let isActive = cue.id == activeCueID

        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(cue.timeLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)

            Text(cue.text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isActive ? Color.accentColor.opacity(0.16) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            player.seek(to: cue.start)
        }
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Compact transport row that sits beside the meeting title (or below it in
/// narrow columns). One quiet line — skip, play/pause, skip, hairline seek
/// track, time — in monochrome with no background: the header is the content
/// layer, so glass stays on the toolbar above instead of stacking a second
/// capsule under the search field.
private struct MeetingAudioPlayerView: View {
    @Bindable var player: MeetingAudioPlayer
    /// The record's duration, so the transport stays visible for a remote
    /// meeting whose recording has not been downloaded yet.
    var recordDuration: TimeInterval = 0
    var isDownloading = false
    var onPlay: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if player.duration > 0 || recordDuration > 0 {
                HStack(spacing: 10) {
                    Button {
                        player.skip(by: -15)
                    } label: {
                        Image(systemName: "gobackward.15")
                            .font(.system(size: 14))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(InterfaceLanguage.current.text("audio.skipBackward"))

                    Button {
                        if let onPlay {
                            onPlay()
                        } else {
                            player.togglePlayback()
                        }
                    } label: {
                        if isDownloading {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 22, height: 22)
                        } else {
                            Image(
                                systemName: player.isPlaying
                                    ? "pause.fill"
                                    : "play.fill"
                            )
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 22, height: 22)
                            .contentShape(Circle())
                            .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .buttonStyle(.plain)
                    .help(
                        InterfaceLanguage.current.text(
                            player.isPlaying ? "audio.pause" : "audio.play"
                        )
                    )

                    Button {
                        player.skip(by: 15)
                    } label: {
                        Image(systemName: "goforward.15")
                            .font(.system(size: 14))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(InterfaceLanguage.current.text("audio.skipForward"))

                    progressTrack
                        .frame(width: 56)

                    // One animation clock drives the label and the track so
                    // the position glides every frame instead of stepping
                    // once per 200 ms poll.
                    TimelineView(.animation) { context in
                        Text(
                            "\(formatTime(player.playbackTime(at: context.date))) / \(formatTime(player.duration))"
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    }
                }
                .padding(.vertical, 2)
                // No glass capsule here: the header is the content layer, and
                // a second glass box under the toolbar's search field reads as
                // competing chrome (materials.md: glass stays on the functional
                // layer). The bare monochrome row keeps the corner quiet.
                .fixedSize()
                .animation(
                    reduceMotion ? nil : .snappy(duration: 0.22),
                    value: player.isPlaying
                )
            } else if let errorMessage = player.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Hairline capsule track inline with the transport. Tapping or dragging
    /// seeks; the hit shape extends past the 3 pt visual height. VoiceOver
    /// gets an adjustable element that jumps in 15-second steps.
    private var progressTrack: some View {
        TimelineView(.animation) { context in
            let time = player.playbackTime(at: context.date)

            GeometryReader { geometry in
                let width = geometry.size.width
                let fraction = player.duration > 0
                    ? min(max(time / player.duration, 0), 1)
                    : 0

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(.secondary)
                        .frame(width: max(3, width * fraction))
                }
                .contentShape(Capsule().inset(by: -8))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard width > 0 else {
                                return
                            }
                            let fraction = min(max(value.location.x / width, 0), 1)
                            player.seek(to: fraction * player.duration)
                        }
                )
                .accessibilityElement()
                .accessibilityLabel(InterfaceLanguage.current.text("audio.progress"))
                .accessibilityValue(
                    "\(formatTime(time)) / \(formatTime(player.duration))"
                )
                .accessibilityAdjustableAction { direction in
                    player.skip(by: direction == .increment ? 15 : -15)
                }
            }
            .frame(height: 3)
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else {
            return "00:00"
        }

        let total = Int(seconds.rounded())
        return String(
            format: "%02d:%02d",
            total / 60,
            total % 60
        )
    }
}

private extension MeetingDetailView {
    func statusSymbol(for meeting: MeetingRecord) -> String {
        switch meeting.status {
        case .pending:
            return "clock"
        case .processing:
            return "waveform"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    func statusColor(for meeting: MeetingRecord) -> Color {
        switch meeting.status {
        case .pending:
            return .secondary
        case .processing:
            return .accentColor
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }
}

private enum DetailContent: String, CaseIterable, Identifiable {
    case minutes
    case transcript
    case notes

    var id: Self { self }

    var title: String {
        let language = InterfaceLanguage.current

        switch self {
        case .minutes:
            return language.text("content.minutes")
        case .transcript:
            return language.text("content.transcriptSRT")
        case .notes:
            return language.text("content.notes")
        }
    }

    var systemImage: String {
        switch self {
        case .minutes:
            return "doc.text.fill"
        case .transcript:
            return "captions.bubble.fill"
        case .notes:
            return "note.text"
        }
    }
}
