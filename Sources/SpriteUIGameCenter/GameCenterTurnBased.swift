import CryptoKit
import ECSCore
import Foundation
@preconcurrency import GameKit
import Observation

public enum GameCenterTurnBasedStatus: String, Codable, Sendable {
    case unknown, open, ended, matching
}

public enum GameCenterTurnBasedParticipantStatus: String, Codable, Sendable {
    case unknown, invited, declined, matching, active, done
}

public enum GameCenterTurnBasedOutcome: Int, Codable, Sendable {
    case unknown = -1, none = 0, quit, won, lost, tied, timeExpired, first, second, third, fourth
}

/// Slots remain stable even before Game Center assigns a player to an invitation.
public struct GameCenterTurnBasedParticipant: Hashable, Codable, Sendable, Identifiable {
    public let slot: Int
    public let player: NetworkPeer?
    public let status: GameCenterTurnBasedParticipantStatus
    public let outcome: GameCenterTurnBasedOutcome
    public var id: Int { slot }

    var canReceiveTurn: Bool {
        outcome == .none && [.active, .invited, .matching].contains(status)
    }
}

/// An inert snapshot. Holding or decoding one never restores an ECS world.
/// Reload before acting on a stale revision. GameKit has no atomic compare-and-
/// swap API: native revision checks detect changes observed by the preflight
/// reload, but cannot prevent another device writing after that reload.
public struct GameCenterTurnBasedMatch: Hashable, Sendable, Identifiable {
    public let id: String
    public let participants: [GameCenterTurnBasedParticipant]
    public let currentTurnSlot: Int?
    public let status: GameCenterTurnBasedStatus
    public let data: Data
    public let revision: String
    public let maximumDataSize: Int
    let localPlayerID: NetworkPeerID?

    public var currentPlayer: NetworkPeer? {
        participants.first { $0.slot == currentTurnSlot }?.player
    }
    public var localCanAct: Bool {
        (status == .open || status == .matching) && localPlayerID != nil &&
        participants.contains { $0.slot == currentTurnSlot && $0.player?.id == localPlayerID &&
            $0.status == .active && $0.outcome == .none }
    }

    func forPlayer(_ id: NetworkPeerID) -> Self {
        Self(id: self.id, participants: participants, currentTurnSlot: currentTurnSlot,
             status: status, data: data, revision: revision, maximumDataSize: maximumDataSize, localPlayerID: id)
    }
}

private struct TurnBasedEnvelope: Codable {
    let format: String
    let version: Int
    let mutation: UUID
    let state: Data
}

enum GameCenterTurnBasedChange: Sendable {
    case save(Data)
    case endTurn(Data, [Int])
    case finish(Data, [Int: GameCenterTurnBasedOutcome])
    case forfeit([Int])

    var data: Data? {
        switch self {
        case .save(let data), .endTurn(let data, _), .finish(let data, _): data
        case .forfeit: nil
        }
    }
}

/// Explicit, process-local preview persistence. Pass the SAME instance to two
/// services with different `.preview(player:)` identities to simulate turns.
/// There is no singleton, disk persistence, account access, or automatic syncing.
@MainActor
public final class InMemoryTurnBasedStore {
    public let maximumDataSize: Int
    private var records: [String: GameCenterTurnBasedMatch] = [:]

    public init(maximumDataSize: Int = 64 * 1024) {
        self.maximumDataSize = max(0, maximumDataSize)
    }

    /// Seeds known players and/or pending slots. Empty payloads mean no state
    /// has been saved yet; use a service's typed save API to initialize it.
    @discardableResult
    public func createMatch(participants: [NetworkPeer?], currentTurnSlot: Int = 0,
                            data: Data = Data()) throws -> String {
        guard participants.count >= 2, participants.count <= 16,
              participants.indices.contains(currentTurnSlot), participants[currentTurnSlot] != nil else {
            throw GameCenterServiceError.invalidValue
        }
        let ids = participants.compactMap { $0?.id }
        guard Set(ids).count == ids.count else { throw GameCenterServiceError.invalidValue }
        for id in ids { try validateGameCenterIdentifier(id.rawValue) }
        guard data.count <= maximumDataSize else { throw GameCenterServiceError.capacityExceeded }
        let id = UUID().uuidString
        records[id] = .init(id: id, participants: participants.enumerated().map {
            .init(slot: $0.offset, player: $0.element, status: $0.element == nil ? .matching : .active, outcome: .none)
        }, currentTurnSlot: currentTurnSlot, status: .open, data: data,
           revision: UUID().uuidString, maximumDataSize: maximumDataSize, localPlayerID: nil)
        return id
    }

