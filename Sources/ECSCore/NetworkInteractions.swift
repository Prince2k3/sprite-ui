import Foundation

/// Bounded admission, history, and pending-feedback limits for one owned interaction stream.
public struct NetworkInteractionConfiguration: Hashable, Sendable {
    /// Maximum host-time age of an issued view, clamped to 0.05...2 seconds.
    public let maximumRewind: TimeInterval
    /// Minimum host-time interval between accepted actions, including misses.
    public let cooldown: TimeInterval
    /// Maximum retained snapshots, issued views, and cached results, clamped to 2...256.
    public let capacity: Int
    /// Maximum unresolved local actions, clamped to 1...64.
    public let maximumPendingActions: Int
    /// Creates bounded interaction settings. The host owns the clock and policy.
    public init(maximumRewind: TimeInterval = 0.5, cooldown: TimeInterval = 0.2,
                capacity: Int = 128, maximumPendingActions: Int = 16) {
        self.maximumRewind = maximumRewind.isFinite ? min(2, max(0.05, maximumRewind)) : 0.5
        self.cooldown = cooldown.isFinite ? min(10, max(0, cooldown)) : 0.2
        self.capacity = min(256, max(2, capacity))
        self.maximumPendingActions = min(64, max(1, maximumPendingActions))
    }
}

/// Admission errors that cannot authorize an action or replace a stream.
public enum NetworkInteractionError: Error, Equatable, Sendable {
    case wrongOwner, wrongStream, invalidSequence, invalidTime, missingHistory, capacityExceeded, invalidResult
}

/// A host-issued capability to select one exact historical sample, not arbitrary client time.
public struct NetworkInteractionViewReference: Hashable, Codable, Sendable {
    /// The host-created entity/owner epoch.
    public let stream: NetworkPredictionStream
    /// An unpredictable identifier issued to this stream's owner.
    public let id: UUID
    /// The exact host history sample; changing it invalidates the reference.
    public let tick: UInt64
    /// Creates inert metadata. Only a reference actually issued by the authority can be used.
    public init(stream: NetworkPredictionStream, id: UUID = UUID(), tick: UInt64) {
        self.stream = stream; self.id = id; self.tick = tick
    }
}

/// A narrow host-selected view that an application may display and use for aiming.
public struct NetworkInteractionView<State: Codable & Sendable>: Codable, Sendable {
    /// The exact sample identifier to return with an action.
    public let reference: NetworkInteractionViewReference
    /// Value-only presentation/query data; the host retains its own trusted copy.
    public let state: State
    /// Creates a view without granting authority to its recipient.
    public init(reference: NetworkInteractionViewReference, state: State) { self.reference = reference; self.state = state }
}

/// One sequenced intent referencing an issued view, without client position or time authority.
public struct NetworkInteractionCommand<Intent: Codable & Sendable>: Codable, Sendable {
    /// The issued sample and ownership incarnation.
    public let view: NetworkInteractionViewReference
    /// A positive action index within this incarnation.
    public let sequence: UInt64
    /// Narrow intent validated by host game rules.
    public let intent: Intent
    /// Creates inert command data; the receiver must still authenticate and validate it.
    public init(view: NetworkInteractionViewReference, sequence: UInt64, intent: Intent) {
        self.view = view; self.sequence = sequence; self.intent = intent
    }
}

/// A completed refusal. It consumes the action index but grants no gameplay effect.
public enum NetworkInteractionRejection: String, Error, Codable, Sendable {
    case unissuedView, expiredView, cooldown, invalidIntent, targetUnavailable, staleSequence
}

/// An accepted query outcome or explicit authoritative refusal.
public enum NetworkInteractionResolution<Outcome: Codable & Sendable>: Codable, Sendable {
    case accepted(Outcome)
    case rejected(NetworkInteractionRejection)
}

