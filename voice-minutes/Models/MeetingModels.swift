import Foundation

// MARK: - Meeting state

enum MeetingStatus: String, Codable, Sendable {
    case pending
    case processing
    case completed
    case failed

    var title: String {
        let language = InterfaceLanguage.current

        switch self {
        case .pending:
            return language.text("status.pending")
        case .processing:
            return language.text("status.processing")
        case .completed:
            return language.text("status.completed")
        case .failed:
            return language.text("status.failed")
        }
    }
}

// MARK: - Library models

struct MeetingFolder: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date
    var updatedAt: Date
    /// Optional minutes-prompt override from the prompt library; nil means
    /// the global default applies.
    var promptID: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        promptID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.promptID = promptID
    }

    /// Folders written before prompt overrides existed decode with nil.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
            ?? createdAt
        promptID = try container.decodeIfPresent(UUID.self, forKey: .promptID)
    }
}

/// Identifies the collection currently shown in the meeting list.
enum LibrarySelection: Hashable, Sendable {
    case all
    case recentlyDeleted
    case folder(UUID)
}

/// A time mark dropped while recording. Independent from key-note blocks:
/// it shows in the transcript overlay and can be converted into a block,
/// which then inherits the mark's time as its optional anchor.
struct MeetingMark: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var time: TimeInterval
    var label: String
    /// LLM summary of the transcript around this time point.
    var analysis: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        time: TimeInterval,
        label: String = "",
        analysis: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.time = time
        self.label = label
        self.analysis = analysis
        self.createdAt = createdAt
    }

    /// Marks written before analysis existed decode with an empty summary.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        time = try container.decode(TimeInterval.self, forKey: .time)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        analysis = try container.decodeIfPresent(String.self, forKey: .analysis) ?? ""
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

/// One independent key-note block. Blocks created directly carry no anchor;
/// blocks converted from a mark inherit its time. `analysis` holds the LLM
/// explanation of the block against the transcript.
struct KeyNoteBlock: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var text: String
    var analysis: String
    var anchorTime: TimeInterval?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        text: String = "",
        analysis: String = "",
        anchorTime: TimeInterval? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.analysis = analysis
        self.anchorTime = anchorTime
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The block a mark converts into: time becomes the anchor, label the text.
    init(converting mark: MeetingMark) {
        self.init(text: mark.label, anchorTime: mark.time)
    }

    mutating func touch() {
        updatedAt = Date()
    }
}

struct MeetingRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var folderID: UUID?
    var title: String
    let createdAt: Date
    /// Last local mutation time. The iCloud sync layer merges records by it
    /// (last writer wins), so every mutation must call `touch()`.
    var updatedAt: Date
    var duration: TimeInterval
    var audioFileName: String
    var status: MeetingStatus
    var transcriptSRT: String
    var minutesMarkdown: String
    /// Derived compatibility field: the ordered block texts joined. Kept in
    /// sync by the store so older sync clients still see the key notes; the
    /// blocks are the editing source of truth.
    var notesMarkdown: String
    /// Time marks dropped while recording, not yet converted into blocks.
    var marks: [MeetingMark]
    /// Independent key-note blocks; anchors are optional.
    var keyNoteBlocks: [KeyNoteBlock]
    var errorMessage: String?
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        folderID: UUID? = nil,
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        duration: TimeInterval = 0,
        audioFileName: String,
        status: MeetingStatus = .pending,
        transcriptSRT: String = "",
        minutesMarkdown: String = "",
        notesMarkdown: String = "",
        marks: [MeetingMark] = [],
        keyNoteBlocks: [KeyNoteBlock] = [],
        errorMessage: String? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.folderID = folderID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.duration = duration
        self.audioFileName = audioFileName
        self.status = status
        self.transcriptSRT = transcriptSRT
        self.minutesMarkdown = minutesMarkdown
        self.notesMarkdown = notesMarkdown
        self.marks = marks
        self.keyNoteBlocks = keyNoteBlocks
        self.errorMessage = errorMessage
        self.deletedAt = deletedAt
    }

    /// Custom decoding keeps libraries written before key notes existed
    /// loadable: the synthesized decoder would throw on the missing key and
    /// wipe the whole library.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        folderID = try container.decodeIfPresent(UUID.self, forKey: .folderID)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
            ?? createdAt
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        audioFileName = try container.decode(String.self, forKey: .audioFileName)
        status = try container.decode(MeetingStatus.self, forKey: .status)
        transcriptSRT = try container.decode(String.self, forKey: .transcriptSRT)
        minutesMarkdown = try container.decode(String.self, forKey: .minutesMarkdown)
        notesMarkdown = try container.decodeIfPresent(
            String.self,
            forKey: .notesMarkdown
        ) ?? ""
        marks = try container.decodeIfPresent([MeetingMark].self, forKey: .marks) ?? []
        if let blocks = try container.decodeIfPresent(
            [KeyNoteBlock].self,
            forKey: .keyNoteBlocks
        ) {
            keyNoteBlocks = blocks
            notesMarkdown = Self.derivedNotes(from: blocks)
        } else {
            // Libraries written before blocks existed: keep the legacy text
            // as a single unanchored block so nothing is lost.
            keyNoteBlocks = notesMarkdown
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? []
                : [KeyNoteBlock(text: notesMarkdown)]
        }
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
    }

    var isDeleted: Bool {
        deletedAt != nil
    }

    /// Marks the record as changed so the sync layer picks it up.
    mutating func touch() {
        updatedAt = Date()
    }

    /// The compatibility notes text derived from blocks: non-empty block
    /// texts in order, separated by blank lines.
    static func derivedNotes(from blocks: [KeyNoteBlock]) -> String {
        blocks.map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }
}

struct TranscriptSegment: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let speakerID: String?

    nonisolated init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        speakerID: String? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.speakerID = speakerID
    }
}

// MARK: - Transcription models

struct AudioChunk: Codable, Sendable {
    let index: Int
    let fileURL: URL
    let originalStart: TimeInterval
    let duration: TimeInterval

    var originalEnd: TimeInterval {
        originalStart + duration
    }
}