    func list(player: NetworkPeerID) -> [GameCenterTurnBasedMatch] {
        records.values.filter { $0.participants.contains { $0.player?.id == player } }
            .map { $0.forPlayer(player) }.sorted { $0.id < $1.id }
    }

    func load(id: String, player: NetworkPeerID) throws -> GameCenterTurnBasedMatch {
        guard let record = records[id], record.participants.contains(where: { $0.player?.id == player }) else {
            throw GameCenterServiceError.notFound
        }
        return record.forPlayer(player)
    }

    // No suspension between the revision check and commit: preview preconditions
    // are atomic across all services sharing this main-actor store.
    func update(_ expected: GameCenterTurnBasedMatch, player: NetworkPeerID,
                change: GameCenterTurnBasedChange) throws -> GameCenterTurnBasedMatch {
        let current = try load(id: expected.id, player: player)
        try validateTurnBasedChange(change, expected: expected, current: current)
        var participants = current.participants
        var slot = current.currentTurnSlot
        var status = current.status
        switch change {
        case .save: break
        case .endTurn(_, let next): slot = next[0]
        case .finish(_, let outcomes):
            participants = participants.map { .init(slot: $0.slot, player: $0.player, status: .done, outcome: outcomes[$0.slot]!) }
            slot = nil; status = .ended
        case .forfeit(let next):
            participants = participants.map {
                $0.player?.id == player ? .init(slot: $0.slot, player: $0.player, status: .done, outcome: .quit) : $0
            }
            if current.localCanAct { slot = next[0] }
        }
        let updated = GameCenterTurnBasedMatch(id: current.id, participants: participants,
            currentTurnSlot: slot, status: status, data: change.data ?? current.data,
            revision: UUID().uuidString, maximumDataSize: maximumDataSize, localPlayerID: player)
        records[current.id] = updated
        return updated
    }
}

private func validateTurnBasedChange(_ change: GameCenterTurnBasedChange,
                                    expected: GameCenterTurnBasedMatch, current: GameCenterTurnBasedMatch) throws {
    guard current.revision == expected.revision else { throw GameCenterServiceError.staleMatch }
    guard current.status != .ended else { throw GameCenterServiceError.matchEnded }
    guard current.status == .open || current.status == .matching else { throw GameCenterServiceError.invalidValue }
    guard let local = current.participants.first(where: { $0.player?.id == current.localPlayerID }),
          local.status == .active, local.outcome == .none else { throw GameCenterServiceError.notYourTurn }
    if let data = change.data, data.count > current.maximumDataSize { throw GameCenterServiceError.capacityExceeded }
    func validateNext(_ slots: [Int]) throws {
        guard !slots.isEmpty, Set(slots).count == slots.count,
              slots.allSatisfy({ index in current.participants.contains {
                  $0.slot == index && $0.slot != local.slot && $0.canReceiveTurn
              } }) else { throw GameCenterServiceError.invalidValue }
    }
    switch change {
    case .forfeit(let slots):
        if current.localCanAct {
            guard current.data.count <= current.maximumDataSize else { throw GameCenterServiceError.capacityExceeded }
            try validateNext(slots)
        }
        else if !slots.isEmpty { throw GameCenterServiceError.invalidValue }
    case .save:
        guard current.localCanAct else { throw GameCenterServiceError.notYourTurn }
    case .endTurn(_, let slots):
        guard current.localCanAct else { throw GameCenterServiceError.notYourTurn }
        try validateNext(slots)
    case .finish(_, let outcomes):
        guard current.localCanAct else { throw GameCenterServiceError.notYourTurn }
        guard Set(outcomes.keys) == Set(current.participants.map(\.slot)),
              outcomes.values.allSatisfy({ $0 != .none && $0 != .unknown }),
              current.participants.allSatisfy({ $0.outcome == .none || outcomes[$0.slot] == $0.outcome }) else {
            throw GameCenterServiceError.invalidValue
        }
    }
}

