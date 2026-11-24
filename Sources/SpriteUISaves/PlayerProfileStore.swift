import Darwin
import Foundation
import Synchronization

/// The readability of an individual save slot without discarding damaged data.
public enum ProfileSlotHealth: String, Sendable { case available, recoveryAvailable, unreadable }

/// Metadata for one slot. Damaged entries may have no recoverable slot identifier.
public struct ProfileSlotSummary: Identifiable, Sendable {
    /// A stable opaque storage key, not a filesystem path.
    public let id: String
    /// The original slot ID when current or backup metadata is readable.
    public let slot: SaveSlotID?
    /// The last readable save time.
    public let savedAt: Date?
    /// Whether the current record or its retained backup is usable.
    public let health: ProfileSlotHealth
}

/// A typed, identity-bound store. Synchronous transactions run on its actor and
/// hold an interprocess filesystem lock; transaction closures must be brief and use value-semantic state.
/// Local commits are atomic slot-file replacements, not cloud/server transactions.
public actor PlayerProfileStore<State: Codable & Sendable> {
    /// The immutable player namespace served by this store.
    public let player: PlayerProfileID
    /// The schema used for payload encoding and migrations.
    public let schema: ProfileSaveSchema<State>
    /// The maximum encoded archive size, including metadata and wallet; default four MiB.
    public let maximumBytes: Int
    private let directory: URL
    private let access: ProfileDirectoryLease?
    private let readOnly: Bool
    private let writeFile: @Sendable (Data, URL) throws -> Void

    /// Creates a store without reading or writing files. Pass an Application Support location for local saves.
    public init(player: PlayerProfileID, directory: URL, schema: ProfileSaveSchema<State>, maximumBytes: Int = 4 * 1_024 * 1_024) throws {
        try player.validate()
        guard directory.isFileURL, (1_024...64 * 1_024 * 1_024).contains(maximumBytes) else { throw ProfileSaveError.invalidValue }
        self.player = player; self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.schema = schema; self.maximumBytes = maximumBytes; access = nil; readOnly = false
        writeFile = { try $0.write(to: $1, options: .atomic) }
    }

    init(player: PlayerProfileID, directory: URL, schema: ProfileSaveSchema<State>, maximumBytes: Int,
         access: ProfileDirectoryLease, readOnly: Bool,
         writeFile: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        try player.validate()
        guard directory.isFileURL, (1_024...64 * 1_024 * 1_024).contains(maximumBytes) else { throw ProfileSaveError.invalidValue }
        self.player = player; self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.schema = schema; self.maximumBytes = maximumBytes; self.access = access; self.readOnly = readOnly
        self.writeFile = writeFile
    }

    /// Creates a new slot, refusing to overwrite any existing file, including a damaged one.
    public func create(in slot: SaveSlotID, state: State, at date: Date) throws -> PlayerProfile<State> {
        try transaction(writing: true) {
            try validateDate(date)
            let url = try slotURL(slot)
            guard !fileEntryExists(url) else { throw ProfileSaveError.slotExists }
            let profile = PlayerProfile(player: player, slot: slot, schemaVersion: schema.version, savedAt: date, state: state)
            try write(profile, previous: nil, to: url)
            return profile
        }
    }

    /// Loads and migrates a slot in memory. Loading never rewrites it or silently falls back to older data.
    public func load(from slot: SaveSlotID) throws -> PlayerProfile<State> {
        try transaction { try decode(readSlot(slot).current, expected: slot) }
    }

    /// Persists candidate state only if the disk revision still matches. Returns the newly committed revision.
    @discardableResult
    public func save(_ profile: PlayerProfile<State>, at date: Date) throws -> PlayerProfile<State> {
        try update(profile, at: date) { _ in }
    }

    /// Changes state and wallet, then commits both together after an optimistic revision check.
    /// A throwing closure, failed write, or stale revision leaves the persisted slot unchanged.
    @discardableResult
    public func update(_ profile: PlayerProfile<State>, at date: Date,
                       _ change: @Sendable (inout PlayerProfile<State>) throws -> Void) throws -> PlayerProfile<State> {
        try transaction(writing: true) {
            try validateDate(date)
            guard profile.player == player, profile.schemaVersion == schema.version else { throw ProfileSaveError.identityMismatch }
            let slot = try readSlot(profile.slot)
            let old = try decode(slot.current, expected: profile.slot)
            guard old.revision == profile.revision else { throw ProfileSaveError.staleRevision }
            var candidate = profile
            try change(&candidate)
            guard candidate.player == player, candidate.slot == profile.slot,
                  candidate.revision == profile.revision, candidate.schemaVersion == schema.version,
                  candidate.parentRevision == profile.parentRevision, candidate.savedAt == profile.savedAt else {
                throw ProfileSaveError.identityMismatch
            }
            candidate.parentRevision = old.revision; candidate.revision = UUID(); candidate.savedAt = date
            try write(candidate, previous: slot.current, to: slotURL(profile.slot))
            return candidate
        }
    }

    /// Lists slots without erasing corruption. Schema-incompatible entries remain visible as unreadable.
    public func slots() throws -> [ProfileSlotSummary] {
        try transaction {
            let folder = try playerDirectory()
            let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "slot" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            return urls.map { url in
                do {
                    let slot = try readFile(url)
                    if let current = try? decode(slot.current, expected: nil), try slotURL(current.slot).lastPathComponent == url.lastPathComponent {
                        return ProfileSlotSummary(id: url.deletingPathExtension().lastPathComponent, slot: current.slot, savedAt: current.savedAt, health: .available)
                    }
                    // A future format/schema is not advertised as recoverable via an older backup.
                    if let header = try? JSONDecoder().decode(ProfileArchiveHeader.self, from: slot.current), header.formatVersion != 1 {
                        return ProfileSlotSummary(id: url.deletingPathExtension().lastPathComponent, slot: nil, savedAt: nil, health: .unreadable)
                    }
                    if let current = try? archiveRecord(slot.current), current.player == player, current.schemaVersion > schema.version {
                        return ProfileSlotSummary(id: url.deletingPathExtension().lastPathComponent, slot: current.slot, savedAt: current.savedAt, health: .unreadable)
                    }
                    if let previous = slot.previous, let backup = try? decode(previous, expected: nil), try slotURL(backup.slot).lastPathComponent == url.lastPathComponent {
                        return ProfileSlotSummary(id: url.deletingPathExtension().lastPathComponent, slot: backup.slot, savedAt: backup.savedAt, health: .recoveryAvailable)
                    }
                } catch { /* Surface this entry as unreadable; never delete or replace it. */ }
                return ProfileSlotSummary(id: url.deletingPathExtension().lastPathComponent, slot: nil, savedAt: nil, health: .unreadable)
            }
        }
    }

    /// Explicitly restores the previous committed archive as a new revision. The previous archive remains the backup.
    /// This rolls back game progress and wallet together; it cannot undo external reward grants.
    @discardableResult
    public func recoverBackup(in slot: SaveSlotID, at date: Date) throws -> PlayerProfile<State> {
        try transaction(writing: true) {
            try validateDate(date)
            let record = try readSlot(slot)
            // Never overwrite an archive written by a newer game build through a recovery shortcut.
            if let header = try? JSONDecoder().decode(ProfileArchiveHeader.self, from: record.current), header.formatVersion != 1 {
                throw ProfileSaveError.unsupportedVersion(header.formatVersion)
            }
            if let current = try? archiveRecord(record.current), current.schemaVersion > schema.version {
                throw ProfileSaveError.unsupportedVersion(current.schemaVersion)
            }
            guard let previous = record.previous else { throw ProfileSaveError.unavailableBackup }
            var profile = try decode(previous, expected: slot)
            profile.parentRevision = profile.revision; profile.revision = UUID(); profile.savedAt = date
            try write(profile, previous: previous, to: slotURL(slot))
            return profile
        }
    }

    /// Deletes this slot and its retained backup only when its revision is still current.
    /// Deletion in a cloud directory is synchronized by GameSave after release; it is not an immediate remote acknowledgement.
    public func delete(_ profile: PlayerProfile<State>) throws {
        try transaction(writing: true) {
            guard profile.player == player else { throw ProfileSaveError.identityMismatch }
            let file = try readSlot(profile.slot)
            let current = try decode(file.current, expected: profile.slot)
            guard current.revision == profile.revision else { throw ProfileSaveError.staleRevision }
            try Task.checkCancellation()
            try FileManager.default.removeItem(at: slotURL(profile.slot))
        }
    }

    private func validateDate(_ date: Date) throws {
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw ProfileSaveError.invalidValue }
    }
    private func archiveRecord(_ bytes: Data) throws -> ProfileRecord {
        guard bytes.count <= maximumBytes else { throw ProfileSaveError.capacityExceeded }
        return try JSONDecoder().decode(ProfileArchive.self, from: bytes).record(maximumBytes: maximumBytes)
    }
    private func decode(_ bytes: Data, expected: SaveSlotID?) throws -> PlayerProfile<State> {
        let record = try archiveRecord(bytes)
        guard record.player == player, expected.map({ $0 == record.slot }) ?? true else { throw ProfileSaveError.identityMismatch }
        let state = try schema.decode(record.payload, version: record.schemaVersion, maximumBytes: maximumBytes)
        return PlayerProfile(player: player, slot: record.slot, schemaVersion: schema.version, revision: record.revision,
            parentRevision: record.parentRevision, savedAt: record.savedAt, state: state, wallet: record.wallet)
    }
    private func write(_ profile: PlayerProfile<State>, previous: Data?, to url: URL) throws {
        let payload = try saveEncoder().encode(profile.state)
        let archive = try ProfileArchive(record: ProfileRecord(player: player, slot: profile.slot, schemaVersion: schema.version,
            revision: profile.revision, parentRevision: profile.parentRevision, savedAt: profile.savedAt, payload: payload, wallet: profile.wallet))
        let bytes = try saveEncoder().encode(archive)
        guard bytes.count <= maximumBytes else { throw ProfileSaveError.capacityExceeded }
        let record = try saveEncoder().encode(ProfileSlotFile(current: bytes, previous: previous))
        guard record.count <= maximumBytes * 4 else { throw ProfileSaveError.capacityExceeded }
        try checkRegularFile(url, missingAllowed: true)
        try Task.checkCancellation()
        try writeFile(record, url)
    }
    private func readSlot(_ slot: SaveSlotID) throws -> ProfileSlotFile { try readFile(slotURL(slot)) }
    private func readFile(_ url: URL) throws -> ProfileSlotFile {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ProfileSaveError.slotNotFound }
        try checkRegularFile(url, missingAllowed: false)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes * 4 else { throw ProfileSaveError.capacityExceeded }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= maximumBytes * 4 else { throw ProfileSaveError.capacityExceeded }
        let slot = try JSONDecoder().decode(ProfileSlotFile.self, from: bytes)
        guard slot.formatVersion == 1 else { throw ProfileSaveError.unsupportedVersion(slot.formatVersion) }
        return slot
    }
    private func playerDirectory() throws -> URL {
        let owner = saveDigest(try saveEncoder().encode(player))
        let url = directory.appendingPathComponent(owner, isDirectory: true)
        if readOnly { try requireDirectory(url) } else { try ensureDirectory(url) }
        return url
    }
    private func slotURL(_ slot: SaveSlotID) throws -> URL {
        try playerDirectory().appendingPathComponent(saveDigest(Data(slot.rawValue.utf8))).appendingPathExtension("slot")
    }
    private func transaction<T>(writing: Bool = false, _ action: () throws -> T) throws -> T {
        try Task.checkCancellation()
        if writing && readOnly { throw ProfileSaveError.readOnly }
        func perform() throws -> T {
            if readOnly {
                // GameSave conflict versions are frozen; inspection must not add locks or directories there.
                try requireDirectory(directory)
                return try action()
            }
            try ensureDirectory(directory)
            let lock = directory.appendingPathComponent("store.lock")
            try checkRegularFile(lock, missingAllowed: true)
            let fd = Darwin.open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { Darwin.close(fd) }
            guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { _ = flock(fd, LOCK_UN) }
            return try action()
        }
        if let access { return try access.withAccess(perform) }
        return try perform()
    }
}

