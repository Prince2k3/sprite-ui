import Foundation
import Observation

/// The current cloud directory phase. Ready means access is available, not that a later save has uploaded.
public enum CloudSaveStatus: Equatable, Sendable {
    case closed, syncing, ready, offline, localOnly, conflicted
    case failed(String)
}

/// An opaque choice representing an entire conflicting GameSave directory.
public struct CloudSaveVersion: Identifiable, Equatable, Sendable {
    /// An ephemeral choice ID, valid only for the current open conflict.
    public let id: UUID
    /// Whether this version came from the local device.
    public let isLocal: Bool
    /// The saving device's display name.
    public let deviceName: String
    /// The timestamp supplied by GameSave; it is not proof that this version is preferable.
    public let modifiedAt: Date
}

/// Explicit GameSave access, available on iOS/macOS 26+, with no sign-in or cloud work on construction.
/// Local `PlayerProfileStore` works on the package's older supported systems independently.
/// Close and reopen at a deliberate gameplay boundary to resume synchronization.
@MainActor @Observable
public final class CloudSaveDirectory {
    /// The consuming application's configured iCloud Documents container.
    public let containerIdentifier: String
    /// The last resolved native directory phase.
    public private(set) var status: CloudSaveStatus = .closed
    /// Whole-directory versions awaiting explicit selection.
    public private(set) var conflicts: [CloudSaveVersion] = []
    /// Whether the native GameSave adapter is available on this OS.
    public static var isSupported: Bool {
        #if canImport(GameSave)
        if #available(iOS 26, macOS 26, *) { return true }
        #endif
        return false
    }
    @ObservationIgnored private let driver: CloudSaveDriver
    @ObservationIgnored private var handle: (any CloudSaveHandle)?
    @ObservationIgnored private var gate: ProfileDirectoryGate?
    @ObservationIgnored private var lease: ProfileDirectoryLease?
    @ObservationIgnored private var availableURL: URL?
    @ObservationIgnored private var versions: [UUID: CloudVersionLocation] = [:]
    @ObservationIgnored private var operation: UUID?
    @ObservationIgnored private var request: CloudSyncRequest?
    @ObservationIgnored private var upload: UUID?
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    /// Creates a closed directory. Call `open()` only after configuring the app's iCloud capability.
    public convenience init(containerIdentifier: String) throws {
        try self.init(containerIdentifier: containerIdentifier, driver: .native)
    }
    init(containerIdentifier: String, driver: CloudSaveDriver) throws {
        try validateSaveID(containerIdentifier)
        self.containerIdentifier = containerIdentifier; self.driver = driver
    }
    isolated deinit { close() }