/// Typed saved matches. Constructing the service has no Game Center effects.
/// Operations/start register an event listener, but never authenticate. Apple
/// persists only the encoded state bytes. Refresh previews explicitly with load.
@MainActor @Observable
public final class GameCenterTurnBasedMatches {
    public private(set) var matches: [GameCenterTurnBasedMatch] = []
    public private(set) var selectedMatch: GameCenterTurnBasedMatch?
    public private(set) var lastError: GameCenterServiceError?
    public private(set) var isLoading = false

    @ObservationIgnored private let context: GameCenterServiceContext
    @ObservationIgnored private let previewStore: InMemoryTurnBasedStore?
    @ObservationIgnored private let driver: GameCenterTurnBasedDriver?
    @ObservationIgnored private var listenerLease: UUID?
    @ObservationIgnored private var listenerOperation: GameCenterServiceContext.Operation?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var pendingEvents: [String: Bool] = [:]
    @ObservationIgnored private var pendingEventOrder: [String] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    public convenience init(mode: GameCenterServicesMode = .live, previewStore: InMemoryTurnBasedStore? = nil) {
        self.init(context: GameCenterServiceContext(mode: mode), previewStore: previewStore)
    }

    convenience init(context: GameCenterServiceContext) { self.init(context: context, previewStore: nil) }

    private init(context: GameCenterServiceContext, previewStore: InMemoryTurnBasedStore?) {
        self.context = context
        self.previewStore = context.isPreview ? (previewStore ?? InMemoryTurnBasedStore()) : nil
        driver = context.isPreview ? nil : .live()
    }

    /// Native callback seam; preview identity avoids system sign-in in tests.
    init(context: GameCenterServiceContext, driver: GameCenterTurnBasedDriver) {
        self.context = context; self.driver = driver; previewStore = nil
    }

    isolated deinit { reset() }

    /// Begin receiving native turn/save/end events without loading an inbox.
    public func start() throws {
        let operation = try beginOperation()
        activateListener(operation)
        try context.validate(operation)
    }

    @discardableResult
    public func list() async throws -> [GameCenterTurnBasedMatch] {
        try await perform { operation, check in
            let values: [GameCenterTurnBasedMatch]
            if let store = self.previewStore { values = store.list(player: operation.player.id) }
            else { values = try await self.driver!.list(check).map { $0.snapshot.forPlayer(operation.player.id) } }
            try check()
            self.matches = values.sorted { $0.id < $1.id }
            if let selected = self.selectedMatch { self.selectedMatch = values.first { $0.id == selected.id } }
            return self.matches
        }
    }

    @discardableResult
    public func load(id: String) async throws -> GameCenterTurnBasedMatch {
        try await load(id: id, selectsMatch: true)
    }

    private func load(id: String, selectsMatch: Bool) async throws -> GameCenterTurnBasedMatch {
        try validateGameCenterIdentifier(id)
        return try await perform { operation, check in
            let snapshot = try await self.read(id: id, operation: operation, check: check).snapshot
            try check()
            self.publish(snapshot, selectsMatch: selectsMatch)
            return snapshot
        }
    }

    /// Programmatic native matchmaking. The preview creates pending slots;
    /// use a shared store's createMatch to seed multiple known preview players.
    @discardableResult
    public func findMatch(_ request: GameCenterMatchRequest = .init()) async throws -> GameCenterTurnBasedMatch {
        try request.validate(maximumPlayers: GKMatchRequest.maxPlayersAllowedForMatch(of: .turnBased))
        return try await perform { operation, check in
            let snapshot: GameCenterTurnBasedMatch
            if let store = self.previewStore {
                let players = [Optional(operation.player)] + Array<NetworkPeer?>(repeating: nil, count: request.maxPlayers - 1)
                let id = try store.createMatch(participants: players)
                snapshot = try store.load(id: id, player: operation.player.id)
            } else {
                snapshot = try await self.driver!.find(request, check).snapshot.forPlayer(operation.player.id)
            }
            try check()
            self.publish(snapshot)
            return snapshot
        }
    }

