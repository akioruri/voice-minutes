import Foundation

/// Last-writer-wins merge rules shared by the iCloud sync pipeline and its
/// tests. Pure functions: no CloudKit, no store access.
enum LibraryMerge {
    /// Merges remote meetings into the local library by `updatedAt`. Records
    /// only present on one side are kept; conflicts pick the newer copy and
    /// ties go to the remote side so converging devices agree.
    static func mergeMeetings(
        local: [MeetingRecord],
        remote: [MeetingRecord]
    ) -> [MeetingRecord] {
        var byID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for record in remote {
            if let existing = byID[record.id] {
                byID[record.id] = preferredMeeting(existing, record)
            } else {
                byID[record.id] = record
            }
        }
        return Array(byID.values)
    }

    /// Same rule as `mergeMeetings`, for folders.
    static func mergeFolders(
        local: [MeetingFolder],
        remote: [MeetingFolder]
    ) -> [MeetingFolder] {
        var byID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for record in remote {
            if let existing = byID[record.id] {
                byID[record.id] = preferredFolder(existing, record)
            } else {
                byID[record.id] = record
            }
        }
        return Array(byID.values)
    }

    static func preferredMeeting(
        _ local: MeetingRecord,
        _ remote: MeetingRecord
    ) -> MeetingRecord {
        remote.updatedAt >= local.updatedAt ? remote : local
    }

    static func preferredFolder(
        _ local: MeetingFolder,
        _ remote: MeetingFolder
    ) -> MeetingFolder {
        remote.updatedAt >= local.updatedAt ? remote : local
    }
}
