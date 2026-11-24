import CloudKit
import Foundation
import Observation
import os
import Security

/// Drives iCloud sync of the meeting library through CKSyncEngine.
///
/// The local file library stays the source of truth while the app runs; this
/// controller mirrors it into the CloudKit private database and applies remote
/// changes back into the store. Recordings live in separate `MeetingAudio`
/// records and are only downloaded on demand (play / retry), so signing in on
/// a new device never pulls the whole audio library.
@Observable
@MainActor
final class CloudSyncController: CKSyncEngineDelegate {
    enum Status: Equatable {
        case disabled
        case unavailable
        case noAccount
        case idle
        case syncing
        case error(String)
    }

    private(set) var status: Status = .disabled
    /// Technical reason behind the current status, surfaced in Settings to
    /// diagnose device-only failures (entitlement probe, account status,
    /// CKError codes). Developer-facing detail, so it stays in English.
    private(set) var statusDetail: String?
    private(set) var lastSyncDate: Date?
    private(set) var downloadingMeetingIDs: Set<UUID> = []

    private let store: MeetingStore
    private let settings: AppSettings
    /// Nil while the iCloud entitlement is absent (e.g. before the developer
    /// account approval). `CKContainer(identifier:)` traps without it, so it
    /// must never be constructed unconditionally.
    private let container: CKContainer?
    private var engine: CKSyncEngine?
    private var isRefreshing = false

    // Last-synced versions, used to compute dirty records. Meetings and
    // folders track `updatedAt`; audio tracks the file's modification date so
    // editing notes never re-uploads the recording.
    private var syncedMeetingVersions: [UUID: Date] = [:]
    private var syncedFolderVersions: [UUID: Date] = [:]
    private var syncedAudioVersions: [UUID: Date] = [:]
    private var knownMeetingIDs: Set<UUID> = []
    private var knownFolderIDs: Set<UUID> = []
    /// Server records cached from fetches / conflict errors. Reusing one as
    /// the base for a save preserves its record change tag, so the engine
    /// sends an update instead of a conflicting insert.
    private var serverRecords: [CKRecord.ID: CKRecord] = [:]

    private static let log = Logger(
        subsystem: "com.akioruri.voiceminutes",
        category: "sync"
    )

    init(store: MeetingStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        let probe = Self.probeEntitlements()
        self.entitlementTrace = probe.trace
        if probe.containers.contains(Self.containerIdentifier) {
            self.container = CKContainer(identifier: Self.containerIdentifier)
        } else {
            self.container = nil
        }
        Self.log.info(
            "entitlement probe: \(probe.trace, privacy: .public), containers: \(probe.containers, privacy: .public)"
        )
        store.libraryDidChange = { [weak self] in
            self?.noteLocalChanges()
        }
    }

    private static let containerIdentifier = "iCloud.com.akioruri.voiceminutes"

    /// Human-readable outcome of the entitlement probe, kept for diagnostics.
    private let entitlementTrace: String