    /// Version is the caller's state schema, not an ECS/network wire schema.
    /// Empty, foreign, corrupt, and differently-versioned payloads are rejected.
    public func state<State: Decodable>(of match: GameCenterTurnBasedMatch, as type: State.Type,
                                       version: Int = 1) throws -> State {
        guard version > 0 else { throw GameCenterServiceError.invalidValue }
        guard match.data.count <= match.maximumDataSize else { throw GameCenterServiceError.capacityExceeded }
        do {
            let envelope = try JSONDecoder().decode(TurnBasedEnvelope.self, from: match.data)
            guard envelope.format == "SpriteUI.turnBased", envelope.version == version else {
                throw GameCenterServiceError.invalidData
            }
            return try JSONDecoder().decode(type, from: envelope.state)
        } catch { throw GameCenterServiceError.invalidData }
    }

    @discardableResult
    public func save<State: Encodable>(_ state: State, in match: GameCenterTurnBasedMatch,
                                      version: Int = 1) async throws -> GameCenterTurnBasedMatch {
        try await update(match, change: .save(encode(state, version: version)))
    }

    /// Slots are ordered fallbacks for GameKit invitations/timeouts. Preview
    /// passes to the first slot. Pending slots are legal; self/done slots aren't.
    @discardableResult
    public func endTurn<State: Encodable>(_ state: State, in match: GameCenterTurnBasedMatch,
                                         nextParticipantSlots: [Int], version: Int = 1) async throws -> GameCenterTurnBasedMatch {
        try await update(match, change: .endTurn(encode(state, version: version), nextParticipantSlots))
    }

    /// Supply a terminal outcome for every slot, preserving existing outcomes.
    @discardableResult
    public func finish<State: Encodable>(_ state: State, in match: GameCenterTurnBasedMatch,
                                        outcomes: [Int: GameCenterTurnBasedOutcome], version: Int = 1) async throws -> GameCenterTurnBasedMatch {
        try await update(match, change: .finish(encode(state, version: version), outcomes))
    }

    /// In turn, supply next slots. Out of turn, omit them; payload is unchanged.
    @discardableResult
    public func forfeit(_ match: GameCenterTurnBasedMatch,
                        nextParticipantSlots: [Int] = []) async throws -> GameCenterTurnBasedMatch {
        try await update(match, change: .forfeit(nextParticipantSlots))
    }