    /// Opens and waits for a usable directory or conflicts, without presenting native UI.
    /// This may use GameSave's local-only/offline directory; it never falls back to a different local profile silently.
    public func open() async throws {
        guard handle == nil, operation == nil else { throw ProfileSaveError.operationInProgress }
        let token = UUID(), gate = ProfileDirectoryGate()
        self.gate = gate; operation = token; status = .syncing
        do {
            try Task.checkCancellation()
            let handle = try driver.open(containerIdentifier)
            self.handle = handle
            observer = NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: nil) { [weak self, gate] _ in
                // Invalidate access on the notification's thread, before the UI actor handles teardown.
                gate.invalidate()
                Task { @MainActor [weak self] in if self?.operation == token { self?.close() } }
            }
            try await finish(handle, token: token)
        } catch {
            if operation == token { close(); if !(error is CancellationError) { status = .failed(error.localizedDescription) } }
            throw error
        }
    }

    /// Waits again after resolving a conflict if the native directory is still syncing.
    public func finishSyncing() async throws {
        guard let handle, let token = operation else { throw ProfileSaveError.directoryClosed }
        guard request == nil, upload == nil else { throw ProfileSaveError.operationInProgress }
        gate?.invalidate(); availableURL = nil; lease = nil; status = .syncing
        do { try await finish(handle, token: token) }
        catch {
            if operation == token { close(); if !(error is CancellationError) { status = .failed(error.localizedDescription) } }
            throw error
        }
    }

    private func finish(_ handle: any CloudSaveHandle, token: UUID) async throws {
        let request = CloudSyncRequest(); self.request = request
        defer { if self.request === request { self.request = nil } }
        try await request.wait { await handle.finishSyncing() }
        try Task.checkCancellation()
        guard operation == token else { throw ProfileSaveError.directoryClosed }
        try apply(handle.snapshot())
    }

    /// Creates an identity-bound store in the available native directory.
    /// The returned store stops working when this directory closes, changes account, or resolves a conflict.
    public func makeStore<State: Codable & Sendable>(for player: PlayerProfileID, schema: ProfileSaveSchema<State>,
                                                     maximumBytes: Int = 4 * 1_024 * 1_024) throws -> PlayerProfileStore<State> {
        guard let url = availableURL, let lease else { throw ProfileSaveError.directoryClosed }
        return try PlayerProfileStore(player: player, directory: url.appendingPathComponent("SpriteUIProfiles", isDirectory: true),
            schema: schema, maximumBytes: maximumBytes, access: lease, readOnly: false)
    }

    /// Creates a read-only store to inspect a conflicting version before selecting it.
    public func inspect<State: Codable & Sendable>(_ version: UUID, for player: PlayerProfileID,
                                                   schema: ProfileSaveSchema<State>, maximumBytes: Int = 4 * 1_024 * 1_024) throws -> PlayerProfileStore<State> {
        guard status == .conflicted, let location = versions[version], let lease else { throw ProfileSaveError.unknownConflict }
        return try PlayerProfileStore(player: player, directory: location.url.appendingPathComponent("SpriteUIProfiles", isDirectory: true),
            schema: schema, maximumBytes: maximumBytes, access: lease, readOnly: true)
    }

    /// Selects one whole directory, potentially replacing all profiles/slots with that version.
    /// No automatic highest-score, wallet, or quest-ledger merge is attempted.
    public func resolve(using version: UUID) throws {
        guard request == nil, upload == nil, status == .conflicted, versions[version] != nil, let handle else { throw ProfileSaveError.unknownConflict }
        gate?.invalidate(); lease = nil
        do { try handle.resolve(version); try apply(handle.snapshot()) }
        catch { close(); status = .failed(error.localizedDescription); throw error }
    }

    /// Asks GameSave to trigger pending uploads. True means uploads were pending, not remote durability confirmation.
    public func requestUpload() async throws -> Bool {
        try Task.checkCancellation()
        guard request == nil, upload == nil else { throw ProfileSaveError.operationInProgress }
        guard let handle, let token = operation, availableURL != nil else { throw ProfileSaveError.directoryClosed }
        let upload = UUID(); self.upload = upload
        defer { if self.upload == upload { self.upload = nil } }
        let value = await handle.triggerPendingUpload()
        try Task.checkCancellation()
        guard operation == token else { throw ProfileSaveError.directoryClosed }
        return value
    }

    /// Invalidates all stores and read-only previews before releasing the native directory to sync.
    /// This does not wait for cloud upload completion or delete any files.
    public func close() {
        gate?.invalidate(); gate = nil; lease = nil; availableURL = nil
        operation = nil; upload = nil; versions = [:]; conflicts = []; status = .closed
        let pending = request; request = nil; pending?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        handle?.close(); handle = nil
    }

    private func apply(_ snapshot: CloudDirectorySnapshot) throws {
        gate?.invalidate(); availableURL = nil; lease = nil; versions = [:]; conflicts = []
        switch snapshot {
        case .available(let url, let status):
            guard url.isFileURL, [.ready, .offline, .localOnly].contains(status) else { throw ProfileSaveError.invalidValue }
            self.status = status; availableURL = url; lease = gate?.activate()
        case .conflicted(let choices):
            guard !choices.isEmpty, Set(choices.map { $0.version.id }).count == choices.count,
                  choices.allSatisfy({ $0.url.isFileURL }) else { throw ProfileSaveError.corruptData }
            status = .conflicted; conflicts = choices.map(\.version)
            versions = Dictionary(uniqueKeysWithValues: choices.map { ($0.version.id, $0) }); lease = gate?.activate()
        case .syncing: status = .syncing
        case .closed: throw ProfileSaveError.directoryClosed
        case .failed(let message): status = .failed(message); throw ProfileSaveError.cloudFailure(message)
        }
    }
}

struct CloudVersionLocation {
    let version: CloudSaveVersion
    let url: URL
}
enum CloudDirectorySnapshot {
    case available(URL, CloudSaveStatus), conflicted([CloudVersionLocation]), syncing, closed, failed(String)
}
@MainActor protocol CloudSaveHandle: AnyObject {
    func finishSyncing() async
    func snapshot() -> CloudDirectorySnapshot
    func resolve(_ version: UUID) throws
    func triggerPendingUpload() async -> Bool
    func close()
}
@MainActor struct CloudSaveDriver {
    var open: @MainActor (String) throws -> any CloudSaveHandle
}

@MainActor private final class CloudSyncRequest {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var task: Task<Void, Never>?
    private var cancelled = false
    func wait(_ work: @escaping @MainActor () async -> Void) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                task = Task { @MainActor [weak self] in await work(); self?.complete() }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }
    func cancel() {
        cancelled = true; task?.cancel(); task = nil
        let pending = continuation; continuation = nil; pending?.resume(throwing: CancellationError())
    }
    private func complete() {
        let pending = continuation; continuation = nil; task = nil; pending?.resume()
    }
}
