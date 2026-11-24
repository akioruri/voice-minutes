import AVFoundation
import Foundation
import Observation

/// Owns the meeting library, folder state, and the transcription pipeline.
@Observable
final class MeetingStore {
    private(set) var folders: [MeetingFolder] = []
    private(set) var meetings: [MeetingRecord] = []
    var selectedLibrary: LibrarySelection?
    var selectedMeetingID: UUID?
    private(set) var isBusy = false
    private(set) var progress = 0.0
    private(set) var processingMessage = ""
    private(set) var processingMeetingID: UUID?
    var lastError: String?

    /// Notifies the sync controller after every persisted local mutation.
    var libraryDidChange: (() -> Void)?

    private let fileManager = FileManager.default
    /// Suppresses the change hook while remote data is being applied.
    private var isApplyingRemote = false
    private let rootURL: URL
    private let meetingsDirectory: URL
    private let indexURL: URL
    private let chunker = AudioChunker()
    private var hasPersistedLibrary = false
    private var librarySaveTask: Task<Void, Never>?

    init(rootURL customRoot: URL? = nil) {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory

        rootURL = customRoot ?? applicationSupport.appendingPathComponent(
            "VoiceMinutes",
            isDirectory: true
        )
        meetingsDirectory = rootURL.appendingPathComponent(
            "Meetings",
            isDirectory: true
        )
        indexURL = rootURL.appendingPathComponent("meetings.json")

        try? fileManager.createDirectory(
            at: meetingsDirectory,
            withIntermediateDirectories: true
        )
        loadLibrary()
        ensureFoldersAndAssignments()
        selectedLibrary = .all
        selectedMeetingID = allMeetings.first?.id
    }

    // MARK: - Library queries

    var selectedMeeting: MeetingRecord? {
        guard let selectedMeetingID else {
            return nil
        }
        return meetings.first { $0.id == selectedMeetingID }
    }

    var selectedFolder: MeetingFolder? {
        guard let selectedFolderID else {
            return nil
        }
        return folders.first { $0.id == selectedFolderID }
    }

    var selectedFolderID: UUID? {
        guard case .folder(let id) = selectedLibrary else {
            return nil
        }
        return id
    }

    var allMeetings: [MeetingRecord] {
        meetings
            .filter { !$0.isDeleted }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var recentlyDeletedMeetings: [MeetingRecord] {
        meetings
            .filter(\.isDeleted)
            .sorted {
                ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast)
            }
    }

    func meetings(in folderID: UUID) -> [MeetingRecord] {
        meetings
            .filter { $0.folderID == folderID && !$0.isDeleted }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func meetingCount(in folderID: UUID) -> Int {
        meetings.lazy.filter { $0.folderID == folderID && !$0.isDeleted }.count
    }

    func meetings(for selection: LibrarySelection?) -> [MeetingRecord] {
        switch selection {
        case .all:
            return allMeetings
        case .recentlyDeleted:
            return recentlyDeletedMeetings
        case .folder(let id):
            return meetings(in: id)
        case nil:
            return []
        }
    }

    // MARK: - Folders

    @discardableResult
    func createFolder(name: String) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = MeetingFolder(
            name: trimmed.isEmpty
                ? InterfaceLanguage.current.text("folder.new")
                : trimmed
        )
        folders.append(folder)
        folders.sort { $0.createdAt < $1.createdAt }
        selectLibrary(.folder(folder.id))
        saveLibrary()
        return folder.id
    }

    func renameFolder(_ id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = folders.firstIndex(where: { $0.id == id }) else {
            return
        }

        folders[index].name = trimmed
        folders[index].updatedAt = Date()
        saveLibrary()
    }

    func deleteFolder(_ id: UUID) {
        guard !isBusy,
              let index = folders.firstIndex(where: { $0.id == id }) else {
            return
        }

        let deletedAt = Date()
        folders.remove(at: index)

        // The last folder may be deleted; its meetings move to Recently
        // Deleted and simply lose their folder assignment.
        for meetingIndex in meetings.indices where meetings[meetingIndex].folderID == id {
            meetings[meetingIndex].folderID = nil
            meetings[meetingIndex].deletedAt = deletedAt
            meetings[meetingIndex].touch()
        }

        selectLibrary(.all)
        saveLibrary()
    }

