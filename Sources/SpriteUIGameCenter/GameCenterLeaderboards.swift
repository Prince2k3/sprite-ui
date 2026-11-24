import ECSCore
import Foundation
@preconcurrency import GameKit
import Observation

public struct GameCenterLeaderboardEntry: Identifiable, Hashable, Sendable {
    public var id: NetworkPeerID { player.id }
    public let rank: Int
    public let score: Int
    public let formattedScore: String
    public let player: NetworkPeer
    public let context: UInt64
    public let date: Date?

    public init(rank: Int, score: Int, formattedScore: String, player: NetworkPeer,
                context: UInt64 = 0, date: Date? = nil) {
        self.rank = rank; self.score = score; self.formattedScore = formattedScore
        self.player = player; self.context = context; self.date = date
    }
}

public struct GameCenterLeaderboardResults: Hashable, Sendable {
    public let identifier: String
    public let title: String?
    public let entries: [GameCenterLeaderboardEntry]
    public let localPlayerEntry: GameCenterLeaderboardEntry?
    public let totalPlayerCount: Int

    public init(identifier: String, title: String? = nil, entries: [GameCenterLeaderboardEntry],
                localPlayerEntry: GameCenterLeaderboardEntry? = nil, totalPlayerCount: Int) {
        self.identifier = identifier; self.title = title; self.entries = entries
        self.localPlayerEntry = localPlayerEntry; self.totalPlayerCount = totalPlayerCount
    }
}

/// Basic global/all-time leaderboards. Calls never authenticate or present UI.
/// Preview stores this instance's player's highest score only, in memory, with
/// rank 1. An unsubmitted preview leaderboard returns empty results. Live score
/// ordering/formatting follows App Store Connect; no offline retry queue is used.
@MainActor @Observable
public final class GameCenterLeaderboards {
    public var lastResults: GameCenterLeaderboardResults? {
        synchronizeIdentity()
        return results
    }
    public var isLoading: Bool { active != nil }
    @ObservationIgnored private let context: GameCenterServiceContext
    @ObservationIgnored private let usesPreviewStore: Bool
    @ObservationIgnored private let backend: GameCenterLeaderboardsBackend
    private var results: GameCenterLeaderboardResults?
    @ObservationIgnored private var previewScores: [String: GameCenterLeaderboardEntry] = [:]
    @ObservationIgnored private var owner: GameCenterServiceContext.Operation?
    private var active: UUID?
    @ObservationIgnored private var cancelPending: (() -> Void)?

    public convenience init(mode: GameCenterServicesMode = .live) {
        self.init(context: GameCenterServiceContext(mode: mode))
    }

    convenience init(context: GameCenterServiceContext) {
        self.init(context: context, backend: .native, usesPreviewStore: context.isPreview)
    }

    init(context: GameCenterServiceContext, backend: GameCenterLeaderboardsBackend, usesPreviewStore: Bool = false) {
        self.context = context; self.backend = backend
        self.usesPreviewStore = usesPreviewStore
    }

    public func submit(score: Int, to identifier: String, context scoreContext: UInt64 = 0) async throws {
        try validateGameCenterIdentifier(identifier)
        _ = try await perform { [usesPreviewStore, backend] operation, _ in
            if usesPreviewStore {
                return GameCenterLeaderboardResults(identifier: identifier, entries: [
                    GameCenterLeaderboardEntry(rank: 1, score: score, formattedScore: String(score),
                                               player: operation.player, context: scoreContext)
                ], totalPlayerCount: 1)
            }
            try await backend.submit(score, identifier, scoreContext, operation.player)
            return nil
        } publish: { value in
            if self.usesPreviewStore, let candidate = value?.entries.first,
               self.previewScores[identifier].map({ candidate.score > $0.score }) ?? true {
                self.previewScores[identifier] = candidate
            }
            // A submission makes the previously loaded page stale.
            self.results = nil
        }
    }

    /// One-based inclusive ranks; at most 100 entries per request, as required
    /// by GameKit. Missing live definitions throw `notFound`.
    public func entries(for identifier: String, range: ClosedRange<Int> = 1...25) async throws -> GameCenterLeaderboardResults {
        try validateGameCenterIdentifier(identifier)
        let nativeRange = try Self.nativeRange(lower: range.lowerBound, upper: range.upperBound)
        let value = try await perform { [usesPreviewStore, backend] operation, previewScores in
            if usesPreviewStore {
                let local = previewScores[identifier]
                return GameCenterLeaderboardResults(identifier: identifier,
                    entries: local.map { range.contains($0.rank) ? [$0] : [] } ?? [],
                    localPlayerEntry: local, totalPlayerCount: local == nil ? 0 : 1)
            }
            return try await backend.entries(identifier, nativeRange, operation.player)
        } publish: { value in
            self.results = value
        } validate: { value in
            guard let value else { throw GameCenterServiceError.invalidData }
            try Self.validate(value, identifier: identifier, range: range)
            if let local = value.localPlayerEntry, local.player.id != self.owner?.player.id {
                throw GameCenterServiceError.invalidData
            }
        }
        guard let value else { throw GameCenterServiceError.invalidData }
        return value
    }

