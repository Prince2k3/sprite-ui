import Foundation

/// Validation and bounded-history failures. Prediction never changes network authority.
public enum NetworkPredictionError: Error, Equatable, Sendable {
    case invalidConfiguration, invalidSequence, invalidAcknowledgment, wrongStream, wrongOwner, capacityExceeded
}

/// Fixed simulation duration and bounded client/host input history.
public struct NetworkPredictionConfiguration: Hashable, Codable, Sendable {
    /// The shared host/client duration. Decode and construction clamp it to 1/240...1/10 second.
    public let stepDuration: TimeInterval
    /// Maximum pending inputs and maximum sequence lead, clamped to 1...512.
    public let maximumPendingInputs: Int
    /// Creates bounded prediction settings; they must agree on stepDuration on all participants.
    public init(stepDuration: TimeInterval = 1.0 / 60, maximumPendingInputs: Int = 256) {
        self.stepDuration = stepDuration.isFinite ? min(0.1, max(1.0 / 240, stepDuration)) : 1.0 / 60
        self.maximumPendingInputs = min(512, max(1, maximumPendingInputs))
    }
    private enum CodingKeys: CodingKey { case stepDuration, maximumPendingInputs }
    /// Decodes through the same bounded construction policy.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(stepDuration: try values.decode(TimeInterval.self, forKey: .stepDuration),
                  maximumPendingInputs: try values.decode(Int.self, forKey: .maximumPendingInputs))
    }
}

/// A host-created ownership incarnation. Create a fresh epoch after rejoin, recovery, or ownership transfer.
public struct NetworkPredictionStream: Hashable, Codable, Sendable {
    /// The authoritative entity's stable network identity.
    public let entity: NetworkEntityID
    /// The transport-authenticated player allowed to submit this stream's inputs.
    public let owner: NetworkPeerID
    /// A fresh, host-created epoch, not an identifier to persist in checkpoints.
    public let epoch: UUID
    /// Creates a stream identity; the host chooses and communicates it before client prediction begins.
    public init(entity: NetworkEntityID, owner: NetworkPeerID, epoch: UUID = UUID()) {
        self.entity = entity; self.owner = owner; self.epoch = epoch
    }
}

/// One ordered fixed-step input. It carries no client-supplied time delta.
public struct NetworkInputCommand<Input: Codable & Sendable>: Codable, Sendable {
    /// The host-authorized ownership incarnation.
    public let stream: NetworkPredictionStream
    /// A positive input index within that incarnation.
    public let sequence: UInt64
    /// Narrow application-owned command data, validated by both peers.
    public let input: Input
    /// Creates an inert packet; receiving code must still validate ownership, sequence, and input.
    public init(stream: NetworkPredictionStream, sequence: UInt64, input: Input) {
        self.stream = stream; self.sequence = sequence; self.input = input
    }
}

/// A complete host result and acknowledgment. Newer revisions replace older results without replaying acknowledged inputs.
public struct NetworkAuthoritativeState<State: Codable & Sendable>: Codable, Sendable {
    /// The ownership incarnation this state belongs to.
    public let stream: NetworkPredictionStream
    /// A monotonic host revision, including explicit corrections.
    public let revision: UInt64
    /// The latest input actually consumed by an authoritative fixed tick.
    public let acknowledgedInput: UInt64
    /// The full narrow application state, not a world snapshot.
    public let state: State
    /// Creates an inert host result. Transport identity and game validation remain mandatory.
    public init(stream: NetworkPredictionStream, revision: UInt64, acknowledgedInput: UInt64, state: State) {
        self.stream = stream; self.revision = revision; self.acknowledgedInput = acknowledgedInput; self.state = state
    }
}

/// Diagnostics from one reconciliation. A stale result performs no replay or mutation.
public struct NetworkReconciliation: Hashable, Sendable {
    /// Whether a newer authoritative state was applied.
    public let wasApplied: Bool
    /// Number of inputs removed by the acknowledgment.
    public let acknowledgedInputs: Int
    /// Number of remaining inputs replayed against the authoritative state.
    public let replayedInputs: Int
}