    private func encode<State: Encodable>(_ state: State, version: Int) throws -> Data {
        guard version > 0 else { throw GameCenterServiceError.invalidValue }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(TurnBasedEnvelope(format: "SpriteUI.turnBased", version: version,
                mutation: UUID(), state: encoder.encode(state)))
        } catch { throw GameCenterServiceError.invalidData }
    }

    private func update(_ match: GameCenterTurnBasedMatch, change: GameCenterTurnBasedChange) async throws -> GameCenterTurnBasedMatch {
        try await perform { operation, check in
            let current = try await self.read(id: match.id, operation: operation, check: check)
            try check()
            try validateTurnBasedChange(change, expected: match, current: current.snapshot)
            let result: GameCenterTurnBasedMatch
            if let store = self.previewStore {
                result = try store.update(match, player: operation.player.id, change: change)
            } else {
                // The loaded native object belongs only to this operation.
                try await self.driver!.write(current, change, check)
                try check()
                result = try await self.read(id: match.id, operation: operation, check: check).snapshot
            }
            try check()
            self.publish(result)
            return result
        }
    }

    private func read(id: String, operation: GameCenterServiceContext.Operation,
                      check: @escaping GameCenterTurnBasedDriver.Check) async throws -> GameCenterTurnBasedLoaded {
        try check()
        if let store = previewStore { return .init(snapshot: try store.load(id: id, player: operation.player.id)) }
        let loaded = try await driver!.load(id, check)
        try check()
        return .init(snapshot: loaded.snapshot.forPlayer(operation.player.id), native: loaded.native)
    }

    private func perform<Value>(_ body: (GameCenterServiceContext.Operation, @escaping GameCenterTurnBasedDriver.Check) async throws -> Value) async throws -> Value {
        guard !isLoading else { throw GameCenterServiceError.operationInProgress }
        let operation = try beginOperation()
        let token = epoch
        isLoading = true
        defer { isLoading = false; scheduleRefresh() }
        let check: GameCenterTurnBasedDriver.Check = { [self] in
            guard token == epoch else { throw GameCenterServiceError.cancelled }
            try context.validate(operation)
        }
        do {
            activateListener(operation)
            try check()
            let value = try await body(operation, check)
            try check()
            lastError = nil
            return value
        } catch {
            let failure = gameCenterServiceFailure(error)
            if token == epoch {
                // Never retain snapshots of a previous account.
                if (try? context.validate(operation)) == nil {
                    matches = []; selectedMatch = nil
                    retireListener()
                }
                lastError = failure
            }
            throw failure
        }
    }

    private func beginOperation() throws -> GameCenterServiceContext.Operation {
        do { return try context.begin() }
        catch {
            let failure = gameCenterServiceFailure(error)
            if failure == .notAuthenticated || failure == .accountChanged {
                retireListener(); matches = []; selectedMatch = nil
            }
            lastError = failure
            throw failure
        }
    }

    private func publish(_ snapshot: GameCenterTurnBasedMatch, selectsMatch: Bool = true) {
        matches.removeAll { $0.id == snapshot.id }; matches.append(snapshot)
        matches.sort { $0.id < $1.id }
        if selectsMatch || selectedMatch?.id == snapshot.id { selectedMatch = snapshot }
    }

    private func activateListener(_ operation: GameCenterServiceContext.Operation) {
        guard let driver else { return }
        if let previous = listenerOperation,
           previous.player.id != operation.player.id || previous.generation != operation.generation {
            retireListener(); matches = []; selectedMatch = nil
        }
        guard listenerLease == nil else { return }
        let lease = UUID(), token = epoch
        listenerOperation = operation
        listenerLease = lease
        driver.start(lease) { [weak self] id, didBecomeActive in
            guard let self, self.epoch == token, self.listenerLease == lease,
                  (try? self.context.validate(operation)) != nil else { return }
            if self.pendingEvents[id] == nil {
                guard self.pendingEventOrder.count < 128 else { self.lastError = .capacityExceeded; return }
                self.pendingEventOrder.append(id)
            } else if didBecomeActive {
                // Coalescing a refresh must not reorder activation intent:
                // A(background), B(active), A(active) must finish on A.
                self.pendingEventOrder.removeAll { $0 == id }
                self.pendingEventOrder.append(id)
            }
            self.pendingEvents[id] = (self.pendingEvents[id] ?? false) || didBecomeActive
            self.scheduleRefresh()
        }
    }

    private func scheduleRefresh() {
        guard !isLoading, refreshTask == nil, !pendingEvents.isEmpty else { return }
        let token = epoch
        refreshTask = Task { [weak self] in
            // Coalesce callbacks before reading; never publish callback objects.
            await Task.yield()
            guard let self, self.epoch == token, !Task.isCancelled else { return }
            while !self.pendingEventOrder.isEmpty, !self.isLoading, self.epoch == token {
                let id = self.pendingEventOrder.removeFirst()
                let selectsMatch = self.pendingEvents.removeValue(forKey: id) ?? false
                do {
                    _ = try await self.load(id: id, selectsMatch: selectsMatch)
                    guard self.epoch == token else { return }
                } catch { /* load records the failure; explicit retry stays available */ }
            }
            guard self.epoch == token else { return }
            self.refreshTask = nil
            self.scheduleRefresh()
        }
    }

    private func retireListener() {
        if let listenerLease { driver?.stop(listenerLease) }
        listenerLease = nil; listenerOperation = nil; pendingEvents = [:]; pendingEventOrder = []
    }

    func reset() {
        epoch = UUID()
        refreshTask?.cancel(); refreshTask = nil
        retireListener()
        matches = []; selectedMatch = nil; lastError = nil
        // A submitted GameKit write cannot be undone. Keep the operation gate
        // until its callback returns, even after reset/cancellation.
    }
}

struct GameCenterTurnBasedLoaded: Sendable {
    let snapshot: GameCenterTurnBasedMatch
    var native: GameCenterCallback<GKTurnBasedMatch>? = nil
}