/// A final host receipt. Applications apply effects once, after this receipt is committed.
public struct NetworkInteractionResult<Outcome: Codable & Sendable>: Codable, Sendable {
    /// The ownership incarnation that resolved this action.
    public let stream: NetworkPredictionStream
    /// The action this receipt completes.
    public let sequence: UInt64
    /// Host-validated outcome or refusal.
    public let resolution: NetworkInteractionResolution<Outcome>
    /// Creates an inert receipt; a client accepts it only from its authenticated current host.
    public init(stream: NetworkPredictionStream, sequence: UInt64, resolution: NetworkInteractionResolution<Outcome>) {
        self.stream = stream; self.sequence = sequence; self.resolution = resolution
    }
}

/// Whether resolving a command produced a new receipt or returned a cached duplicate.
public struct NetworkInteractionDecision<Outcome: Codable & Sendable>: Sendable {
    /// The authoritative receipt, safe to resend to its owner.
    public let result: NetworkInteractionResult<Outcome>
    /// Only a new receipt may trigger gameplay effects or confirmation events.
    public let isNew: Bool
}

/// Host-only bounded history, issued-view validation, cooldowns, and duplicate-safe action receipts.
/// Use value-semantic State/Intent/Outcome and pure validation/query closures. This is not a durable reward ledger.
public struct NetworkInteractionAuthority<State: Codable & Sendable, Intent: Codable & Sendable, Outcome: Codable & Sendable>: Sendable {
    /// The host-created owner incarnation; rebuild after recovery or ownership transfer.
    public let stream: NetworkPredictionStream
    /// The immutable host admission policy.
    public let configuration: NetworkInteractionConfiguration
    /// Number of retained inert snapshots.
    public var historyCount: Int { history.count }
    /// Number of bounded issued references.
    public var issuedViewCount: Int { views.count }
    /// Number of cached receipts; older action indices remain retired after eviction.
    public var resultCount: Int { results.count }
    private struct Sample: Sendable { let tick: UInt64; let time: TimeInterval; let state: State }
    private var history: [Sample] = []
    private var views: [NetworkInteractionViewReference] = []
    private var results: [NetworkInteractionResult<Outcome>] = []
    private var tick: UInt64 = 0
    private var highestSequence: UInt64 = 0
    private var lastAccepted: TimeInterval?
    private var lastOperationTime: TimeInterval = 0
    /// Creates an empty authority; record a trusted state before issuing a view.
    public init(stream: NetworkPredictionStream, configuration: NetworkInteractionConfiguration = .init()) {
        self.stream = stream; self.configuration = configuration
    }
    /// Records one validated host state at a strictly increasing nonnegative host time.
    /// Failed validation leaves history untouched. No world or native physics state is rewound.
    public mutating func record(_ state: State, at time: TimeInterval,
                                validate: @Sendable (State) throws -> Void = { _ in }) throws {
        guard time.isFinite, time >= lastOperationTime, time >= 0,
              history.last.map({ time > $0.time }) ?? true else { throw NetworkInteractionError.invalidTime }
        guard tick < UInt64.max else { throw NetworkInteractionError.capacityExceeded }
        try validate(state)
        tick += 1; lastOperationTime = time; history.append(.init(tick: tick, time: time, state: state))
        history = history.filter { time - $0.time <= configuration.maximumRewind }
        if history.count > configuration.capacity { history.removeFirst(history.count - configuration.capacity) }
        let retained = Set(history.map(\.tick)); views.removeAll { !retained.contains($0.tick) }
    }
    /// Issues the latest trusted snapshot and remembers its exact reference for this owner.
    public mutating func issueView() throws -> NetworkInteractionView<State> {
        guard let sample = history.last else { throw NetworkInteractionError.missingHistory }
        let reference = NetworkInteractionViewReference(stream: stream, tick: sample.tick)
        views.append(reference)
        if views.count > configuration.capacity { views.removeFirst(views.count - configuration.capacity) }
        return .init(reference: reference, state: sample.state)
    }
    /// Resolves once at host receipt time. Duplicates return their original receipt without evaluating again.
    /// The query must be pure; apply damage/rewards only when isNew and resolution is accepted.
    public mutating func resolve(_ command: NetworkInteractionCommand<Intent>, from sender: NetworkPeerID, at time: TimeInterval,
                                 evaluate: (State, Intent) throws -> Outcome) throws -> NetworkInteractionDecision<Outcome> {
        guard sender == stream.owner else { throw NetworkInteractionError.wrongOwner }
        guard command.view.stream == stream else { throw NetworkInteractionError.wrongStream }
        guard time.isFinite, time >= lastOperationTime else { throw NetworkInteractionError.invalidTime }
        guard command.sequence > 0 else { throw NetworkInteractionError.invalidSequence }
        if let old = results.first(where: { $0.sequence == command.sequence }) { return .init(result: old, isNew: false) }
        guard command.sequence > highestSequence else {
            return .init(result: .init(stream: stream, sequence: command.sequence, resolution: .rejected(.staleSequence)), isNew: false)
        }
        guard command.sequence - highestSequence <= UInt64(configuration.capacity) else { throw NetworkInteractionError.invalidSequence }
        let resolution: NetworkInteractionResolution<Outcome>
        if !views.contains(command.view) { resolution = .rejected(.unissuedView) }
        else if let sample = history.first(where: { $0.tick == command.view.tick }), time - sample.time <= configuration.maximumRewind {
            if let lastAccepted, time - lastAccepted + 1e-9 < configuration.cooldown { resolution = .rejected(.cooldown) }
            else {
                do { resolution = .accepted(try evaluate(sample.state, command.intent)) }
                catch let rejection as NetworkInteractionRejection { resolution = .rejected(rejection) }
                catch { resolution = .rejected(.invalidIntent) }
            }
        } else { resolution = .rejected(.expiredView) }
        let result = NetworkInteractionResult(stream: stream, sequence: command.sequence, resolution: resolution)
        highestSequence = command.sequence; lastOperationTime = time
        if case .accepted = resolution { lastAccepted = time }
        results.append(result)
        if results.count > configuration.capacity { results.removeFirst(results.count - configuration.capacity) }
        return .init(result: result, isNew: true)
    }
}

