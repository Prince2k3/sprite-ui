import Foundation
@preconcurrency import GameKit
import Observation

/// Configured native challenge metadata. It does not represent a custom SpriteUI league or quest.
public struct GameCenterChallengeDefinition: Hashable, Sendable, Identifiable {
    /// The configured challenge identifier.
    public let id: String
    /// The localized title.
    public let title: String
    /// Optional localized details.
    public let details: String?
    /// The leaderboard whose submissions also count as challenge attempts.
    public let leaderboardID: String?
    /// Whether players can attempt this configured challenge more than once.
    public let isRepeatable: Bool
    /// Creates inert metadata, including fixtures for explicit previews.
    public init(id: String, title: String, details: String? = nil, leaderboardID: String?, isRepeatable: Bool) {
        self.id = id; self.title = title; self.details = details; self.leaderboardID = leaderboardID; self.isRepeatable = isRepeatable
    }
}

/// The local handling state of one report. Requested is not remote durability confirmation.
public enum GameCenterChallengeAttemptStatus: String, Sendable { case reporting, requested, uncertain }

/// One bounded, in-memory attempt record. Persist application attempt IDs before native submission when needed.
public struct GameCenterChallengeAttempt: Hashable, Sendable, Identifiable {
    /// The application's stable per-attempt identifier.
    public let id: UUID
    /// The configured challenge definition ID.
    public let challengeID: String
    /// The associated leaderboard ID.
    public let leaderboardID: String
    /// The latest completed-attempt score, including one below the personal best.
    public let score: Int
    /// Application-defined score metadata, not an idempotency key understood by Game Center.
    public let context: UInt64
    /// The local submission state.
    public let status: GameCenterChallengeAttemptStatus
}

/// Challenge catalogs, active decorations, and explicit direct attempt reporting.
/// Native UI is presented by GameCenterServices. Never report both here and via activity finish for the same attempt.
@MainActor @Observable
public final class GameCenterChallenges {
    /// Loaded challenge definition snapshots.
    public var definitions: [GameCenterChallengeDefinition] { synchronizeIdentity(); return catalog }
    /// At most 256 retained attempt IDs; new IDs fail at capacity rather than silently losing retry protection.
    public var attempts: [GameCenterChallengeAttempt] { synchronizeIdentity(); return records }
    /// Whether a catalog, active-state, or report operation is in flight.
    public var isLoading: Bool { active != nil }
    @ObservationIgnored private let context: GameCenterServiceContext
    @ObservationIgnored private let leaderboards: GameCenterLeaderboards
    @ObservationIgnored private let backend: GameCenterChallengesBackend
    @ObservationIgnored private let usesPreview: Bool
    @ObservationIgnored private var fixtures: [GameCenterChallengeDefinition] = []
    @ObservationIgnored private var previewActive: Set<String> = []
    @ObservationIgnored private var owner: GameCenterServiceContext.Operation?
    @ObservationIgnored private var cancellation: (() -> Void)?
    private var active: UUID?
    private var catalog: [GameCenterChallengeDefinition] = []
    private var records: [GameCenterChallengeAttempt] = []

    /// Creates a stopped service. Live calls require OS 26+, authentication, and configured native resources.
    public convenience init(mode: GameCenterServicesMode = .live) {
        let context = GameCenterServiceContext(mode: mode)
        self.init(context: context, leaderboards: .init(context: context))
    }
    convenience init(context: GameCenterServiceContext, leaderboards: GameCenterLeaderboards) {
        self.init(context: context, leaderboards: leaderboards, backend: .native, usesPreview: context.isPreview)
    }
    init(context: GameCenterServiceContext, leaderboards: GameCenterLeaderboards,
         backend: GameCenterChallengesBackend, usesPreview: Bool = false) {
        self.context = context; self.leaderboards = leaderboards; self.backend = backend; self.usesPreview = usesPreview
    }
    isolated deinit { reset() }

    /// Configures an account-free catalog and active flags without calling Apple.
    public func configurePreview(_ values: [GameCenterChallengeDefinition], activeChallengeIDs: Set<String> = []) throws {
        guard usesPreview else { throw GameCenterServiceError.unavailable }
        guard active == nil, records.isEmpty else { throw GameCenterServiceError.operationInProgress }
        try validate(values)
        guard activeChallengeIDs.isSubset(of: Set(values.map(\.id))) else { throw GameCenterServiceError.invalidValue }
        fixtures = values; previewActive = activeChallengeIDs; catalog = []
    }

    /// Loads metadata only. Query active challenge state separately when useful for a UI decoration.
    @discardableResult public func load() async throws -> [GameCenterChallengeDefinition] {
        let values = try await perform { [usesPreview, fixtures, backend] in usesPreview ? fixtures : try await backend.load() }
        try validate(values); catalog = values; return values
    }

    /// Queries whether this loaded definition has active challenges; it does not create one.
    public func hasActiveChallenges(for id: String) async throws -> Bool {
        _ = try begin()
        guard catalog.contains(where: { $0.id == id }) else { throw GameCenterServiceError.notFound }
        return try await perform { [usesPreview, previewActive, backend] in usesPreview ? previewActive.contains(id) : try await backend.hasActive(id) }
    }