/// Value-based seam also exercises late callbacks/listener lifetime without GC.
@MainActor
struct GameCenterTurnBasedDriver {
    typealias Check = @MainActor () throws -> Void
    var list: (@escaping Check) async throws -> [GameCenterTurnBasedLoaded]
    var load: (String, @escaping Check) async throws -> GameCenterTurnBasedLoaded
    var find: (GameCenterMatchRequest, @escaping Check) async throws -> GameCenterTurnBasedLoaded
    var write: (GameCenterTurnBasedLoaded, GameCenterTurnBasedChange, @escaping Check) async throws -> Void
    var start: (UUID, @escaping @MainActor @Sendable (String, Bool) -> Void) -> Void
    var stop: (UUID) -> Void

    static func live() -> Self {
        let listeners = TurnBasedListenerRegistry()
        return Self(list: { check in
            let matches: GameCenterCallback<[GKTurnBasedMatch]> = try await turnBasedCallback(check: check) { done in
                GKTurnBasedMatch.loadMatches { matches, error in
                    done(error.map { .failure(gameCenterServiceFailure($0)) } ?? .success(.init(matches ?? [])))
                }
            }
            var values: [GameCenterTurnBasedLoaded] = []
            for match in matches.value { values.append(try await loadedNativeMatch(match, check: check)) }
            return values
        }, load: { id, check in
            let match: GameCenterCallback<GKTurnBasedMatch> = try await turnBasedCallback(check: check) { done in
                GKTurnBasedMatch.load(withID: id) { match, error in
                    if let error { done(.failure(gameCenterServiceFailure(error))) }
                    else if let match { done(.success(.init(match))) }
                    else { done(.failure(.notFound)) }
                }
            }
            return try await loadedNativeMatch(match.value, check: check)
        }, find: { request, check in
            let native = GKMatchRequest()
            native.minPlayers = request.minPlayers; native.maxPlayers = request.maxPlayers
            native.defaultNumberOfPlayers = request.maxPlayers; native.playerGroup = request.playerGroup
            let match: GameCenterCallback<GKTurnBasedMatch> = try await turnBasedCallback(check: check) { done in
                GKTurnBasedMatch.find(for: native) { match, error in
                    if let error { done(.failure(gameCenterServiceFailure(error))) }
                    else if let match { done(.success(.init(match))) }
                    else { done(.failure(.notFound)) }
                }
            }
            return try await loadedNativeMatch(match.value, check: check)
        }, write: { loaded, change, check in
            try check()
            guard let match = loaded.native?.value else { throw GameCenterServiceError.notFound }
            guard (match.completedExchanges ?? []).isEmpty else { throw GameCenterServiceError.invalidValue }
            let participants = match.participants
            let _: Bool = try await turnBasedCallback(check: check) { done in
                let completion: @Sendable ((any Error)?) -> Void = { error in
                    done(error.map { .failure(gameCenterServiceFailure($0)) } ?? .success(true))
                }
                switch change {
                case .save(let data): match.saveCurrentTurn(withMatch: data, completionHandler: completion)
                case .endTurn(let data, let slots):
                    match.endTurn(withNextParticipants: slots.map { participants[$0] },
                                  turnTimeout: GKTurnTimeoutDefault, match: data, completionHandler: completion)
                case .finish(let data, let outcomes):
                    for (slot, outcome) in outcomes { participants[slot].matchOutcome = .init(rawValue: outcome.rawValue)! }
                    match.endMatchInTurn(withMatch: data, completionHandler: completion)
                case .forfeit(let slots):
                    if loaded.snapshot.localCanAct {
                        match.participantQuitInTurn(with: .quit, nextParticipants: slots.map { participants[$0] },
                            turnTimeout: GKTurnTimeoutDefault, match: loaded.snapshot.data, completionHandler: completion)
                    } else { match.participantQuitOutOfTurn(with: .quit, withCompletionHandler: completion) }
                }
            }
        }, start: { lease, receive in listeners.start(lease, receive: receive) },
           stop: { lease in listeners.stop(lease) })
    }
}

/// One-shot delivery tolerates duplicated SDK callbacks. Cancellation is checked
/// before submission and on completion; in-flight native writes stay serialized.
@MainActor
final class GameCenterTurnBasedCallback<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, any Error>?
    init(_ continuation: CheckedContinuation<Value, any Error>) { self.continuation = continuation }
    func resolve(_ result: Result<Value, GameCenterServiceError>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result.mapError { $0 as any Error })
    }
}