    /// Gates container construction on a real entitlement check, keeping the
    /// app fully functional (sync reported unavailable) without iCloud.
    /// `CKContainer(identifier:)` traps without the entitlement, so it must
    /// never be constructed unconditionally. The trace explains exactly which
    /// step failed when a device build reports sync unavailable.
    private static func probeEntitlements() -> (containers: [String], trace: String) {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let identifiers = SecTaskCopyValueForEntitlement(
                  task,
                  "com.apple.developer.icloud-container-identifiers" as CFString,
                  nil
              ) as? [String] else {
            return ([], "SecTask entitlement read failed")
        }
        return (identifiers, "SecTask ok")
        #elseif targetEnvironment(simulator)
        // Simulator builds carry no provisioning profile; the iCloud
        // entitlement comes from the signing entitlements file, so trust
        // the configured container.
        return ([containerIdentifier], "simulator")
        #else
        // iOS / visionOS device: App Store / TestFlight re-signing strips
        // embedded.mobileprovision, so the authoritative entitlement source
        // is the executable's own code signature. Development builds also
        // carry a provisioning profile; keep it as a fallback.
        if let entitlements = codeSignatureEntitlements(),
           let identifiers = entitlements[
               "com.apple.developer.icloud-container-identifiers"
           ] as? [String] {
            return (identifiers, "code signature ok")
        }
        guard let url = Bundle.main.url(
                  forResource: "embedded",
                  withExtension: "mobileprovision"
              ) else {
            return ([], "no entitlements in code signature; profile missing")
        }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>") else {
            return ([], "profile plist payload not found")
        }
        let plistText = String(text[start.lowerBound..<end.upperBound])
        guard let plistData = plistText.data(using: .isoLatin1),
              let plist = try? PropertyListSerialization.propertyList(
                  from: plistData,
                  format: nil
              ) as? [String: Any] else {
            return ([], "profile plist parse failed")
        }
        guard let entitlements = plist["Entitlements"] as? [String: Any],
              let identifiers = entitlements[
                  "com.apple.developer.icloud-container-identifiers"
              ] as? [String] else {
            return ([], "profile lacks icloud-container-identifiers")
        }
        return (identifiers, "profile ok")
        #endif
    }

    #if !os(macOS) && !targetEnvironment(simulator)
    /// Reads the entitlements embedded in the executable's code signature
    /// (LC_CODE_SIGNATURE → entitlements blob). Unlike the provisioning
    /// profile, this survives App Store / TestFlight re-signing.
    private static func codeSignatureEntitlements() -> [String: Any]? {
        guard let url = Bundle.main.executableURL,
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return data.withUnsafeBytes { raw -> [String: Any]? in
            func le32(_ offset: Int) -> UInt32 {
                UInt32(
                    littleEndian: raw.loadUnaligned(
                        fromByteOffset: offset, as: UInt32.self
                    )
                )
            }
            func be32(_ offset: Int) -> UInt32 {
                UInt32(
                    bigEndian: raw.loadUnaligned(
                        fromByteOffset: offset, as: UInt32.self
                    )
                )
            }
            guard raw.count > 32 else {
                return nil
            }
            var imageStart = 0
            let magic = le32(0)
            if magic == 0xFEEDFACF { // MH_MAGIC_64
                imageStart = 0
            } else if magic == 0xBEBAFECA || magic == 0xCAFEBABE {
                // Fat binary: locate the arm64 slice.
                let count = Int(be32(4))
                var found = false
                for i in 0..<count {
                    let entry = 8 + i * 20
                    guard entry + 20 <= raw.count else {
                        break
                    }
                    if be32(entry) == 0x0100000C { // CPU_TYPE_ARM64
                        imageStart = Int(be32(entry + 8))
                        found = true
                        break
                    }
                }
                guard found, imageStart + 32 <= raw.count,
                      le32(imageStart) == 0xFEEDFACF else {
                    return nil
                }
            } else {
                return nil
            }
            // mach_header_64 is 32 bytes; walk the load commands.
            let ncmds = Int(le32(imageStart + 16))
            var cursor = imageStart + 32
            var signatureOffset: Int?
            for _ in 0..<ncmds {
                guard cursor + 8 <= raw.count else {
                    return nil
                }
                let cmd = le32(cursor)
                let cmdsize = Int(le32(cursor + 4))
                guard cmdsize >= 8 else {
                    return nil
                }
                if cmd == 0x1D { // LC_CODE_SIGNATURE
                    signatureOffset = imageStart + Int(le32(cursor + 8))
                    break
                }
                cursor += cmdsize
            }
            guard let sig = signatureOffset, sig + 12 <= raw.count,
                  be32(sig) == 0xFADE0CC0 else { // CSMAGIC_EMBEDDED_SIGNATURE
                return nil
            }
            let blobCount = Int(be32(sig + 8))
            var xmlBlob: Data?
            var derBlob: Data?
            for i in 0..<blobCount {
                let index = sig + 12 + i * 8
                guard index + 8 <= raw.count else {
                    break
                }
                let type = be32(index)
                let blob = sig + Int(be32(index + 4))
                guard blob + 8 <= raw.count else {
                    continue
                }
                let blobMagic = be32(blob)
                let blobLength = Int(be32(blob + 4))
                guard blobLength >= 8, blob + blobLength <= raw.count else {
                    continue
                }
                let payload = data.subdata(in: (blob + 8)..<(blob + blobLength))
                if type == 5, blobMagic == 0xFADE7171 {
                    xmlBlob = payload // CSSLOT_ENTITLEMENTS (XML plist)
                } else if type == 7, blobMagic == 0xFADE7172 {
                    derBlob = payload // CSSLOT_DER_ENTITLEMENTS
                }
            }
            if let xmlBlob,
               let plist = try? PropertyListSerialization.propertyList(
                   from: xmlBlob,
                   format: nil
               ) as? [String: Any] {
                return plist
            }
            if let derBlob {
                return parseDEREntitlements(derBlob)
            }
            return nil
        }
    }

    /// Minimal DER walker for the signature's DER entitlements blob. The
    /// blob is either a plain SET of SEQUENCE { key, value } pairs, or a
    /// wrapper containing a version INTEGER plus a constructed context tag
    /// holding those pairs.
    private static func parseDEREntitlements(_ data: Data) -> [String: Any]? {
        var index = 0
        guard let top = derValue(data, &index) as? [Any] else {
            return nil
        }
        var result: [String: Any] = [:]
        func addPairs(_ nodes: [Any]) -> Bool {
            var added = false
            for pair in nodes {
                guard let fields = pair as? [Any], fields.count == 2,
                      let key = fields[0] as? String else {
                    continue
                }
                result[key] = fields[1]
                added = true
            }
            return added
        }
        if !addPairs(top) {
            for node in top {
                if let children = node as? [Any] {
                    _ = addPairs(children)
                }
            }
        }
        return result.isEmpty ? nil : result
    }

    private static func derValue(_ data: Data, _ index: inout Int) -> Any? {
        guard index + 2 <= data.count else {
            return nil
        }
        let tag = data[index]
        index += 1
        var length = Int(data[index])
        index += 1
        if length & 0x80 != 0 {
            let byteCount = length & 0x7F
            guard byteCount <= 4, index + byteCount <= data.count else {
                return nil
            }
            length = 0
            for _ in 0..<byteCount {
                length = (length << 8) | Int(data[index])
                index += 1
            }
        }
        guard index + length <= data.count else {
            return nil
        }
        let content = data.subdata(in: index..<(index + length))
        index += length
        switch tag {
        case 0x0C, 0x13, 0x16: // UTF8String / PrintableString / IA5String
            return String(data: content, encoding: .utf8)
        case 0x01: // BOOLEAN
            return (content.first ?? 0) != 0
        case 0x02: // INTEGER
            var value = 0
            for byte in content {
                value = (value << 8) | Int(byte)
            }
            return value
        case 0x05: // NULL
            return NSNull()
        default:
            // Any constructed tag (SEQUENCE / SET / context wrappers) is
            // walked as a list of children.
            guard tag & 0x20 != 0 else {
                return nil
            }
            var children: [Any] = []
            var sub = 0
            while sub < content.count {
                guard let child = derValue(content, &sub) else {
                    return nil
                }
                children.append(child)
            }
            return children
        }
    }
    #endif

    private static func describe(_ account: CKAccountStatus) -> String {
        switch account {
        case .available: return "available"
        case .noAccount: return "noAccount"
        case .restricted: return "restricted"
        case .couldNotDetermine: return "couldNotDetermine"
        case .temporarilyUnavailable: return "temporarilyUnavailable"
        @unknown default: return "unknown(\(account.rawValue))"
        }
    }

    // MARK: - Lifecycle

    /// Starts sync when enabled, or nudges an already-running engine. Safe to
    /// call on launch, on foreground, and whenever the toggle changes.
    func refresh() async {
        guard settings.syncEnabled else {
            stop()
            return
        }

        if let engine {
            status = .syncing
            noteLocalChanges(sendImmediately: false)
            try? await engine.fetchChanges()
            try? await engine.sendChanges()
            return
        }

        guard let container else {
            statusDetail = "entitlement: \(entitlementTrace)"
            status = .unavailable
            Self.log.error(
                "sync unavailable — entitlement: \(self.entitlementTrace, privacy: .public)"
            )
            return
        }

        guard !isRefreshing else {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        // Right after install or an account switch the account can be
        // momentarily undeterminable; retry briefly before degrading.
        var account: CKAccountStatus = .couldNotDetermine
        for attempt in 1...3 {
            do {
                account = try await container.accountStatus()
            } catch {
                statusDetail = "accountStatus error: \(error.localizedDescription)"
                status = .unavailable
                Self.log.error(
                    "accountStatus failed: \(error.localizedDescription, privacy: .public)"
                )
                return
            }
            if account == .available || account == .noAccount {
                break
            }
            if attempt < 3 {
                try? await Task.sleep(for: .seconds(2))
            }
        }
        switch account {
        case .available:
            break
        case .noAccount:
            statusDetail = nil
            status = .noAccount
            return
        default:
            statusDetail = "accountStatus: \(Self.describe(account))"
            status = .unavailable
            Self.log.error(
                "sync unavailable — accountStatus: \(Self.describe(account), privacy: .public)"
            )
            return
        }

        await migrateLegacyDefaultZoneRecords(in: container.privateCloudDatabase)

        let configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: loadStateSerialization(),
            delegate: self
        )
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        statusDetail = nil
        status = .syncing
        Self.log.info(
            "sync engine started for \(Self.containerIdentifier, privacy: .public)"
        )
        // Reconcile server state first so local saves carry the server's
        // record change tags (avoids "record already exists" conflicts).
        try? await engine.fetchChanges()
        Self.log.info("initial fetchChanges returned")
        noteLocalChanges(sendImmediately: false)
        try? await engine.sendChanges()
        Self.log.info("initial sendChanges returned")
    }

    func stop() {
        engine = nil
        statusDetail = nil
        status = .disabled
    }

    /// Called when the "sync recordings" preference flips. Turning it off
    /// removes remote audio (freeing iCloud quota); local files stay put.
    func audioSyncPreferenceChanged() {
        guard let engine, settings.syncEnabled else {
            return
        }

        if settings.syncAudioEnabled {
            syncedAudioVersions = [:]
            noteLocalChanges()
        } else {
            let deletions: [CKSyncEngine.PendingRecordZoneChange] = store.meetings.map {
                .deleteRecord(LibrarySyncMapping.audioRecordID($0.id))
            }
            syncedAudioVersions = [:]
            guard !deletions.isEmpty else {
                return
            }
            engine.state.add(pendingRecordZoneChanges: deletions)
            Task.detached { try? await engine.sendChanges() }
        }
    }

    // MARK: - On-demand audio

    /// Fetches a recording that exists in iCloud but not on this device and
    /// moves it into the meeting directory. CKAsset staging files are cleaned
    /// up by the system, so the move must happen immediately.
    func downloadAudio(for meeting: MeetingRecord) async throws {
        guard !downloadingMeetingIDs.contains(meeting.id) else {
            return
        }
        downloadingMeetingIDs.insert(meeting.id)
        defer { downloadingMeetingIDs.remove(meeting.id) }

        guard let container else {
            throw SyncError.syncUnavailable
        }

        let record: CKRecord
        do {
            record = try await container.privateCloudDatabase.record(
                for: LibrarySyncMapping.audioRecordID(meeting.id)
            )
        } catch let error as CKError where error.code == .unknownItem {
            throw SyncError.audioNotSynced
        }

        guard let asset = record["audio"] as? CKAsset,
              let stagedURL = asset.fileURL else {
            throw SyncError.audioNotSynced
        }

        let destination = store.audioURL(for: meeting)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: stagedURL, to: destination)
        syncedAudioVersions[meeting.id] = audioModificationDate(for: meeting)
    }

    // MARK: - Local change tracking

    /// Diffs the library against the last-synced snapshot and queues saves /
    /// deletes. Called after every persisted local mutation.
    private func noteLocalChanges(sendImmediately: Bool = true) {
        Self.log.info(
            "noteLocalChanges: enabled=\(self.settings.syncEnabled, privacy: .public) engine=\(self.engine != nil, privacy: .public) meetings=\(self.store.meetings.count, privacy: .public) folders=\(self.store.folders.count, privacy: .public) syncedVersions=\(self.syncedMeetingVersions.count, privacy: .public)"
        )
        guard let engine, settings.syncEnabled else {
            return
        }

        let meetings = store.meetings
        let folders = store.folders
        let currentMeetingIDs = Set(meetings.map(\.id))
        let currentFolderIDs = Set(folders.map(\.id))

        var pending: Set<CKSyncEngine.PendingRecordZoneChange> = []

        func enqueue(_ change: CKSyncEngine.PendingRecordZoneChange) {
            pending.insert(change)
        }

        for meeting in meetings {
            if LibrarySyncMapping.isUploadable(meeting.status),
               syncedMeetingVersions[meeting.id] != meeting.updatedAt {
                enqueue(.saveRecord(LibrarySyncMapping.meetingRecordID(meeting.id)))
            }
            if settings.syncAudioEnabled,
               let modificationDate = audioModificationDate(for: meeting),
               syncedAudioVersions[meeting.id] != modificationDate {
                enqueue(.saveRecord(LibrarySyncMapping.audioRecordID(meeting.id)))
            }
        }
        for id in knownMeetingIDs.subtracting(currentMeetingIDs) {
            enqueue(.deleteRecord(LibrarySyncMapping.meetingRecordID(id)))
            enqueue(.deleteRecord(LibrarySyncMapping.audioRecordID(id)))
        }
        for folder in folders where syncedFolderVersions[folder.id] != folder.updatedAt {
            enqueue(.saveRecord(LibrarySyncMapping.folderRecordID(folder.id)))
        }
        for id in knownFolderIDs.subtracting(currentFolderIDs) {
            enqueue(.deleteRecord(LibrarySyncMapping.folderRecordID(id)))
        }

        knownMeetingIDs = currentMeetingIDs
        knownFolderIDs = currentFolderIDs

        guard !pending.isEmpty else {
            return
        }
        Self.log.info(
            "queued \(pending.count, privacy: .public) local changes"
        )
        engine.state.add(pendingRecordZoneChanges: Array(pending))
        status = .syncing
        if sendImmediately {
            Task.detached { try? await engine.sendChanges() }
        }
    }

    private func audioModificationDate(for meeting: MeetingRecord) -> Date? {
        let url = store.audioURL(for: meeting)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }

    // MARK: - CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        Self.log.info(
            "engine event: \(String(describing: event).prefix(100), privacy: .public)"
        )
        switch event {
        case .stateUpdate(let update):
            saveStateSerialization(update.stateSerialization)

        case .accountChange(let change):
            handleAccountChange(change)

        case .fetchedRecordZoneChanges(let changes):
            applyFetched(changes)

        case .fetchedDatabaseChanges(let changes):
            // A purged or encrypted-data-reset zone must not be re-uploaded
            // automatically; surface it and let the user re-enable sync.
            if changes.deletions.contains(where: { $0.reason != .deleted }) {
                engine = nil
                clearSyncState()
                status = .error(InterfaceLanguage.current.text("sync.error.purged"))
            }

        case .sentRecordZoneChanges(let sent):
            handleSent(sent)

        case .willFetchChanges, .willSendChanges:
            status = .syncing

        case .didFetchChanges, .didSendChanges:
            Self.log.info("didFetch/didSend cycle finished")
            lastSyncDate = Date()
            if status == .syncing {
                status = .idle
            }

        case .didFetchRecordZoneChanges(let finished):
            if let error = finished.error {
                report(error)
            }

        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges
        guard !pending.isEmpty else {
            return nil
        }
        Self.log.info(
            "batch requested: \(pending.count, privacy: .public) pending"
        )

        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [CKRecord.ID] = []
        var seen: Set<CKRecord.ID> = []

        // Cap the batch so a large first upload cannot exceed CloudKit's
        // per-request limits; the engine asks again for the remainder.
        for change in pending.prefix(40) {
            switch change {
            case .saveRecord(let recordID):
                guard seen.insert(recordID).inserted else {
                    continue
                }
                if let record = recordToSend(for: recordID) {
                    recordsToSave.append(record)
                } else {
                    Self.log.error(
                        "no record built for pending save \(recordID.recordName, privacy: .public)"
                    )
                }
            case .deleteRecord(let recordID):
                guard seen.insert(recordID).inserted else {
                    continue
                }
                recordIDsToDelete.append(recordID)
            @unknown default:
                break
            }
        }

        guard !recordsToSave.isEmpty || !recordIDsToDelete.isEmpty else {
            Self.log.error("batch empty despite pending changes — dropping")
            return nil
        }
        Self.log.info(
            "batch: \(recordsToSave.count, privacy: .public) saves, \(recordIDsToDelete.count, privacy: .public) deletes"
        )
        return CKSyncEngine.RecordZoneChangeBatch(
            recordsToSave: recordsToSave,
            recordIDsToDelete: recordIDsToDelete,
            atomicByZone: false
        )
    }

    /// Builds the current record for a pending save, straight from the store.
    private func recordToSend(for recordID: CKRecord.ID) -> CKRecord? {
        guard let fresh = buildRecord(for: recordID) else {
            return nil
        }
        // If the server already holds this record, overlay local fields onto
        // a copy of it so the record change tag is preserved (update, not insert).
        if let server = serverRecords[recordID]?.copy() as? CKRecord {
            for key in fresh.allKeys() {
                server[key] = fresh[key]
            }
            return server
        }
        return fresh
    }

    private func buildRecord(for recordID: CKRecord.ID) -> CKRecord? {
        let name = recordID.recordName
        if name.hasPrefix(LibrarySyncMapping.audioRecordPrefix) {
            guard settings.syncAudioEnabled,
                  let id = LibrarySyncMapping.meetingID(from: recordID),
                  let meeting = store.meetings.first(where: { $0.id == id }) else {
                return nil
            }
            let url = store.audioURL(for: meeting)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return nil
            }
            return LibrarySyncMapping.audioRecord(for: meeting, fileURL: url)
        }

        guard let id = UUID(uuidString: name) else {
            return nil
        }
        if let meeting = store.meetings.first(where: { $0.id == id }) {
            guard LibrarySyncMapping.isUploadable(meeting.status) else {
                return nil
            }
            return LibrarySyncMapping.record(for: meeting)
        }
        if let folder = store.folders.first(where: { $0.id == id }) {
            return LibrarySyncMapping.record(for: folder)
        }
        return nil
    }

    // MARK: - Remote changes

    private func applyFetched(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        Self.log.info(
            "fetched: \(changes.modifications.count, privacy: .public) modifications, \(changes.deletions.count, privacy: .public) deletions"
        )
        var remoteMeetings: [MeetingRecord] = []
        var remoteFolders: [MeetingFolder] = []
        var deletedMeetingIDs: Set<UUID> = []
        var deletedFolderIDs: Set<UUID> = []

        for modification in changes.modifications {
            let record = modification.record
            serverRecords[record.recordID] = record
            switch record.recordType {
            case LibrarySyncMapping.meetingRecordType:
                if let meeting = LibrarySyncMapping.meeting(from: record) {
                    remoteMeetings.append(meeting)
                }
            case LibrarySyncMapping.folderRecordType:
                if let folder = LibrarySyncMapping.folder(from: record) {
                    remoteFolders.append(folder)
                }
            default:
                // MeetingAudio modifications are ignored: audio is fetched
                // on demand only.
                break
            }
        }
        for deletion in changes.deletions {
            switch deletion.recordType {
            case LibrarySyncMapping.meetingRecordType:
                if let id = UUID(uuidString: deletion.recordID.recordName) {
                    deletedMeetingIDs.insert(id)
                }
            case LibrarySyncMapping.folderRecordType:
                if let id = UUID(uuidString: deletion.recordID.recordName) {
                    deletedFolderIDs.insert(id)
                }
            default:
                break
            }
        }

        guard !remoteMeetings.isEmpty || !remoteFolders.isEmpty
                || !deletedMeetingIDs.isEmpty || !deletedFolderIDs.isEmpty else {
            return
        }

        store.applyRemoteSync(
            meetings: remoteMeetings,
            folders: remoteFolders,
            deletedMeetingIDs: deletedMeetingIDs,
            deletedFolderIDs: deletedFolderIDs
        )
        refreshSnapshotsFromStore()
    }

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges) {
        Self.log.info(
            "sent: \(sent.savedRecords.count, privacy: .public) saved, \(sent.deletedRecordIDs.count, privacy: .public) deleted, \(sent.failedRecordSaves.count, privacy: .public) failed saves, \(sent.failedRecordDeletes.count, privacy: .public) failed deletes"
        )
        for failure in sent.failedRecordSaves {
            Self.log.error(
                "save failed \(failure.record.recordID.recordName, privacy: .public): \(failure.error.localizedDescription, privacy: .public)"
            )
        }
        for record in sent.savedRecords {
            serverRecords[record.recordID] = record
            switch record.recordType {
            case LibrarySyncMapping.meetingRecordType:
                if let meeting = LibrarySyncMapping.meeting(from: record) {
                    syncedMeetingVersions[meeting.id] = meeting.updatedAt
                }
            case LibrarySyncMapping.folderRecordType:
                if let folder = LibrarySyncMapping.folder(from: record) {
                    syncedFolderVersions[folder.id] = folder.updatedAt
                }
            case LibrarySyncMapping.audioRecordType:
                if let id = LibrarySyncMapping.meetingID(from: record.recordID),
                   let meeting = store.meetings.first(where: { $0.id == id }) {
                    syncedAudioVersions[id] = audioModificationDate(for: meeting)
                }
            default:
                break
            }
        }
        for recordID in sent.deletedRecordIDs {
            if let id = LibrarySyncMapping.meetingID(from: recordID) {
                syncedMeetingVersions.removeValue(forKey: id)
                syncedAudioVersions.removeValue(forKey: id)
                syncedFolderVersions.removeValue(forKey: id)
            }
        }

        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        for failure in sent.failedRecordSaves {
            if failure.error.code == .serverRecordChanged,
               let server = failure.error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
                serverRecords[failure.record.recordID] = server
            }
            if failure.error.code == .quotaExceeded {
                status = .error(InterfaceLanguage.current.text("sync.error.quota"))
                // Audio is the bulky part: drop it until the user frees space
                // or flips the recording toggle. Metadata keeps retrying.
                if failure.record.recordType == LibrarySyncMapping.audioRecordType {
                    continue
                }
            } else if !isRetryable(failure.error) {
                report(failure.error)
                continue
            }
            retry.append(.saveRecord(failure.record.recordID))
        }
        for (recordID, error) in sent.failedRecordDeletes {
            if error.code == .unknownItem {
                continue
            }
            if isRetryable(error) {
                retry.append(.deleteRecord(recordID))
            }
        }
        if !retry.isEmpty {
            engine?.state.add(pendingRecordZoneChanges: retry)
        }
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signOut, .switchAccounts:
            // The engine resets its own state; drop ours so a different
            // account never inherits the previous user's sync bookkeeping.
            engine = nil
            clearSyncState()
            statusDetail = nil
            status = settings.syncEnabled ? .noAccount : .disabled
            Task.detached { [weak self] in await self?.refresh() }
        default:
            syncedMeetingVersions = [:]
            syncedFolderVersions = [:]
            syncedAudioVersions = [:]
            knownMeetingIDs = []
            knownFolderIDs = []
            noteLocalChanges()
        }
    }

    private func refreshSnapshotsFromStore() {
        for meeting in store.meetings {
            syncedMeetingVersions[meeting.id] = meeting.updatedAt
        }
        for folder in store.folders {
            syncedFolderVersions[folder.id] = folder.updatedAt
        }
        knownMeetingIDs = Set(store.meetings.map(\.id))
        knownFolderIDs = Set(store.folders.map(\.id))
    }

    // MARK: - Errors

    private func isRetryable(_ error: CKError) -> Bool {
        switch error.code {
        case .networkUnavailable, .requestRateLimited, .zoneNotFound,
             .serviceUnavailable, .internalError, .serverRecordChanged:
            return true
        default:
            return false
        }
    }

    private func report(_ error: CKError) {
        statusDetail = "CKError \(error.code.rawValue): \(error.localizedDescription)"
        Self.log.error(
            "sync CKError \(error.code.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        switch error.code {
        case .notAuthenticated, .permissionFailure, .badContainer:
            status = .unavailable
        case .quotaExceeded:
            status = .error(InterfaceLanguage.current.text("sync.error.quota"))
        case .networkUnavailable:
            status = .error(InterfaceLanguage.current.text("sync.error.network"))
        default:
            status = .error(error.localizedDescription)
        }
    }

    // MARK: - Legacy zone migration

    /// Builds before the custom-zone fix stored records in `_defaultZone`,
    /// which CKSyncEngine never fetches. Copy this device's legacy records
    /// into the library zone once, then delete the originals. Records are
    /// addressed by their known local identifiers because Production
    /// schemas do not guarantee queryable indexes for a full scan; every
    /// device migrates the records it created.
    private func migrateLegacyDefaultZoneRecords(in database: CKDatabase) async {
        let flagURL = store.syncStateURL.deletingLastPathComponent()
            .appendingPathComponent("sync-zone-migration-v1.done")
        guard !FileManager.default.fileExists(atPath: flagURL.path) else {
            return
        }
        Self.log.info("migrating legacy _defaultZone records")
        do {
            _ = try await database.save(
                CKRecordZone(zoneID: LibrarySyncMapping.recordZoneID)
            )
        } catch {
            // The zone usually already exists; a real failure resurfaces
            // when the copies below cannot be saved.
        }
        var legacyIDs: [CKRecord.ID] = []
        for meeting in store.meetings {
            legacyIDs.append(CKRecord.ID(recordName: meeting.id.uuidString))
            legacyIDs.append(
                CKRecord.ID(
                    recordName: LibrarySyncMapping.audioRecordPrefix
                        + meeting.id.uuidString
                )
            )
        }
        for folder in store.folders {
            legacyIDs.append(CKRecord.ID(recordName: folder.id.uuidString))
        }
        var moved = 0
        var failed = false
        for legacyID in legacyIDs {
            let record: CKRecord
            do {
                record = try await database.record(for: legacyID)
            } catch let error as CKError where error.code == .unknownItem {
                continue // never uploaded from this device
            } catch {
                failed = true
                Self.log.error(
                    "migration fetch failed \(legacyID.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                continue
            }
            let copy = CKRecord(
                recordType: record.recordType,
                recordID: CKRecord.ID(
                    recordName: legacyID.recordName,
                    zoneID: LibrarySyncMapping.recordZoneID
                )
            )
            for key in record.allKeys() {
                // A CKAsset object belongs to its fetched record; reusing it
                // on another record traps, so rebuild it from the staged file.
                if let asset = record[key] as? CKAsset,
                   let fileURL = asset.fileURL {
                    copy[key] = CKAsset(fileURL: fileURL)
                } else {
                    copy[key] = record[key]
                }
            }
            do {
                _ = try await database.save(copy)
            } catch let error as CKError
                where error.code == .serverRecordChanged {
                // Already copied by an earlier run or the engine itself.
            } catch {
                failed = true
                Self.log.error(
                    "migration copy failed \(legacyID.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                continue
            }
            do {
                _ = try await database.deleteRecord(withID: legacyID)
                moved += 1
            } catch let error as CKError where error.code == .unknownItem {
                moved += 1 // already removed
            } catch {
                failed = true
            }
        }
        if !failed {
            try? Data().write(to: flagURL)
            Self.log.info(
                "migration complete: \(moved, privacy: .public) records moved"
            )
        }
    }

    // MARK: - Engine state persistence

    private func saveStateSerialization(_ serialization: CKSyncEngine.State.Serialization) {
        guard let data = try? JSONEncoder().encode(serialization) else {
            return
        }
        try? data.write(to: store.syncStateURL, options: .atomic)
    }

    private func loadStateSerialization() -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: store.syncStateURL) else {
            return nil
        }
        return try? JSONDecoder().decode(
            CKSyncEngine.State.Serialization.self,
            from: data
        )
    }

    private func clearSyncState() {
        syncedMeetingVersions = [:]
        syncedFolderVersions = [:]
        syncedAudioVersions = [:]
        knownMeetingIDs = []
        knownFolderIDs = []
        try? FileManager.default.removeItem(at: store.syncStateURL)
    }
}

// MARK: - Errors

enum SyncError: LocalizedError {
    case audioNotSynced
    case syncUnavailable

    var errorDescription: String? {
        switch self {
        case .audioNotSynced:
            return InterfaceLanguage.current.text("sync.audio.notSynced")
        case .syncUnavailable:
            return InterfaceLanguage.current.text("sync.status.unavailable")
        }
    }
}