/// Bounded speculative action bookkeeping; confirmation never replays predicted effects.
public struct NetworkInteractionClient<State: Codable & Sendable, Intent: Codable & Sendable, Outcome: Codable & Sendable>: Sendable {
    /// Latest host-issued view. Older sample ticks cannot replace it.
    public private(set) var view: NetworkInteractionView<State>
    /// Number of unresolved actions.
    public var pendingActionCount: Int { pending.count }
    private let configuration: NetworkInteractionConfiguration
    private var issued: UInt64 = 0
    private var pending: Set<UInt64> = []
    /// Begins from an authenticated, application-validated host view.
    public init(view: NetworkInteractionView<State>, configuration: NetworkInteractionConfiguration = .init()) {
        self.view = view; self.configuration = configuration
    }
    /// Accepts a newer view in the same epoch. Validate its state before calling.
    @discardableResult public mutating func receive(_ view: NetworkInteractionView<State>) throws -> Bool {
        guard view.reference.stream == self.view.reference.stream else { throw NetworkInteractionError.wrongStream }
        guard view.reference.tick > self.view.reference.tick else { return false }
        self.view = view; return true
    }
    /// Reserves one bounded local action; its feedback may be displayed exactly once by the caller.
    public mutating func predict(_ intent: Intent) throws -> NetworkInteractionCommand<Intent> {
        guard pending.count < configuration.maximumPendingActions, issued < UInt64.max else { throw NetworkInteractionError.capacityExceeded }
        issued += 1; pending.insert(issued)
        return .init(view: view.reference, sequence: issued, intent: intent)
    }
    /// Completes a pending action once. Duplicate/retired results return false without effects.
    @discardableResult public mutating func receive(_ result: NetworkInteractionResult<Outcome>) throws -> Bool {
        guard result.stream == view.reference.stream else { throw NetworkInteractionError.wrongStream }
        guard result.sequence > 0, result.sequence <= issued else { throw NetworkInteractionError.invalidResult }
        return pending.remove(result.sequence) != nil
    }
}