@MainActor
private func turnBasedCallback<Value: Sendable>(check: GameCenterTurnBasedDriver.Check,
    start: (@escaping @Sendable (Result<Value, GameCenterServiceError>) -> Void) -> Void) async throws -> Value {
    try check()
    let value: Value
    do {
        value = try await withCheckedThrowingContinuation { continuation in
            let callback = GameCenterTurnBasedCallback(continuation)
            start { result in Task { @MainActor in callback.resolve(result) } }
        }
    } catch { try check(); throw error }
    try check()
    return value
}

@MainActor
private func loadedNativeMatch(_ match: GKTurnBasedMatch,
                               check: GameCenterTurnBasedDriver.Check) async throws -> GameCenterTurnBasedLoaded {
    let data: Data = try await turnBasedCallback(check: check) { done in
        match.loadMatchData { data, error in
            done(error.map { .failure(gameCenterServiceFailure($0)) } ?? .success(data ?? Data()))
        }
    }
    let participants = match.participants.enumerated().map { slot, participant in
        GameCenterTurnBasedParticipant(slot: slot, player: participant.player.map {
            NetworkPeer(id: .init(rawValue: $0.gamePlayerID), displayName: $0.displayName)
        }, status: [.unknown, .invited, .declined, .matching, .active, .done][safe: participant.status.rawValue] ?? .unknown,
           outcome: GameCenterTurnBasedOutcome(rawValue: participant.matchOutcome.rawValue) ?? .unknown)
    }
    let slot = match.currentParticipant.flatMap { current in match.participants.firstIndex { $0 === current } }
    let status: GameCenterTurnBasedStatus
    switch match.status {
    case .open: status = .open
    case .ended: status = .ended
    case .matching: status = .matching
    default: status = .unknown
    }
    // Include payload, turn, roster, outcomes, deadlines and exchanges. The
    // envelope mutation UUID makes identical typed saves produce new revisions.
    struct Fingerprint: Encodable {
        let id: String
        let participants: [GameCenterTurnBasedParticipant]
        let slot: Int?
        let status: GameCenterTurnBasedStatus
        let data: Data
        let dates: [Date?]
        let exchanges: [String]
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let fingerprint = try encoder.encode(Fingerprint(id: match.matchID, participants: participants, slot: slot,
        status: status, data: data, dates: match.participants.flatMap { [$0.lastTurnDate, $0.timeoutDate] },
        exchanges: (match.exchanges ?? []).map { "\($0.exchangeID):\($0.status.rawValue)" }.sorted()))
    let revision = SHA256.hash(data: fingerprint).map { String(format: "%02x", $0) }.joined()
    return .init(snapshot: .init(id: match.matchID, participants: participants, currentTurnSlot: slot,
        status: status, data: data, revision: revision, maximumDataSize: match.matchDataMaximumSize, localPlayerID: nil), native: .init(match))
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

@MainActor
private final class TurnBasedListenerRegistry {
    private var listeners: [UUID: TurnBasedListener] = [:]
    func start(_ lease: UUID, receive: @escaping @MainActor @Sendable (String, Bool) -> Void) {
        guard listeners[lease] == nil else { return }
        let listener = TurnBasedListener(receive: receive)
        listeners[lease] = listener
        GKLocalPlayer.local.register(listener)
    }
    func stop(_ lease: UUID) {
        if let listener = listeners.removeValue(forKey: lease) { GKLocalPlayer.local.unregisterListener(listener) }
    }
}

private final class TurnBasedListener: NSObject, GKLocalPlayerListener, Sendable {
    let receive: @MainActor @Sendable (String, Bool) -> Void
    init(receive: @escaping @MainActor @Sendable (String, Bool) -> Void) { self.receive = receive }
    func player(_ player: GKPlayer, receivedTurnEventFor match: GKTurnBasedMatch, didBecomeActive: Bool) {
        let id = match.matchID, receive = receive
        Task { @MainActor in receive(id, didBecomeActive) }
    }
    func player(_ player: GKPlayer, matchEnded match: GKTurnBasedMatch) {
        let id = match.matchID, receive = receive
        Task { @MainActor in receive(id, false) }
    }
}
