import ECSCore
import Foundation
@preconcurrency import GameKit
import Observation

/// An inert copy of one player's achievement progress; no GameKit objects escape.
public struct GameCenterAchievement: Identifiable, Hashable, Sendable {
    public var id: String { identifier }
    public let identifier: String
    public let percentComplete: Double
    public let lastReportedDate: Date?

    public init(identifier: String, percentComplete: Double, lastReportedDate: Date? = nil) {
        self.identifier = identifier
        self.percentComplete = percentComplete
        self.lastReportedDate = lastReportedDate
    }
}

/// Basic achievement progress. Construction never authenticates or starts work.
/// Preview progress exists only in this instance's memory. Failed reports are
/// thrown to the caller and are never placed in an automatic retry queue.
@MainActor @Observable
public final class GameCenterAchievements {
    public var achievements: [GameCenterAchievement] {
        synchronizeIdentity()
        return snapshots
    }
    public var isLoading: Bool { active != nil }
    @ObservationIgnored private let context: GameCenterServiceContext
    @ObservationIgnored private let usesPreviewStore: Bool
    @ObservationIgnored private let backend: GameCenterAchievementsBackend
    private var snapshots: [GameCenterAchievement] = []
    @ObservationIgnored private var owner: GameCenterServiceContext.Operation?
    private var active: UUID?
    @ObservationIgnored private var cancelPending: (() -> Void)?

    public convenience init(mode: GameCenterServicesMode = .live) {
        self.init(context: GameCenterServiceContext(mode: mode))
    }

    convenience init(context: GameCenterServiceContext) {
        self.init(context: context, backend: .native, usesPreviewStore: context.isPreview)
    }

    init(context: GameCenterServiceContext, backend: GameCenterAchievementsBackend, usesPreviewStore: Bool = false) {
        self.context = context
        self.backend = backend
        self.usesPreviewStore = usesPreviewStore
    }

    /// Loads started/completed achievements, sorted by identifier. Descriptions
    /// of achievements with no progress are presented by the native dashboard.
    @discardableResult
    public func load() async throws -> [GameCenterAchievement] {
        try await perform { [usesPreviewStore, backend] operation, known in
            if usesPreviewStore { return known }
            return try await backend.load(operation.player)
        }
    }

    /// Progress must be finite and in 0...100. Known progress never decreases;
    /// reporting an equal/lower value is a successful no-op. Load first to use
    /// server progress when suppressing already-earned completion banners.
    public func report(progress: Double, for identifier: String) async throws {
        try validateGameCenterIdentifier(identifier)
        guard progress.isFinite, (0...100).contains(progress) else { throw GameCenterServiceError.invalidValue }
        _ = try await perform { [usesPreviewStore, backend] operation, snapshots in
            let known = snapshots.first { $0.identifier == identifier }
            if let known, known.percentComplete >= progress { return snapshots }
            if !usesPreviewStore {
                try await backend.report(identifier, progress, progress == 100, operation.player)
            }
            return [GameCenterAchievement(identifier: identifier, percentComplete: progress,
                                          lastReportedDate: usesPreviewStore ? nil : Date())]
        }
    }

    public func unlock(_ identifier: String) async throws {
        try await report(progress: 100, for: identifier)
    }

    /// Clears local state only; never calls GameKit's destructive achievement reset.
    func reset() {
        active = nil
        let cancel = cancelPending
        cancelPending = nil
        cancel?()
        owner = nil
        snapshots = []
    }

    private func synchronizeIdentity() {
        do {
            let operation = try context.begin()
            if let owner, owner.player.id != operation.player.id || owner.generation != operation.generation { reset() }
        } catch is CancellationError {
            // Reading state from a cancelled caller does not erase another caller's work.
        } catch { reset() }
    }

    private func perform(_ work: @escaping @MainActor (GameCenterServiceContext.Operation, [GameCenterAchievement]) async throws -> [GameCenterAchievement]) async throws -> [GameCenterAchievement] {
        synchronizeIdentity()
        let operation: GameCenterServiceContext.Operation
        do { operation = try context.begin() } catch { throw gameCenterServiceFailure(error) }
        guard active == nil else { throw GameCenterServiceError.operationInProgress }
        owner = operation
        let token = UUID()
        active = token
        let request = GameCenterProgressRequest<[GameCenterAchievement]>()
        cancelPending = { request.cancel() }
        defer {
            if active == token { active = nil; cancelPending = nil }
        }
        do {
            let known = snapshots
            let values = try await request.run { [context] in
                try context.validate(operation)
                return try await work(operation, known)
            }
            try context.validate(operation)
            guard active == token else { throw GameCenterServiceError.cancelled }
            // Validate the entire response before publishing any of it.
            var merged = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.identifier, $0) })
            var seen = Set<String>()
            for value in values {
                do { try validateGameCenterIdentifier(value.identifier) }
                catch { throw GameCenterServiceError.invalidData }
                guard seen.insert(value.identifier).inserted, value.percentComplete.isFinite,
                      (0...100).contains(value.percentComplete),
                      value.lastReportedDate.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else {
                    throw GameCenterServiceError.invalidData
                }
                if let old = merged[value.identifier], old.percentComplete >= value.percentComplete { continue }
                merged[value.identifier] = value
            }
            snapshots = merged.values.sorted { $0.identifier < $1.identifier }
            return snapshots
        } catch {
            synchronizeIdentity()
            throw gameCenterServiceFailure(error)
        }
    }
}

/// Internal value-only asynchronous seam: tests never authenticate or touch GameKit.
@MainActor
struct GameCenterAchievementsBackend {
    var load: @MainActor (NetworkPeer) async throws -> [GameCenterAchievement]
    var report: @MainActor (String, Double, Bool, NetworkPeer) async throws -> Void

    static var native: Self {
        Self(load: { _ in
            let values = try await GKAchievement.loadAchievements()
            return values.map {
                GameCenterAchievement(identifier: $0.identifier, percentComplete: $0.percentComplete,
                                             lastReportedDate: $0.lastReportedDate)
            }
        }, report: { identifier, progress, banner, player in
            guard GKLocalPlayer.local.isAuthenticated, GKLocalPlayer.local.gamePlayerID == player.id.rawValue else {
                throw GameCenterServiceError.accountChanged
            }
            let value = GKAchievement(identifier: identifier)
            value.percentComplete = progress
            value.showsCompletionBanner = banner
            try await GKAchievement.report([value])
        })
    }
}

/// Cancellation finishes local callers promptly even when an SDK callback is
/// delayed. A retired callback cannot resume twice or publish into a new request.
@MainActor
final class GameCenterProgressRequest<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, any Error>?
    private var task: Task<Void, Never>?
    private var cancelled = false

    func run(_ work: @escaping @MainActor () async throws -> Value) async throws -> Value {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                task = Task { @MainActor [weak self] in
                    let result: Result<Value, any Error>
                    do { result = .success(try await work()) }
                    catch { result = .failure(error) }
                    self?.finish(result)
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    func cancel() {
        cancelled = true
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Value, any Error>) {
        let pending = continuation
        continuation = nil
        task = nil
        pending?.resume(with: result)
    }
}