    /// Assigns a minutes-prompt override to a folder (nil = global default).
    func setFolderPrompt(_ id: UUID, promptID: UUID?) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else {
            return
        }
        folders[index].promptID = promptID
        touchFolder(id)
        saveLibrary()
    }

    // MARK: - Meeting metadata

    func renameMeeting(_ id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = meetings.firstIndex(where: { $0.id == id }) else {
            return
        }

        meetings[index].title = trimmed
        meetings[index].touch()
        saveLibrary()
    }

    /// Moves a meeting into another folder, or out of every folder when nil.
    func moveMeeting(_ id: UUID, to folderID: UUID?) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else {
            return
        }

        guard meetings[index].folderID != folderID else {
            return
        }

        if let folderID {
            touchFolder(folderID)
        }
        meetings[index].folderID = folderID
        meetings[index].touch()
        saveLibrary()
    }

    func selectLibrary(_ selection: LibrarySelection?) {
        selectedLibrary = selection
        selectedMeetingID = meetings(for: selection).first?.id
    }

    func selectFolder(_ id: UUID?) {
        selectLibrary(id.map(LibrarySelection.folder))
    }

    // MARK: - Meeting lifecycle

    func importAudio(
        from sourceURL: URL,
        title: String?,
        folderID: UUID? = nil,
        settings: AppSettings
    ) async {
        guard !isBusy else {
            lastError = InterfaceLanguage.current.text("error.busy")
            return
        }

        let hasSecurityAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            // A nil folderID leaves the meeting unfiled. Callers decide the
            // default, so a recording only lands in a folder when the user
            // was already browsing one.
            let targetFolderID = folderID

            let id = UUID()
            let meetingDirectory = directoryURL(for: id)
            try fileManager.createDirectory(
                at: meetingDirectory,
                withIntermediateDirectories: true
            )

            let fileExtension = sourceURL.pathExtension.isEmpty
                ? "m4a"
                : sourceURL.pathExtension.lowercased()
            let audioFileName = "audio.\(fileExtension)"
            let destination = meetingDirectory.appendingPathComponent(audioFileName)
            try fileManager.copyItem(at: sourceURL, to: destination)

            let inferredTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalTitle = (inferredTitle?.isEmpty == false ? inferredTitle : nil)
                ?? sourceURL.deletingPathExtension().lastPathComponent
            let duration = await audioDuration(for: destination)

            let record = MeetingRecord(
                id: id,
                folderID: targetFolderID,
                title: finalTitle,
                duration: duration,
                audioFileName: audioFileName
            )
            meetings.insert(record, at: 0)
            if let targetFolderID {
                touchFolder(targetFolderID)
                selectedLibrary = .folder(targetFolderID)
            } else {
                // Surface the unfiled meeting in All Minutes when the library
                // was not showing a folder.
                selectedLibrary = .all
            }
            selectedMeetingID = id
            saveLibrary()

            await processMeeting(id: id, settings: settings)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Recording

    /// Creates the meeting record the moment recording starts, so the detail
    /// view opens right away and key notes can be typed while the meeting is
    /// still in progress.
    @discardableResult
    func beginRecording(folderID: UUID?) -> UUID {
        let title = InterfaceLanguage.current.format(
            "meeting.generatedTitle",
            Self.formattedTitleDate(Date())
        )
        let record = MeetingRecord(
            folderID: folderID,
            title: title,
            audioFileName: "audio.m4a",
            status: .pending
        )
        meetings.insert(record, at: 0)
        try? fileManager.createDirectory(
            at: directoryURL(for: record.id),
            withIntermediateDirectories: true
        )

        if let folderID {
            selectedLibrary = .folder(folderID)
        } else {
            // Surface the unfiled recording in All Minutes.
            selectedLibrary = .all
        }
        selectedMeetingID = record.id
        saveLibrary()
        return record.id
    }

    /// Attaches the finished recording to the meeting created by
    /// `beginRecording` and starts the processing pipeline.
    func finishRecording(
        meetingID: UUID,
        recordingURL: URL,
        settings: AppSettings
    ) async {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else {
            try? fileManager.removeItem(at: recordingURL)
            return
        }

        let destination = audioURL(for: meetings[index])

        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: recordingURL, to: destination)
        } catch {
            try? fileManager.removeItem(at: recordingURL)
            lastError = error.localizedDescription
            return
        }

        let duration = await audioDuration(for: destination)
        guard let refreshedIndex = meetings.firstIndex(
            where: { $0.id == meetingID }
        ) else {
            return
        }
        meetings[refreshedIndex].duration = duration
        meetings[refreshedIndex].touch()
        saveLibrary()

        await processMeeting(id: meetingID, settings: settings)
    }

    /// Drops a placeholder meeting whose recording never started, so a denied
    /// microphone permission leaves no trace in the library.
    func cancelRecording(meetingID: UUID) {
        meetings.removeAll { $0.id == meetingID }
        try? fileManager.removeItem(at: directoryURL(for: meetingID))

        if selectedMeetingID == meetingID {
            selectedMeetingID = meetings(for: selectedLibrary).first?.id
        }
        saveLibrary()
    }

    // MARK: - Key notes & marks

    /// Adds a key-note block, optionally after a given block (Cmd+Enter) and
    /// optionally anchored to a mark's time. Returns the new block's id so
    /// the editor can focus it.
    @discardableResult
    func addBlock(
        to meetingID: UUID,
        after blockID: UUID? = nil,
        anchorTime: TimeInterval? = nil,
        text: String = ""
    ) -> UUID? {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else {
            return nil
        }
        let block = KeyNoteBlock(text: text, anchorTime: anchorTime)
        if let blockID,
           let position = meetings[index].keyNoteBlocks.firstIndex(
               where: { $0.id == blockID }
           ) {
            meetings[index].keyNoteBlocks.insert(block, at: position + 1)
        } else {
            meetings[index].keyNoteBlocks.append(block)
        }
        refreshDerivedNotes(at: index)
        meetings[index].touch()
        scheduleLibrarySave()
        return block.id
    }

    /// Stores a block's text. The record updates immediately so processing
    /// always reads the latest content, while persistence is debounced to
    /// avoid a disk write on every keystroke.
    func updateBlockText(_ text: String, blockID: UUID, meetingID: UUID) {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }),
              let blockIndex = meetings[index].keyNoteBlocks.firstIndex(
                  where: { $0.id == blockID }
              ) else {
            return
        }
        meetings[index].keyNoteBlocks[blockIndex].text = text
        meetings[index].keyNoteBlocks[blockIndex].touch()
        refreshDerivedNotes(at: index)
        meetings[index].touch()
        scheduleLibrarySave()
    }

    func deleteBlock(blockID: UUID, meetingID: UUID) {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else {
            return
        }
        meetings[index].keyNoteBlocks.removeAll { $0.id == blockID }
        refreshDerivedNotes(at: index)
        meetings[index].touch()
        saveLibrary()
    }

    func setBlockAnalysis(_ analysis: String, blockID: UUID, meetingID: UUID) {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }),
              let blockIndex = meetings[index].keyNoteBlocks.firstIndex(
                  where: { $0.id == blockID }
              ) else {
            return
        }
        meetings[index].keyNoteBlocks[blockIndex].analysis = analysis
        meetings[index].keyNoteBlocks[blockIndex].touch()
        meetings[index].touch()
        saveLibrary()
    }

    /// Drops a time mark at the current recording position.
    @discardableResult
    func addMark(to meetingID: UUID, time: TimeInterval) -> UUID? {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else {
            return nil
        }
        let mark = MeetingMark(time: time)
        meetings[index].marks.append(mark)
        meetings[index].marks.sort { $0.time < $1.time }
        meetings[index].touch()
        saveLibrary()
        return mark.id
    }

    func updateMarkLabel(_ label: String, markID: UUID, meetingID: UUID) {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }),
              let markIndex = meetings[index].marks.firstIndex(
                  where: { $0.id == markID }
              ) else {
            return
        }
        meetings[index].marks[markIndex].label = label
        meetings[index].touch()
        scheduleLibrarySave()
    }

    func deleteMark(markID: UUID, meetingID: UUID) {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else {
            return
        }
        meetings[index].marks.removeAll { $0.id == markID }
        meetings[index].touch()
        saveLibrary()
    }

    /// Converts a mark into an anchored block (time becomes the anchor,
    /// label the text) and removes the mark. Returns the new block's id.
    @discardableResult
    func convertMark(markID: UUID, meetingID: UUID) -> UUID? {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }),
              let mark = meetings[index].marks.first(where: { $0.id == markID }) else {
            return nil
        }
        let block = KeyNoteBlock(converting: mark)
        meetings[index].marks.removeAll { $0.id == markID }
        meetings[index].keyNoteBlocks.append(block)
        refreshDerivedNotes(at: index)
        meetings[index].touch()
        saveLibrary()
        return block.id
    }

    private func refreshDerivedNotes(at index: Int) {
        meetings[index].notesMarkdown = MeetingRecord.derivedNotes(
            from: meetings[index].keyNoteBlocks
        )
    }

    // MARK: - Key-point analysis

    private(set) var analyzingBlockIDs: Set<UUID> = []
    private(set) var blockAnalysisErrors: [UUID: String] = [:]

    /// Runs the LLM explanation for one block. Independent of the main
    /// pipeline: several blocks can analyze concurrently.
    func analyzeBlock(meetingID: UUID, blockID: UUID, settings: AppSettings) async {
        guard let meeting = meetings.first(where: { $0.id == meetingID }),
              meeting.status == .completed,
              let block = meeting.keyNoteBlocks.first(where: { $0.id == blockID }),
              !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !analyzingBlockIDs.contains(blockID) else {
            return
        }
        let transcript = plainTranscript(from: meeting.transcriptSRT)
        guard !transcript.isEmpty else {
            return
        }
        guard settings.isSummaryConfigured else {
            blockAnalysisErrors[blockID] = InterfaceLanguage.current.text(
                "error.configureProviders"
            )
            return
        }

        analyzingBlockIDs.insert(blockID)
        blockAnalysisErrors[blockID] = nil
        let service = CloudAIService(
            provider: settings.summaryProvider,
            configuration: settings.summaryConfiguration,
            promptTemplate: settings.promptTemplate
        )
        do {
            let analysis = try await service.analyzeKeyPoint(
                transcript: transcript,
                keyPoint: block.text,
                promptTemplate: settings.keyPointPromptTemplate
            )
            setBlockAnalysis(analysis, blockID: blockID, meetingID: meetingID)
        } catch {
            blockAnalysisErrors[blockID] = error.localizedDescription
        }
        analyzingBlockIDs.remove(blockID)
    }

    // MARK: - Time-mark analysis

    private(set) var analyzingMarkIDs: Set<UUID> = []
    private(set) var markAnalysisErrors: [UUID: String] = [:]

    /// Summarizes the transcript window around a mark with the editable
    /// mark prompt; the label (if any) rides along as extra context.
    func analyzeMark(meetingID: UUID, markID: UUID, settings: AppSettings) async {
        guard let meeting = meetings.first(where: { $0.id == meetingID }),
              meeting.status == .completed,
              let mark = meeting.marks.first(where: { $0.id == markID }),
              !analyzingMarkIDs.contains(markID) else {
            return
        }
        guard !meeting.transcriptSRT.isEmpty else {
            return
        }
        guard settings.isSummaryConfigured else {
            markAnalysisErrors[markID] = InterfaceLanguage.current.text(
                "error.configureProviders"
            )
            return
        }

        analyzingMarkIDs.insert(markID)
        markAnalysisErrors[markID] = nil
        let window = SRTBuilder.windowText(
            from: meeting.transcriptSRT,
            around: mark.time
        )
        let timeLabel = MeetingRowView.formatDuration(mark.time)
        let keyPoint = mark.label.isEmpty
            ? "[time point \(timeLabel)]"
            : "[time point \(timeLabel)] \(mark.label)"
        let service = CloudAIService(
            provider: settings.summaryProvider,
            configuration: settings.summaryConfiguration,
            promptTemplate: settings.promptTemplate
        )
        do {
            let analysis = try await service.analyzeKeyPoint(
                transcript: window,
                keyPoint: keyPoint,
                promptTemplate: settings.markPromptTemplate
            )
            setMarkAnalysis(analysis, markID: markID, meetingID: meetingID)
        } catch {
            markAnalysisErrors[markID] = error.localizedDescription
        }
        analyzingMarkIDs.remove(markID)
    }

    func setMarkAnalysis(_ analysis: String, markID: UUID, meetingID: UUID) {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }),
              let markIndex = meetings[index].marks.firstIndex(
                  where: { $0.id == markID }
              ) else {
            return
        }
        meetings[index].marks[markIndex].analysis = analysis
        meetings[index].touch()
        saveLibrary()
    }

    /// Default behavior: once the transcript is ready, summarize every mark
    /// that has no analysis yet, sequentially to keep request bursts small.
    private func autoAnalyzeMarksIfNeeded(meetingID: UUID, settings: AppSettings) {
        guard settings.autoAnalyzeMarks,
              let meeting = meetings.first(where: { $0.id == meetingID }),
              meeting.status == .completed else {
            return
        }
        let pending = meeting.marks.filter { $0.analysis.isEmpty }.map(\.id)
        guard !pending.isEmpty else {
            return
        }
        Task { [weak self] in
            for markID in pending {
                await self?.analyzeMark(
                    meetingID: meetingID,
                    markID: markID,
                    settings: settings
                )
            }
        }
    }

    // MARK: - Regeneration

    /// Manually regenerates the minutes: either re-summarizing the existing
    /// transcript or re-running the full transcription pipeline.
    func regenerateMinutes(
        meetingID: UUID,
        retranscribe: Bool,
        settings: AppSettings
    ) async {
        guard !isBusy else {
            lastError = InterfaceLanguage.current.text("error.busy")
            return
        }
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }),
              meetings[index].status == .completed else {
            return
        }

        if retranscribe {
            guard hasLocalAudio(for: meetings[index]) else {
                lastError = InterfaceLanguage.current.text("regen.needAudio")
                return
            }
            await processMeeting(id: meetingID, settings: settings)
        } else {
            await resummarize(meetingID: meetingID, settings: settings)
        }
    }

    private func resummarize(meetingID: UUID, settings: AppSettings) async {
        guard settings.isSummaryConfigured else {
            lastError = InterfaceLanguage.current.text("error.configureProviders")
            return
        }
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else {
            return
        }
        let transcript = plainTranscript(from: meetings[index].transcriptSRT)
        guard !transcript.isEmpty else {
            return
        }

        isBusy = true
        progress = 0.5
        processingMessage = InterfaceLanguage.current.text("progress.generatingMinutes")
        processingMeetingID = meetingID
        meetings[index].status = .processing
        meetings[index].errorMessage = nil
        meetings[index].touch()
        saveLibrary()

        defer {
            isBusy = false
            processingMessage = ""
            processingMeetingID = nil
        }

        do {
            let service = CloudAIService(
                provider: settings.summaryProvider,
                configuration: settings.summaryConfiguration,
                promptTemplate: minutesPromptBody(
                    for: meetings[index],
                    settings: settings
                )
            )
            let markdown = try await service.summarize(
                transcript: transcript,
                notes: notesInput(for: meetings[index])
            )
            try markdown.write(
                to: markdownURL(for: meetings[index]),
                atomically: true,
                encoding: .utf8
            )
            guard let refreshedIndex = meetings.firstIndex(
                where: { $0.id == meetingID }
            ) else {
                return
            }
            meetings[refreshedIndex].minutesMarkdown = markdown
            meetings[refreshedIndex].status = .completed
            meetings[refreshedIndex].errorMessage = nil
            meetings[refreshedIndex].touch()
            progress = 1
            processingMessage = InterfaceLanguage.current.text("progress.completed")
            saveLibrary()
        } catch {
            if let refreshedIndex = meetings.firstIndex(
                where: { $0.id == meetingID }
            ) {
                meetings[refreshedIndex].status = .failed
                meetings[refreshedIndex].errorMessage = error.localizedDescription
                meetings[refreshedIndex].touch()
            }
            lastError = error.localizedDescription
            saveLibrary()
        }
    }

    /// Resolves the minutes prompt for a meeting: folder override → global
    /// default → localized built-in.
    private func minutesPromptBody(
        for meeting: MeetingRecord,
        settings: AppSettings
    ) -> String {
        MinutesPromptResolver.body(
            folderPromptID: folders.first { $0.id == meeting.folderID }?.promptID,
            defaultPromptID: settings.defaultMinutesPromptID,
            library: settings.minutesPrompts,
            builtIn: AppSettings.defaultPrompt
        )
    }

    /// Plain transcript text for LLM input, reconstructed from the SRT cues.
    private func plainTranscript(from srt: String) -> String {
        SRTBuilder.cues(from: srt)
            .map(\.text)
            .joined(separator: "\n")
    }

    /// The priority notes section for the summary model: every block's text
    /// plus its analysis, replacing the legacy single notes string.
    private func notesInput(for meeting: MeetingRecord) -> String {
        meeting.keyNoteBlocks.compactMap { block in
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let analysis = block.analysis
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || !analysis.isEmpty else {
                return nil
            }
            if analysis.isEmpty {
                return text
            }
            if text.isEmpty {
                return "[Key point analysis]\n\(analysis)"
            }
            return "\(text)\n[Key point analysis]\n\(analysis)"
        }
        .joined(separator: "\n\n")
    }

    private func scheduleLibrarySave() {
        librarySaveTask?.cancel()
        librarySaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else {
                return
            }
            self?.saveLibrary()
        }
    }

    /// Writes any debounced change to disk right away, e.g. when the detail
    /// view goes away, so a quit inside the debounce window loses nothing.
    func flushPendingLibrarySave() {
        librarySaveTask?.cancel()
        librarySaveTask = nil
        saveLibrary()
    }

    func retry(
        meetingID: UUID,
        settings: AppSettings
    ) async {
        await processMeeting(id: meetingID, settings: settings)
    }

    func deleteMeeting(_ id: UUID) {
        guard !isBusy else {
            lastError = InterfaceLanguage.current.text(
                "error.cannotDeleteDuringProcessing"
            )
            return
        }

        guard let index = meetings.firstIndex(where: { $0.id == id }) else {
            return
        }
        meetings[index].deletedAt = Date()
        meetings[index].touch()
        if let folderID = meetings[index].folderID {
            touchFolder(folderID)
        }

        if selectedMeetingID == id {
            selectedMeetingID = meetings(for: selectedLibrary).first?.id
        }
        saveLibrary()
    }

    func restoreMeeting(_ id: UUID) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else {
            return
        }

        meetings[index].deletedAt = nil
        meetings[index].touch()
        // An unfiled meeting stays unfiled instead of falling back to the
        // first folder, matching how new recordings are stored.
        if let folderID = meetings[index].folderID {
            selectedLibrary = .folder(folderID)
            selectedMeetingID = id
            touchFolder(folderID)
        }
        saveLibrary()
    }

    func permanentlyDeleteMeeting(_ id: UUID) {
        guard !isBusy else {
            lastError = InterfaceLanguage.current.text(
                "error.cannotDeleteDuringProcessing"
            )
            return
        }

        meetings.removeAll { $0.id == id }
        try? fileManager.removeItem(at: directoryURL(for: id))

        if selectedMeetingID == id {
            selectedMeetingID = meetings(for: selectedLibrary).first?.id
        }
        saveLibrary()
    }

    func emptyTrash() {
        guard !isBusy else {
            lastError = InterfaceLanguage.current.text(
                "error.cannotEmptyTrashDuringProcessing"
            )
            return
        }

        let deletedIDs = meetings.filter(\.isDeleted).map(\.id)
        meetings.removeAll(where: \.isDeleted)
        for id in deletedIDs {
            try? fileManager.removeItem(at: directoryURL(for: id))
        }
        if selectedMeeting?.isDeleted != false {
            selectedMeetingID = nil
        }
        saveLibrary()
    }

    func clearError() {
        lastError = nil
    }

    /// Local CKSyncEngine state; lives in the library root but is never synced.
    var syncStateURL: URL {
        rootURL.appendingPathComponent("sync-state.data")
    }

    func hasLocalAudio(for meeting: MeetingRecord) -> Bool {
        fileManager.fileExists(atPath: audioURL(for: meeting).path)
    }

    func audioURL(for meeting: MeetingRecord) -> URL {
        directoryURL(for: meeting.id)
            .appendingPathComponent(meeting.audioFileName)
    }

    func srtURL(for meeting: MeetingRecord) -> URL {
        directoryURL(for: meeting.id)
            .appendingPathComponent("transcript.srt")
    }

    func markdownURL(for meeting: MeetingRecord) -> URL {
        directoryURL(for: meeting.id)
            .appendingPathComponent("minutes.md")
    }

    // MARK: - Processing

    private func processMeeting(
        id: UUID,
        settings: AppSettings
    ) async {
        guard !isBusy else {
            if let index = meetings.firstIndex(where: { $0.id == id }),
               meetings[index].status == .pending {
                meetings[index].status = .failed
                meetings[index].errorMessage = InterfaceLanguage.current.text(
                    "error.busyRetry"
                )
                meetings[index].touch()
                saveLibrary()
            }
            lastError = InterfaceLanguage.current.text("error.busy")
            return
        }
        guard settings.isConfigured else {
            if let index = meetings.firstIndex(where: { $0.id == id }) {
                meetings[index].status = .failed
                meetings[index].errorMessage = InterfaceLanguage.current.text(
                    "error.configureProviders"
                )
                meetings[index].touch()
                saveLibrary()
            }
            lastError = InterfaceLanguage.current.text("error.configureProviders")
            return
        }
        guard let initialIndex = meetings.firstIndex(where: { $0.id == id }) else {
            return
        }

        isBusy = true
        progress = 0
        processingMessage = InterfaceLanguage.current.text("progress.prepareAudio")
        processingMeetingID = id
        meetings[initialIndex].status = .processing
        meetings[initialIndex].errorMessage = nil
        meetings[initialIndex].touch()
        saveLibrary()

        let workDirectory = rootURL
            .appendingPathComponent("Processing", isDirectory: true)
            .appendingPathComponent("\(id)-\(UUID().uuidString)", isDirectory: true)

        defer {
            try? fileManager.removeItem(at: workDirectory)
            isBusy = false
            processingMessage = ""
            processingMeetingID = nil
        }

        do {
            let meeting = meetings[initialIndex]
            let sourceURL = audioURL(for: meeting)
            let summaryService = CloudAIService(
                provider: settings.summaryProvider,
                configuration: settings.summaryConfiguration,
                promptTemplate: minutesPromptBody(for: meeting, settings: settings)
            )

            let segments: [TranscriptSegment]

            if settings.useLocalTranscription {
                progress = 0.15
                processingMessage = InterfaceLanguage.current.text(
                    "progress.localTranscription"
                )
                segments = try await LocalSpeechTranscriber().transcribe(
                    fileURL: sourceURL,
                    localeIdentifier: settings.localTranscriptionLocaleIdentifier
                )
                progress = 0.82
            } else {
                let chunks = try await chunker.split(
                    sourceURL: sourceURL,
                    outputDirectory: workDirectory,
                    targetChunkDuration: settings.transcriptionProvider.maximumChunkDuration
                )

                let transcriptionService = CloudAIService(
                    provider: settings.transcriptionProvider,
                    configuration: settings.transcriptionConfiguration
                )

                segments = try await transcribeChunksInParallel(
                    chunks,
                    service: transcriptionService,
                    maximumConcurrency: settings.transcriptionProvider.maximumConcurrentRequests
                )
            }

            let sortedSegments = segments.sorted { $0.start < $1.start }
            guard !sortedSegments.isEmpty else {
                throw MeetingProcessingError.emptyTranscript
            }

            let srt = SRTBuilder.make(from: sortedSegments)
            let transcript = sortedSegments
                .map(\.text)
                .joined(separator: "\n")

            progress = 0.82
            processingMessage = InterfaceLanguage.current.text(
                "progress.generatingMinutes"
            )
            // Read the notes now rather than from the snapshot above, so key
            // points typed while transcription was running are included.
            let notes = notesInput(for: meetings[initialIndex])
            let markdown = try await summaryService.summarize(
                transcript: transcript,
                notes: notes
            )

            try srt.write(
                to: srtURL(for: meeting),
                atomically: true,
                encoding: .utf8
            )
            try markdown.write(
                to: markdownURL(for: meeting),
                atomically: true,
                encoding: .utf8
            )

            guard let index = meetings.firstIndex(where: { $0.id == id }) else {
                return
            }
            meetings[index].transcriptSRT = srt
            meetings[index].minutesMarkdown = markdown
            meetings[index].status = .completed
            meetings[index].errorMessage = nil
            meetings[index].touch()

            progress = 1
            processingMessage = InterfaceLanguage.current.text("progress.completed")
            saveLibrary()
            autoAnalyzeMarksIfNeeded(meetingID: id, settings: settings)
        } catch {
            if let index = meetings.firstIndex(where: { $0.id == id }) {
                meetings[index].status = .failed
                meetings[index].errorMessage = error.localizedDescription
                meetings[index].touch()
            }
            lastError = error.localizedDescription
            saveLibrary()
        }
    }

    private func globalSegments(
        from response: CloudTranscriptionResponse,
        chunk: AudioChunk
    ) -> [TranscriptSegment] {
        let rawSegments = response.segments ?? []
        var result: [TranscriptSegment] = []

        for segment in rawSegments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  let relativeStart = segment.start,
                  let relativeEnd = segment.end else {
                continue
            }

            // Cloud timestamps are relative to each uploaded chunk.
            let start = chunk.originalStart + max(0, relativeStart)
            let end = min(
                chunk.originalEnd,
                max(start + 0.2, chunk.originalStart + relativeEnd)
            )

            result.append(
                TranscriptSegment(
                    start: start,
                    end: end,
                    text: text,
                    speakerID: segment.speakerID
                )
            )
        }

        if result.isEmpty,
           let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            result.append(
                TranscriptSegment(
                    start: chunk.originalStart,
                    end: chunk.originalEnd,
                    text: text
                )
            )
        }

        return result
    }

    private func transcribeChunksInParallel(
        _ chunks: [AudioChunk],
        service: CloudAIService,
        maximumConcurrency: Int
    ) async throws -> [TranscriptSegment] {
        guard !chunks.isEmpty else {
            return []
        }

        // Keep a bounded number of uploads in flight for provider rate limits.
        let concurrency = max(1, min(maximumConcurrency, chunks.count))
        var responses: [Int: CloudTranscriptionResponse] = [:]
        var nextChunkIndex = 0
        var completedCount = 0

        try await withThrowingTaskGroup(
            of: (Int, CloudTranscriptionResponse).self
        ) { group in
            func addNextTask() {
                guard nextChunkIndex < chunks.count else {
                    return
                }

                let index = nextChunkIndex
                let chunk = chunks[index]
                nextChunkIndex += 1

                group.addTask {
                    let response = try await service.transcribe(fileURL: chunk.fileURL)
                    return (index, response)
                }
            }

            for _ in 0..<concurrency {
                addNextTask()
            }

            while let (index, response) = try await group.next() {
                responses[index] = response
                completedCount += 1
                progress = 0.1 + (Double(completedCount) / Double(chunks.count)) * 0.65
                processingMessage = InterfaceLanguage.current.format(
                    "progress.chunks",
                    completedCount,
                    chunks.count
                )
                addNextTask()
            }
        }

        return chunks.flatMap { chunk -> [TranscriptSegment] in
            guard let response = responses[chunk.index] else {
                return []
            }
            return globalSegments(from: response, chunk: chunk)
        }
    }

    private func audioDuration(for url: URL) async -> TimeInterval {
        do {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            return duration.isFinite ? max(0, duration) : 0
        } catch {
            return 0
        }
    }

    private func directoryURL(for id: UUID) -> URL {
        meetingsDirectory.appendingPathComponent(
            id.uuidString,
            isDirectory: true
        )
    }

    // MARK: - Remote sync

    /// Merges fetched CloudKit records into the library (last writer wins),
    /// materializes remote documents, and applies hard deletions. The change
    /// hook is suppressed so applied data is never echoed back to iCloud.
    func applyRemoteSync(
        meetings remoteMeetings: [MeetingRecord],
        folders remoteFolders: [MeetingFolder],
        deletedMeetingIDs: Set<UUID>,
        deletedFolderIDs: Set<UUID>
    ) {
        isApplyingRemote = true
        defer {
            isApplyingRemote = false
            saveLibrary()
        }

        meetings = LibraryMerge.mergeMeetings(local: meetings, remote: remoteMeetings)
        folders = LibraryMerge.mergeFolders(local: folders, remote: remoteFolders)

        if !deletedMeetingIDs.isEmpty {
            meetings.removeAll { deletedMeetingIDs.contains($0.id) }
            for id in deletedMeetingIDs {
                try? fileManager.removeItem(at: directoryURL(for: id))
            }
        }
        if !deletedFolderIDs.isEmpty {
            folders.removeAll { deletedFolderIDs.contains($0.id) }
        }

        let mergedIDs = Set(meetings.map(\.id))
        for meeting in remoteMeetings where mergedIDs.contains(meeting.id) {
            writeRemoteDocuments(for: meeting)
        }

        reassignStaleFolderReferences()

        if let selectedMeetingID,
           !meetings.contains(where: { $0.id == selectedMeetingID }) {
            self.selectedMeetingID = meetings(for: selectedLibrary).first?.id
        }
    }

    /// Keeps the on-disk transcript/minutes in step with merged records so
    /// export and playback work without re-fetching anything.
    private func writeRemoteDocuments(for meeting: MeetingRecord) {
        try? fileManager.createDirectory(
            at: directoryURL(for: meeting.id),
            withIntermediateDirectories: true
        )
        if !meeting.transcriptSRT.isEmpty {
            let url = srtURL(for: meeting)
            let existing = try? String(contentsOf: url, encoding: .utf8)
            if existing != meeting.transcriptSRT {
                try? meeting.transcriptSRT.write(
                    to: url,
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
        if !meeting.minutesMarkdown.isEmpty {
            let url = markdownURL(for: meeting)
            let existing = try? String(contentsOf: url, encoding: .utf8)
            if existing != meeting.minutesMarkdown {
                try? meeting.minutesMarkdown.write(
                    to: url,
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
    }

    // MARK: - Persistence

    private func loadLibrary() {
        do {
            let data = try Data(contentsOf: indexURL)
            let decoder = JSONDecoder()

            if let library = try? decoder.decode(
                MeetingLibrarySnapshot.self,
                from: data
            ) {
                folders = library.folders
                meetings = library.meetings
                hasPersistedLibrary = true
            } else {
                folders = []
                meetings = try decoder.decode([MeetingRecord].self, from: data)
                hasPersistedLibrary = true
            }
        } catch {
            folders = []
            meetings = []
        }

        meetings = meetings
            .sorted { $0.createdAt > $1.createdAt }
            .map { meeting in
                var recovered = meeting
                recovered.status = .failed

                switch meeting.status {
                case .processing:
                    recovered.errorMessage = InterfaceLanguage.current.text(
                        "error.previousProcessingInterrupted"
                    )
                case .pending:
                    // Nothing records while the app is closed, so a pending
                    // meeting is a recording that never finished. Failing it
                    // keeps the row actionable through the retry button.
                    recovered.errorMessage = InterfaceLanguage.current.text(
                        "error.recordingInterrupted"
                    )
                case .completed, .failed:
                    return meeting
                }

                recovered.touch()
                return recovered
            }
    }

    private func ensureFoldersAndAssignments() {
        // Only a first launch seeds the default folder; an empty folder list
        // written by the user (they deleted the last folder) is preserved.
        if folders.isEmpty, !hasPersistedLibrary {
            folders = [
                MeetingFolder(
                    name: InterfaceLanguage.current.text("folder.uncategorized")
                )
            ]
        }
        folders.sort { $0.createdAt < $1.createdAt }

        reassignStaleFolderReferences()
        saveLibrary()
    }

    /// Points meetings at the first folder when their folder vanished (e.g.
    /// deleted on another device). An unfiled meeting is a legitimate state
    /// and keeps no folder.
    private func reassignStaleFolderReferences() {
        guard !folders.isEmpty else {
            return
        }
        let validFolderIDs = Set(folders.map(\.id))
        let fallbackID = folders[0].id

        for index in meetings.indices {
            if let folderID = meetings[index].folderID,
               !validFolderIDs.contains(folderID) {
                meetings[index].folderID = fallbackID
                meetings[index].touch()
            }
        }
    }

    private func touchFolder(_ id: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else {
            return
        }
        folders[index].updatedAt = Date()
    }

    private func saveLibrary() {
        do {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
            let library = MeetingLibrarySnapshot(
                folders: folders,
                meetings: meetings
            )
            let data = try JSONEncoder().encode(library)
            try data.write(to: indexURL, options: .atomic)
            if !isApplyingRemote {
                libraryDidChange?()
            }
        } catch {
            lastError = InterfaceLanguage.current.format(
                "error.saveLibrary",
                error.localizedDescription
            )
        }
    }

    // MARK: - Helpers

    private static func formattedTitleDate(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .year()
                .month(.twoDigits)
                .day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
                .locale(InterfaceLanguage.current.locale)
        )
    }
}

private struct MeetingLibrarySnapshot: Codable {
    var folders: [MeetingFolder]
    var meetings: [MeetingRecord]
}

enum MeetingProcessingError: LocalizedError {
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return InterfaceLanguage.current.text("error.emptyTranscript")
        }
    }
}