private func ensureDirectory(_ url: URL) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: url.path) {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else { throw ProfileSaveError.corruptData }
    } else { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
}
private func requireDirectory(_ url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { throw ProfileSaveError.slotNotFound }
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
    guard values.isSymbolicLink != true, values.isDirectory == true else { throw ProfileSaveError.corruptData }
}
private func checkRegularFile(_ url: URL, missingAllowed: Bool) throws {
    if missingAllowed && !fileEntryExists(url) { return }
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
    guard values.isSymbolicLink != true, values.isRegularFile == true else { throw ProfileSaveError.corruptData }
}
private func fileEntryExists(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
}

final class ProfileDirectoryGate: Sendable {
    private struct State { var generation: UInt64 = 0; var active = false }
    private let storage = Mutex(State())
    func activate() -> ProfileDirectoryLease {
        storage.withLock { $0.generation &+= 1; $0.active = true; return ProfileDirectoryLease(gate: self, generation: $0.generation) }
    }
    func invalidate() { storage.withLock { $0.generation &+= 1; $0.active = false } }
    fileprivate func withAccess<T>(_ generation: UInt64, _ work: () throws -> T) throws -> T {
        try storage.withLock { state in
            guard state.active, state.generation == generation else { throw ProfileSaveError.directoryClosed }
            return try work()
        }
    }
}
struct ProfileDirectoryLease: Sendable {
    let gate: ProfileDirectoryGate
    let generation: UInt64
    func withAccess<T>(_ work: () throws -> T) throws -> T { try gate.withAccess(generation, work) }
}