    /// The upper bound is exclusive. Empty ranges are rejected.
    public func entries(for identifier: String, range: Range<Int>) async throws -> GameCenterLeaderboardResults {
        guard range.lowerBound >= 1, range.upperBound > range.lowerBound else { throw GameCenterServiceError.invalidValue }
        return try await entries(for: identifier, range: range.lowerBound...(range.upperBound - 1))
    }

    func reset() {
        active = nil
        let cancel = cancelPending
        cancelPending = nil
        cancel?()
        owner = nil; results = nil; previewScores = [:]
    }

    private func synchronizeIdentity() {
        do {
            let operation = try context.begin()
            if let owner, owner.player.id != operation.player.id || owner.generation != operation.generation { reset() }
        } catch is CancellationError {
        } catch { reset() }
    }

    private static func nativeRange(lower: Int, upper: Int) throws -> NSRange {
        guard lower >= 1, upper >= lower, upper - lower < 100, upper < Int.max else {
            throw GameCenterServiceError.invalidValue
        }
        return NSRange(location: lower, length: upper - lower + 1)
    }

    private static func validate(_ value: GameCenterLeaderboardResults, identifier: String, range: ClosedRange<Int>) throws {
        guard value.identifier == identifier, value.totalPlayerCount >= 0, value.entries.count <= range.count else {
            throw GameCenterServiceError.invalidData
        }
        var ranks = Set<Int>(), players = Set<NetworkPeerID>()
        for entry in value.entries {
            guard range.contains(entry.rank), ranks.insert(entry.rank).inserted,
                  players.insert(entry.player.id).inserted else { throw GameCenterServiceError.invalidData }
            try validateEntry(entry, total: value.totalPlayerCount)
        }
        if let local = value.localPlayerEntry { try validateEntry(local, total: value.totalPlayerCount) }
    }

    private static func validateEntry(_ entry: GameCenterLeaderboardEntry, total: Int) throws {
        guard entry.rank > 0, entry.rank <= total,
              entry.date.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else { throw GameCenterServiceError.invalidData }
        do { try validateGameCenterIdentifier(entry.player.id.rawValue) }
        catch { throw GameCenterServiceError.invalidData }
    }

    private func perform(_ work: @escaping @MainActor (GameCenterServiceContext.Operation, [String: GameCenterLeaderboardEntry]) async throws -> GameCenterLeaderboardResults?,
                         publish: @MainActor (GameCenterLeaderboardResults?) -> Void,
                         validate: @MainActor (GameCenterLeaderboardResults?) throws -> Void = { _ in }) async throws -> GameCenterLeaderboardResults? {
        synchronizeIdentity()
        let operation: GameCenterServiceContext.Operation
        do { operation = try context.begin() } catch { throw gameCenterServiceFailure(error) }
        guard active == nil else { throw GameCenterServiceError.operationInProgress }
        owner = operation
        let token = UUID()
        active = token
        let request = GameCenterProgressRequest<GameCenterLeaderboardResults?>()
        cancelPending = { request.cancel() }
        defer { if active == token { active = nil; cancelPending = nil } }
        do {
            let scores = previewScores
            let value = try await request.run { [context] in
                try context.validate(operation)
                return try await work(operation, scores)
            }
            try context.validate(operation)
            guard active == token else { throw GameCenterServiceError.cancelled }
            try validate(value)
            publish(value)
            return value
        } catch {
            synchronizeIdentity()
            throw gameCenterServiceFailure(error)
        }
    }
}

@MainActor
struct GameCenterLeaderboardsBackend {
    var submit: @MainActor (Int, String, UInt64, NetworkPeer) async throws -> Void
    var entries: @MainActor (String, NSRange, NetworkPeer) async throws -> GameCenterLeaderboardResults

    static var native: Self {
        Self(submit: { score, identifier, context, player in
            try checkPlayer(player)
            let nativeContext = Int(bitPattern: UInt(context))
            try await GKLeaderboard.submitScore(score, context: nativeContext, player: GKLocalPlayer.local, leaderboardIDs: [identifier])
        }, entries: { identifier, range, player in
            let definitions = try await GKLeaderboard.loadLeaderboards(IDs: [identifier])
            try Task.checkCancellation()
            try checkPlayer(player)
            guard let leaderboard = definitions.first(where: { $0.baseLeaderboardID == identifier }) else {
                throw GameCenterServiceError.notFound
            }
            let (local, entries, count) = try await leaderboard.loadEntries(for: .global, timeScope: .allTime, range: range)
            return GameCenterLeaderboardResults(identifier: identifier, title: leaderboard.title,
                entries: entries.map(snapshot), localPlayerEntry: local.map(snapshot), totalPlayerCount: count)
        })
    }

    private static func checkPlayer(_ player: NetworkPeer) throws {
        guard GKLocalPlayer.local.isAuthenticated, GKLocalPlayer.local.gamePlayerID == player.id.rawValue else {
            throw GameCenterServiceError.accountChanged
        }
    }

    private static func snapshot(_ value: GKLeaderboard.Entry) -> GameCenterLeaderboardEntry {
        GameCenterLeaderboardEntry(rank: value.rank, score: value.score, formattedScore: value.formattedScore,
            player: NetworkPeer(id: .init(rawValue: value.player.gamePlayerID), displayName: value.player.displayName),
            context: UInt64(bitPattern: Int64(value.context)), date: value.date)
    }
}