/// Transport-independent, bounded local prediction. Steps and validators must be pure and side-effect free.
/// Use value-semantic state and input. Staged changes then keep validation/replay failures atomic.
public struct NetworkPrediction<State: Codable & Sendable, Input: Codable & Sendable>: Sendable {
    /// The ownership incarnation accepted from the authenticated host.
    public let stream: NetworkPredictionStream
    /// Fixed duration and history bounds.
    public let configuration: NetworkPredictionConfiguration
    /// Current predicted state after replaying pending inputs.
    public private(set) var state: State
    /// The last accepted canonical host state.
    public private(set) var authoritativeState: State
    /// Latest input acknowledged by the host.
    public private(set) var acknowledgedInput: UInt64
    /// Latest accepted authoritative revision.
    public private(set) var revision: UInt64
    /// Latest locally issued input index.
    public private(set) var issuedInput: UInt64
    /// Pending ordered inputs, bounded by configuration.
    public private(set) var pendingInputs: [NetworkInputCommand<Input>] = []
    private let step: @Sendable (State, Input, TimeInterval) throws -> State
    private let validateInput: @Sendable (Input) throws -> Void
    private let validateState: @Sendable (State) throws -> Void

    /// Begins from a validated initial host result. Rebuild this value for a fresh ownership epoch.
    public init(authoritative: NetworkAuthoritativeState<State>, configuration: NetworkPredictionConfiguration = .init(),
                validateInput: @escaping @Sendable (Input) throws -> Void = { _ in },
                validateState: @escaping @Sendable (State) throws -> Void = { _ in },
                step: @escaping @Sendable (State, Input, TimeInterval) throws -> State) throws {
        try validateState(authoritative.state)
        stream = authoritative.stream; self.configuration = configuration
        state = authoritative.state; authoritativeState = authoritative.state
        acknowledgedInput = authoritative.acknowledgedInput; issuedInput = authoritative.acknowledgedInput; revision = authoritative.revision
        self.step = step; self.validateInput = validateInput; self.validateState = validateState
    }
    /// Predicts exactly one fixed step and returns the command to send through the current authenticated session.
    @discardableResult public mutating func predict(_ input: Input) throws -> NetworkInputCommand<Input> {
        guard pendingInputs.count < configuration.maximumPendingInputs, issuedInput < UInt64.max else { throw NetworkPredictionError.capacityExceeded }
        try validateInput(input)
        let next = try step(state, input, configuration.stepDuration); try validateState(next)
        let command = NetworkInputCommand(stream: stream, sequence: issuedInput + 1, input: input)
        state = next; issuedInput = command.sequence; pendingInputs.append(command)
        return command
    }
    /// Replaces canonical state, discards acknowledged inputs, and replays the bounded remainder.
    /// - Complexity: O(n) in pending inputs; no rendering, audio, rewards, or world events should run inside step.
    @discardableResult public mutating func reconcile(_ result: NetworkAuthoritativeState<State>) throws -> NetworkReconciliation {
        guard result.stream == stream else { throw NetworkPredictionError.wrongStream }
        guard result.revision > revision else { return .init(wasApplied: false, acknowledgedInputs: 0, replayedInputs: 0) }
        guard result.acknowledgedInput >= acknowledgedInput, result.acknowledgedInput <= issuedInput else { throw NetworkPredictionError.invalidAcknowledgment }
        try validateState(result.state)
        let remaining = pendingInputs.filter { $0.sequence > result.acknowledgedInput }
        var next = result.state
        for command in remaining { next = try step(next, command.input, configuration.stepDuration); try validateState(next) }
        let applied = pendingInputs.count - remaining.count
        state = next; authoritativeState = result.state; revision = result.revision
        acknowledgedInput = result.acknowledgedInput; pendingInputs = remaining
        return .init(wasApplied: true, acknowledgedInputs: applied, replayedInputs: remaining.count)
    }
}