    /// Reports a completed attempt through its configured leaderboard, even below a personal best.
    /// An identical requested ID is a no-op. An uncertain ID cannot be retried automatically.
    /// GameKit consumes attempts through leaderboard submission; its score context is NOT a deduplication key.
    @discardableResult public func submitAttempt(score: Int, for challengeID: String, attemptID: UUID,
                                                context scoreContext: UInt64 = 0) async throws -> GameCenterChallengeAttempt {
        let operation = try begin()
        guard let definition = catalog.first(where: { $0.id == challengeID }), let board = definition.leaderboardID else {
            throw GameCenterServiceError.notFound
        }
        if let previous = records.first(where: { $0.id == attemptID }) {
            guard previous.challengeID == challengeID, previous.score == score, previous.context == scoreContext else { throw GameCenterServiceError.invalidData }
            switch previous.status {
            case .requested: return previous
            case .reporting: throw GameCenterServiceError.operationInProgress
            case .uncertain: throw GameCenterServiceError.attemptUncertain
            }
        }
        guard active == nil else { throw GameCenterServiceError.operationInProgress }
        guard !leaderboards.isLoading else { throw GameCenterServiceError.operationInProgress }
        guard records.count < 256 else { throw GameCenterServiceError.capacityExceeded }
        let token = UUID(); active = token
        func record(_ status: GameCenterChallengeAttemptStatus) -> GameCenterChallengeAttempt {
            .init(id: attemptID, challengeID: challengeID, leaderboardID: board, score: score, context: scoreContext, status: status)
        }
        records.append(record(.reporting))
        defer { if active == token { active = nil } }
        do {
            try context.validate(operation)
            try await leaderboards.submit(score: score, to: board, context: scoreContext)
            try context.validate(operation)
            guard active == token else { throw GameCenterServiceError.cancelled }
            let value = record(.requested); records[records.count - 1] = value; return value
        } catch {
            if active == token, let index = records.firstIndex(where: { $0.id == attemptID }) { records[index] = record(.uncertain) }
            synchronizeIdentity(); throw gameCenterServiceFailure(error)
        }
    }

    func reset() { active = nil; cancellation?(); cancellation = nil; owner = nil; catalog = []; records = [] }
    private func begin() throws -> GameCenterServiceContext.Operation {
        synchronizeIdentity()
        guard usesPreview || backend.isSupported else { throw GameCenterServiceError.unavailable }
        let value = try context.begin(); owner = value; return value
    }
    private func synchronizeIdentity() {
        do { let value = try context.begin(); if let owner, owner.player.id != value.player.id || owner.generation != value.generation { reset() } }
        catch is CancellationError { } catch { reset() }
    }
    private func validate(_ values: [GameCenterChallengeDefinition]) throws {
        guard values.count <= 256, Set(values.map(\.id)).count == values.count else { throw GameCenterServiceError.invalidData }
        for value in values {
            try validateGameCenterIdentifier(value.id)
            if let id = value.leaderboardID { try validateGameCenterIdentifier(id) }
            guard !value.title.isEmpty else { throw GameCenterServiceError.invalidData }
        }
    }
    private func perform<Value: Sendable>(_ work: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let operation = try begin()
        guard active == nil else { throw GameCenterServiceError.operationInProgress }
        let token = UUID(); active = token
        let request = GameCenterProgressRequest<Value>(); cancellation = { request.cancel() }
        defer { if active == token { active = nil; cancellation = nil } }
        let value = try await request.run(work)
        try context.validate(operation)
        guard active == token else { throw GameCenterServiceError.cancelled }
        return value
    }
}

@MainActor struct GameCenterChallengesBackend {
    var isSupported = true
    var load: @MainActor () async throws -> [GameCenterChallengeDefinition]
    var hasActive: @MainActor (String) async throws -> Bool
    static var native: Self {
        if #available(iOS 26, macOS 26, *) {
            let cache = NativeChallengeCatalog()
            return .init(load: { try await cache.load() }, hasActive: { try await cache.hasActive($0) })
        }
        return .init(isSupported: false, load: { throw GameCenterServiceError.unavailable }, hasActive: { _ in throw GameCenterServiceError.unavailable })
    }
}

@available(iOS 26, macOS 26, *)
@MainActor private final class NativeChallengeCatalog {
    private var definitions: [String: GKChallengeDefinition] = [:]
    func load() async throws -> [GameCenterChallengeDefinition] {
        let values = try await GKChallengeDefinition.all
        try Task.checkCancellation()
        guard values.count <= 256, Set(values.map(\.identifier)).count == values.count else { throw GameCenterServiceError.invalidData }
        definitions = Dictionary(uniqueKeysWithValues: values.map { ($0.identifier, $0) })
        return values.map { .init(id: $0.identifier, title: $0.title, details: $0.details,
            leaderboardID: $0.leaderboard?.baseLeaderboardID, isRepeatable: $0.isRepeatable) }
    }
    func hasActive(_ id: String) async throws -> Bool {
        guard let definition = definitions[id] else { throw GameCenterServiceError.notFound }
        return try await definition.hasActiveChallenges
    }
}
