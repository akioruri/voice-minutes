import CloudKit
import Foundation

/// Maps library models to CloudKit records and back. Pure functions so the
/// mapping can be unit tested without a CloudKit container.
///
/// Record layout in the private database:
/// - `Meeting`      recordName = meeting UUID, all metadata as fields.
/// - `Folder`       recordName = folder UUID.
/// - `MeetingAudio` recordName = "audio-<UUID>", the recording as a CKAsset.
///   Audio lives in its own record so fetching meetings never downloads
///   recordings; audio is fetched on demand when the user presses play.
enum LibrarySyncMapping {
    static let meetingRecordType = "Meeting"
    static let folderRecordType = "Folder"
    static let audioRecordType = "MeetingAudio"
    static let audioRecordPrefix = "audio-"
    static let schemaVersion: Int64 = 3

    // MARK: - Record identifiers

    /// CKSyncEngine discovers and fetches changes only in custom zones;
    /// `_defaultZone` has no change tracking, so records saved there upload
    /// but are never fetched back (even after a reinstall).
    static let recordZoneID = CKRecordZone.ID(zoneName: "VoiceMinutesLibrary")

    static func meetingRecordID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: recordZoneID)
    }

    static func folderRecordID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: recordZoneID)
    }

    static func audioRecordID(_ meetingID: UUID) -> CKRecord.ID {
        CKRecord.ID(
            recordName: audioRecordPrefix + meetingID.uuidString,
            zoneID: recordZoneID
        )
    }

    /// The meeting UUID a record belongs to, for any of the three types.
    static func meetingID(from recordID: CKRecord.ID) -> UUID? {
        let name = recordID.recordName
        if name.hasPrefix(audioRecordPrefix) {
            return UUID(uuidString: String(name.dropFirst(audioRecordPrefix.count)))
        }
        return UUID(uuidString: name)
    }

    // MARK: - Meetings

    /// `.processing` is a device-local transient state: it is never uploaded
    /// and never accepted from the server.
    static func isUploadable(_ status: MeetingStatus) -> Bool {
        status != .processing
    }

    static func record(for meeting: MeetingRecord) -> CKRecord {
        let record = CKRecord(
            recordType: meetingRecordType,
            recordID: meetingRecordID(meeting.id)
        )
        record["schemaVersion"] = schemaVersion
        record["title"] = meeting.title
        record["createdAt"] = meeting.createdAt
        record["updatedAt"] = meeting.updatedAt
        record["duration"] = meeting.duration
        record["audioFileName"] = meeting.audioFileName
        record["status"] = meeting.status.rawValue
        record["transcriptSRT"] = meeting.transcriptSRT
        record["minutesMarkdown"] = meeting.minutesMarkdown
        record["notesMarkdown"] = meeting.notesMarkdown
        if let marksJSON = jsonString(meeting.marks) {
            record["meetingMarks"] = marksJSON
        }
        if let blocksJSON = jsonString(meeting.keyNoteBlocks) {
            record["keyNoteBlocks"] = blocksJSON
        }
        if let folderID = meeting.folderID {
            record["folderID"] = folderID.uuidString
        }
        if let errorMessage = meeting.errorMessage {
            record["errorMessage"] = errorMessage
        }
        if let deletedAt = meeting.deletedAt {
            record["deletedAt"] = deletedAt
        }
        return record
    }

    static func meeting(from record: CKRecord) -> MeetingRecord? {
        guard record.recordType == meetingRecordType,
              let id = UUID(uuidString: record.recordID.recordName),
              let title = record["title"] as? String,
              let createdAt = record["createdAt"] as? Date,
              let audioFileName = record["audioFileName"] as? String,
              let statusRaw = record["status"] as? String else {
            return nil
        }

        var status = MeetingStatus(rawValue: statusRaw) ?? .failed
        if status == .processing {
            status = .pending
        }

        let folderID = (record["folderID"] as? String).flatMap(UUID.init(uuidString:))

        let marks: [MeetingMark] = (record["meetingMarks"] as? String).flatMap {
            try? JSONDecoder().decode([MeetingMark].self, from: Data($0.utf8))
        } ?? []

        let legacyNotes = record["notesMarkdown"] as? String ?? ""
        let blocks: [KeyNoteBlock]
        let notes: String
        if let blocksJSON = record["keyNoteBlocks"] as? String,
           let decoded = try? JSONDecoder().decode(
               [KeyNoteBlock].self,
               from: Data(blocksJSON.utf8)
           ) {
            blocks = decoded
            notes = MeetingRecord.derivedNotes(from: decoded)
        } else {
            // Records written before blocks existed: migrate the legacy
            // notes text into a single unanchored block.
            blocks = legacyNotes
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? []
                : [KeyNoteBlock(text: legacyNotes)]
            notes = legacyNotes
        }

        return MeetingRecord(
            id: id,
            folderID: folderID,
            title: title,
            createdAt: createdAt,
            updatedAt: record["updatedAt"] as? Date ?? createdAt,
            duration: record["duration"] as? Double ?? 0,
            audioFileName: audioFileName,
            status: status,
            transcriptSRT: record["transcriptSRT"] as? String ?? "",
            minutesMarkdown: record["minutesMarkdown"] as? String ?? "",
            notesMarkdown: notes,
            marks: marks,
            keyNoteBlocks: blocks,
            errorMessage: record["errorMessage"] as? String,
            deletedAt: record["deletedAt"] as? Date
        )
    }

    // MARK: - Folders

    static func record(for folder: MeetingFolder) -> CKRecord {
        let record = CKRecord(
            recordType: folderRecordType,
            recordID: folderRecordID(folder.id)
        )
        record["schemaVersion"] = schemaVersion
        record["name"] = folder.name
        record["createdAt"] = folder.createdAt
        record["updatedAt"] = folder.updatedAt
        if let promptID = folder.promptID {
            record["promptID"] = promptID.uuidString
        }
        return record
    }

    static func folder(from record: CKRecord) -> MeetingFolder? {
        guard record.recordType == folderRecordType,
              let id = UUID(uuidString: record.recordID.recordName),
              let name = record["name"] as? String,
              let createdAt = record["createdAt"] as? Date else {
            return nil
        }

        return MeetingFolder(
            id: id,
            name: name,
            createdAt: createdAt,
            updatedAt: record["updatedAt"] as? Date ?? createdAt,
            promptID: (record["promptID"] as? String).flatMap(UUID.init(uuidString:))
        )
    }

    // MARK: - Audio

    private static func jsonString<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func audioRecord(for meeting: MeetingRecord, fileURL: URL) -> CKRecord {
        let record = CKRecord(
            recordType: audioRecordType,
            recordID: audioRecordID(meeting.id)
        )
        record["schemaVersion"] = schemaVersion
        record["meetingID"] = meeting.id.uuidString
        record["audio"] = CKAsset(fileURL: fileURL)
        return record
    }
}