/// Host-side ordered input admission and fixed-tick simulation. Receiving a burst never advances the actor.
public struct NetworkInputAuthority<State: Codable & Sendable, Input: Codable & Sendable>: Sendable {
    /// The host-created ownership incarnation.
    public let stream: NetworkPredictionStream
    /// The shared fixed step and admission bounds.
    public let configuration: NetworkPredictionConfiguration
    /// Canonical host state.
    public private(set) var state: State
    /// Latest actually simulated input, independent of transport message numbering.
    public private(set) var acknowledgedInput: UInt64 = 0
    /// Monotonic authoritative revision.
    public private(set) var revision: UInt64 = 0
    /// Number of admitted commands waiting for a host fixed tick.
    public var queuedInputCount: Int { queued.count }
    /// A complete current result; initial revision/acknowledgment are zero.
    public var snapshot: NetworkAuthoritativeState<State> { .init(stream: stream, revision: revision, acknowledgedInput: acknowledgedInput, state: state) }
    private var queued: [UInt64: NetworkInputCommand<Input>] = [:]
    private let idleInput: Input
    private let step: @Sendable (State, Input, TimeInterval) throws -> State
    private let validateInput: @Sendable (Input) throws -> Void
    private let validateState: @Sendable (State) throws -> Void
    /// Creates an authority with a neutral input used when the next ordered command has not arrived.
    public init(stream: NetworkPredictionStream, state: State, idleInput: Input,
                configuration: NetworkPredictionConfiguration = .init(),
                validateInput: @escaping @Sendable (Input) throws -> Void = { _ in },
                validateState: @escaping @Sendable (State) throws -> Void = { _ in },
                step: @escaping @Sendable (State, Input, TimeInterval) throws -> State) throws {
        try validateState(state); try validateInput(idleInput)
        self.stream = stream; self.state = state; self.idleInput = idleInput; self.configuration = configuration
        self.step = step; self.validateInput = validateInput; self.validateState = validateState
    }
    /// Admits one command from its transport-authenticated owner; duplicate indices are harmless and never replace queued input.
    @discardableResult public mutating func receive(_ command: NetworkInputCommand<Input>, from sender: NetworkPeerID) throws -> Bool {
        guard sender == stream.owner else { throw NetworkPredictionError.wrongOwner }
        guard command.stream == stream else { throw NetworkPredictionError.wrongStream }
        guard command.sequence > 0 else { throw NetworkPredictionError.invalidSequence }
        guard command.sequence > acknowledgedInput, queued[command.sequence] == nil else { return false }
        guard command.sequence - acknowledgedInput <= UInt64(configuration.maximumPendingInputs),
              queued.count < configuration.maximumPendingInputs else { throw NetworkPredictionError.capacityExceeded }
        try validateInput(command.input); queued[command.sequence] = command; return true
    }
    /// Advances once on a host-owned fixed tick, consuming at most the next contiguous input.
    /// No supplied command can choose duration or accelerate the host clock.
    @discardableResult public mutating func advance() throws -> NetworkAuthoritativeState<State> {
        guard revision < UInt64.max else { throw NetworkPredictionError.capacityExceeded }
        let command = acknowledgedInput < UInt64.max ? queued[acknowledgedInput + 1] : nil
        let next = try step(state, command?.input ?? idleInput, configuration.stepDuration); try validateState(next)
        state = next; revision += 1
        if let command { queued[command.sequence] = nil; acknowledgedInput = command.sequence }
        return snapshot
    }
    /// Applies a validated host correction with a new revision, retaining unprocessed input order.
    public mutating func correct(to state: State) throws {
        guard revision < UInt64.max else { throw NetworkPredictionError.capacityExceeded }
        try validateState(state); self.state = state; revision += 1
    }
}
