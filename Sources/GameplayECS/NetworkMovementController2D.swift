import ECSCore
import Foundation
import Gameplay
import Observation

/// Visual correction policy; model state is corrected immediately and never smoothed.
public struct NetworkMovementPresentationConfiguration: Hashable, Sendable {
    /// Exponential correction decay in seconds; zero snaps immediately.
    public let smoothingDuration: TimeInterval
    /// Corrections at or above this distance snap instead of dragging a visual across the scene.
    public let snapDistance: Float
    /// Creates bounded render-only correction settings.
    public init(smoothingDuration: TimeInterval = 0.12, snapDistance: Float = 100) {
        self.smoothingDuration = smoothingDuration.isFinite ? min(1, max(0, smoothingDuration)) : 0.12
        self.snapDistance = snapDistance.isFinite ? min(10_000, max(0, snapDistance)) : 100
    }
}

/// Explicit movement-controller lifecycle; a failed stream needs an application-owned rebuild.
public enum NetworkMovementStatus: String, Sendable { case waitingForAuthority, running, stopped, failed }
/// Adapter setup or lifetime errors. Native physics prediction is outside this controller's contract.
public enum NetworkMovementError: Error, Equatable, Sendable { case invalidSetup, incompatibleRules, invalidFixedStep, ownershipChanged, invalidMessage }

private struct MovementHeader: Decodable { let protocolID: String?; let entity: NetworkEntityID? }
private struct MovementPacket: Codable {
    var protocolID = "spriteui.movement2d"
    var version = 1
    enum Kind: String, Codable { case request, input, state }
    let kind: Kind
    let entity: NetworkEntityID
    let client: UUID
    var rules: KinematicMovement2D? = nil
    var stepDuration: TimeInterval? = nil
    var command: NetworkInputCommand<SIMD2<Float>>?
    var state: NetworkAuthoritativeState<KinematicState2D>?
}

/// A retained kinematic prediction adapter driven by fixed/presentation systems.
/// The client moves a separate, unsynchronized local visual; authoritative replicas remain untouched.
@MainActor @Observable public final class NetworkMovementController2D {
    /// The adapter's current lifecycle.
    public private(set) var status: NetworkMovementStatus
    /// The latest local error, without automatic retries or authentication.
    public private(set) var lastError: String?
    /// Current replayed client state, or canonical host state.
    public private(set) var predictedState: KinematicState2D
    /// Last accepted host state; the client must not publish it as authority.
    public private(set) var authoritativeState: KinematicState2D
    /// Number of client inputs awaiting an actual host simulation acknowledgment.
    public private(set) var pendingInputCount = 0
    /// Most recent host acknowledgment.
    public private(set) var acknowledgedInput: UInt64 = 0
    /// Number of inputs replayed by the last applied state.
    public private(set) var replayedInputCount = 0
    /// Most recent correction distance, before render-only smoothing.
    public private(set) var correctionDistance: Float = 0
    /// Count of nontrivial applied corrections.
    public private(set) var correctionCount: UInt64 = 0
    /// Count of rejected untrusted command messages; rejects do not advance the host.
    public private(set) var rejectedCommandCount: UInt64 = 0
    /// The host-created stream after the client handshake, or nil while waiting.
    public private(set) var stream: NetworkPredictionStream?
    /// The authoritative network identity.
    public let entityID: NetworkEntityID
    @ObservationIgnored private weak var world: World?
    @ObservationIgnored private weak var entity: Entity?
    @ObservationIgnored private let session: NetworkSession
    @ObservationIgnored private let rules: KinematicMovement2D
    @ObservationIgnored private let configuration: NetworkPredictionConfiguration
    @ObservationIgnored private let presentation: NetworkMovementPresentationConfiguration
    @ObservationIgnored private let owner: NetworkPeerID
    @ObservationIgnored private let isHost: Bool
    @ObservationIgnored private var clientID = UUID()
    @ObservationIgnored private var remoteClientID: UUID?
    @ObservationIgnored private var authority: NetworkInputAuthority<KinematicState2D, SIMD2<Float>>?
    @ObservationIgnored private var prediction: NetworkPrediction<KinematicState2D, SIMD2<Float>>?
    @ObservationIgnored private var input = SIMD2<Float>.zero
    @ObservationIgnored private var offset = SIMD2<Float>.zero
    @ObservationIgnored private var requestClock: TimeInterval = 1
    @ObservationIgnored private var stateClock: TimeInterval = 0
    @ObservationIgnored private var reliableState = true
    @ObservationIgnored private var subscriptions: [EventSubscription] = []

    /// Creates host authority for one root-level synchronized entity owned by a remote player.
    public static func host(in world: World, session: NetworkSession, entity: Entity, rules: KinematicMovement2D,
                            configuration: NetworkPredictionConfiguration = .init()) throws -> NetworkMovementController2D {
        guard session.isHost, entity.components.has(Transform.self), let sync = entity.components[SynchronizationComponent.self],
              sync.components.contains("transform"), let owner = sync.owner,
              owner != session.localPeer.id, session.peers.contains(where: { $0.id == owner }) else { throw NetworkMovementError.invalidSetup }
        return try .init(world: world, session: session, entity: entity, id: sync.id, owner: owner, rules: rules,
                         configuration: configuration, presentation: .init(), isHost: true, initialState: .init(position: entity.position))
    }
    /// Creates local prediction for one owned entity using a root-level visual with no SynchronizationComponent or native physics.
    /// Retain the controller; stop/rebuild it with its session after recovery, rejoin, or ownership transfer.
    public static func client(in world: World, session: NetworkSession, entityID: NetworkEntityID, visual: Entity,
                              rules: KinematicMovement2D, configuration: NetworkPredictionConfiguration = .init(),
                              presentation: NetworkMovementPresentationConfiguration = .init()) throws -> NetworkMovementController2D {
        guard !session.isHost, !visual.components.has(SynchronizationComponent.self),
              let replica = session.entity(withNetworkID: entityID), replica.parent === world.root,
              replica.components.has(Transform.self), let sync = replica.components[SynchronizationComponent.self],
              sync.owner == session.localPeer.id, sync.components.contains("transform") else { throw NetworkMovementError.invalidSetup }
        return try .init(world: world, session: session, entity: visual, id: entityID, owner: session.localPeer.id, rules: rules,
                         configuration: configuration, presentation: presentation, isHost: false, initialState: .init(position: replica.position))
    }
    private init(world: World, session: NetworkSession, entity: Entity, id: NetworkEntityID, owner: NetworkPeerID,
                 rules: KinematicMovement2D, configuration: NetworkPredictionConfiguration,
                 presentation: NetworkMovementPresentationConfiguration, isHost: Bool, initialState: KinematicState2D) throws {
        guard session.isAttached(to: world), session.state == .connected, entity.world === world, entity.parent === world.root,
              let fixed = world.fixedStep, abs(fixed.stepDuration - configuration.stepDuration) < 1e-9 else { throw NetworkMovementError.invalidSetup }
        try rules.validate()
        let state = initialState; try rules.validate(state: state)
        let drivers = world.root.components[NetworkMovementDrivers.self] ?? NetworkMovementDrivers()
        drivers.entries.removeAll { $0.value == nil || $0.value?.isActive == false }
        guard drivers.entries.count < 16, !drivers.entries.contains(where: { $0.value?.entityID == id }) else { throw NetworkMovementError.invalidSetup }
        self.world = world; self.entity = entity; self.session = session; self.entityID = id; self.owner = owner
        self.rules = rules; self.configuration = configuration; self.presentation = presentation; self.isHost = isHost
        predictedState = state; authoritativeState = state; status = isHost ? .running : .waitingForAuthority
        if isHost { authority = try Self.makeAuthority(stream: .init(entity: id, owner: owner), state: state, rules: rules, configuration: configuration); stream = authority?.stream }
        try world.systems.add(NetworkMovementSystem2D.self); try world.systems.add(NetworkMovementPresentationSystem2D.self)
        world.root.components.set(drivers); drivers.entries.append(.init(self))
        if !isHost { entity.position = state.position }
        subscriptions = [world.subscribe(to: NetworkEvents.CommandReceived.self) { [weak self] event in self?.receiveCommand(event) },
                         world.subscribe(to: NetworkEvents.ResponseReceived.self) { [weak self] event in self?.receiveState(event.data) },
                         world.subscribe(to: NetworkEvents.PeerLeft.self) { [weak self] event in if event.peerID == self?.owner { self?.stop() } },
                         world.subscribe(to: NetworkEvents.Failed.self) { [weak self] _ in self?.stop() }]
    }
    isolated deinit { for subscription in subscriptions { subscription.cancel() } }
    private var isActive: Bool { status == .running || status == .waitingForAuthority }
    /// Sets the held unit direction; one sample is captured on each client fixed tick.
    public func setInput(_ direction: SIMD2<Float>) throws { try rules.validate(direction: direction); guard isActive, !isHost else { throw NetworkMovementError.invalidSetup }; input = direction }
    /// Corrects canonical host position and schedules a reliable full result. Pending inputs remain ordered.
    public func correct(to position: SIMD2<Float>) throws {
        guard isHost, status == .running, var authority else { throw NetworkMovementError.invalidSetup }
        try authority.correct(to: .init(position: position)); self.authority = authority
        predictedState = authority.state; authoritativeState = authority.state; entity?.position = position; reliableState = true
    }
    /// Retires local input/history and smoothing without stopping the shared network session.
    public func stop() { for subscription in subscriptions { subscription.cancel() }; subscriptions = []; prediction = nil; authority = nil; input = .zero; offset = .zero; pendingInputCount = 0; status = .stopped }

    fileprivate func fixedUpdate(_ duration: TimeInterval) {
        guard isActive else { return }
        guard let world, let entity, session.isAttached(to: world), session.state == .connected else { stop(); return }
        do {
            guard entity.world === world, entity.parent === world.root, entity.isActive else { throw NetworkMovementError.invalidSetup }
            guard abs(duration - configuration.stepDuration) < 1e-9 else { throw NetworkMovementError.invalidFixedStep }
            if isHost {
                guard session.peers.contains(where: { $0.id == owner }), entity.components.has(Transform.self),
                      let sync = entity.components[SynchronizationComponent.self], sync.id == entityID, sync.owner == owner, sync.components.contains("transform") else { throw NetworkMovementError.ownershipChanged }
                guard var authority else { throw NetworkMovementError.invalidSetup }
                _ = try authority.advance(); self.authority = authority
                predictedState = authority.state; authoritativeState = authority.state; acknowledgedInput = authority.acknowledgedInput; entity.position = authority.state.position
                let stateInterval = 1 / session.configuration.updatesPerSecond
                stateClock = min(stateInterval, stateClock + duration)
                if stateClock + 1e-9 >= stateInterval, let client = remoteClientID {
                    stateClock = max(0, stateClock - stateInterval)
                    let packet = MovementPacket(kind: .state, entity: entityID, client: client, rules: reliableState ? rules : nil,
                        stepDuration: reliableState ? configuration.stepDuration : nil, state: authority.snapshot)
                    do { try sendState(packet, reliably: reliableState); reliableState = false }
                    catch NetworkSessionError.notConnected { } // Wait for the owner's baseline handshake.
                }
            } else if var prediction {
                guard let replica = session.entity(withNetworkID: entityID), replica.parent === world.root,
                      replica.components.has(Transform.self), replica.components[SynchronizationComponent.self]?.owner == owner else { throw NetworkMovementError.ownershipChanged }
                let command = try prediction.predict(input)
                try session.sendCommand(JSONEncoder().encode(MovementPacket(kind: .input, entity: entityID, client: clientID, command: command)))
                self.prediction = prediction; predictedState = prediction.state; pendingInputCount = prediction.pendingInputs.count
            } else {
                requestClock += duration
                if requestClock >= 0.5 {
                    requestClock = 0
                    try session.sendCommand(JSONEncoder().encode(MovementPacket(kind: .request, entity: entityID, client: clientID,
                        rules: rules, stepDuration: configuration.stepDuration)))
                }
            }
        } catch { fail(error) }
    }
    fileprivate func present(_ duration: TimeInterval) {
        guard isActive else { return }
        guard let world, session.isAttached(to: world), session.state == .connected else { stop(); return }
        guard duration.isFinite, duration >= 0, let fixed = world.fixedStep,
              abs(fixed.stepDuration - configuration.stepDuration) < 1e-9 else { fail(NetworkMovementError.invalidFixedStep); return }
        if !isHost, prediction != nil {
            let decay = presentation.smoothingDuration == 0 ? 0 : Float(exp(-min(duration, 1) / presentation.smoothingDuration))
            offset *= decay; entity?.position = predictedState.position + offset
        }
    }
    private static func makeAuthority(stream: NetworkPredictionStream, state: KinematicState2D, rules: KinematicMovement2D,
                                      configuration: NetworkPredictionConfiguration) throws -> NetworkInputAuthority<KinematicState2D, SIMD2<Float>> {
        try .init(stream: stream, state: state, idleInput: .zero, configuration: configuration,
            validateInput: { try rules.validate(direction: $0) }, validateState: { try rules.validate(state: $0) },
            step: { try rules.step($0, direction: $1, deltaTime: $2) })
    }
    private func receiveCommand(_ event: NetworkEvents.CommandReceived) {
        guard isHost, status == .running, event.sender == owner,
              let header = try? JSONDecoder().decode(MovementHeader.self, from: event.data),
              header.protocolID == "spriteui.movement2d", header.entity == entityID else { return }
        do {
            let packet = try JSONDecoder().decode(MovementPacket.self, from: event.data)
            guard packet.entity == entityID else { return }
            try validate(packet)
            switch packet.kind {
            case .request:
                guard packet.command == nil, packet.state == nil, packet.rules == rules, packet.stepDuration == configuration.stepDuration, let authority else { throw NetworkMovementError.invalidMessage }
                if remoteClientID != packet.client {
                    self.authority = try Self.makeAuthority(stream: .init(entity: entityID, owner: owner), state: authority.state, rules: rules, configuration: configuration)
                    stream = self.authority?.stream; remoteClientID = packet.client
                }
                reliableState = true
            case .input:
                guard packet.client == remoteClientID, let command = packet.command, packet.state == nil, var authority else { throw NetworkMovementError.invalidMessage }
                _ = try authority.receive(command, from: event.sender); self.authority = authority
            case .state: throw NetworkMovementError.invalidMessage
            }
        } catch { if rejectedCommandCount < UInt64.max { rejectedCommandCount += 1 } }
    }
    private func receiveState(_ data: Data) {
        guard !isHost, isActive,
              let header = try? JSONDecoder().decode(MovementHeader.self, from: data),
              header.protocolID == "spriteui.movement2d", header.entity == entityID else { return }
        do {
            guard let source = session.entity(withNetworkID: entityID), source.components[SynchronizationComponent.self]?.owner == owner,
                  source.parent === world?.root, source.components.has(Transform.self) else { throw NetworkMovementError.ownershipChanged }
            let packet = try JSONDecoder().decode(MovementPacket.self, from: data)
            guard packet.entity == entityID, packet.client == clientID else { return }
            try validate(packet)
            guard packet.kind == .state, packet.command == nil, let state = packet.state,
                  state.stream.entity == entityID, state.stream.owner == owner else { throw NetworkMovementError.invalidMessage }
            if var prediction {
                let previousPrediction = predictedState.position
                let displayed = previousPrediction + offset
                let result = try prediction.reconcile(state)
                guard result.wasApplied else { return }
                self.prediction = prediction; predictedState = prediction.state; authoritativeState = state.state
                acknowledgedInput = state.acknowledgedInput; pendingInputCount = prediction.pendingInputs.count; replayedInputCount = result.replayedInputs
                let delta = displayed - predictedState.position
                let modelDelta = previousPrediction - predictedState.position
                correctionDistance = sqrt(modelDelta.x * modelDelta.x + modelDelta.y * modelDelta.y)
                if correctionDistance > 0.001, correctionCount < UInt64.max { correctionCount += 1 }
                let visualDistance = sqrt(delta.x * delta.x + delta.y * delta.y)
                offset = visualDistance >= presentation.snapDistance || presentation.smoothingDuration == 0 ? .zero : delta
            } else {
                guard packet.rules == rules, packet.stepDuration == configuration.stepDuration, state.acknowledgedInput == 0 else { throw NetworkPredictionError.invalidAcknowledgment }
                prediction = try .init(authoritative: state, configuration: configuration,
                    validateInput: { [rules] in try rules.validate(direction: $0) }, validateState: { [rules] in try rules.validate(state: $0) },
                    step: { [rules] in try rules.step($0, direction: $1, deltaTime: $2) })
                stream = state.stream; predictedState = state.state; authoritativeState = state.state; status = .running; offset = .zero
            }
        } catch { fail(error) }
    }
    private func validate(_ packet: MovementPacket) throws {
        guard packet.protocolID == "spriteui.movement2d", packet.version == 1 else { throw NetworkMovementError.invalidMessage }
        if let sent = packet.rules, sent != rules { throw NetworkMovementError.incompatibleRules }
        if let duration = packet.stepDuration, abs(duration - configuration.stepDuration) >= 1e-9 || !duration.isFinite { throw NetworkMovementError.incompatibleRules }
    }
    private func sendState(_ packet: MovementPacket, reliably: Bool) throws {
        let data = try JSONEncoder().encode(packet)
        do { try session.sendResponse(data, to: owner, reliably: reliably) }
        catch NetworkSessionError.packetTooLarge where !reliably { try session.sendResponse(data, to: owner, reliably: true) }
    }
    private func fail(_ error: any Error) { let message = String(describing: error); stop(); status = .failed; lastError = message }
}

@MainActor private final class WeakMovementController {
    weak var value: NetworkMovementController2D?
    init(_ value: NetworkMovementController2D) { self.value = value }
}
@MainActor private final class NetworkMovementDrivers: Component { var entries: [WeakMovementController] = [] }

/// Advances retained movement controllers exactly once per configured fixed tick.
public struct NetworkMovementSystem2D: System {
    public static var phase: SystemPhase { .fixedSimulation }
    public init(world: World) {}
    public mutating func update(context: UpdateContext) {
        guard let drivers = context.world.root.components[NetworkMovementDrivers.self] else { return }
        drivers.entries.removeAll { $0.value == nil }
        for entry in drivers.entries { entry.value?.fixedUpdate(context.deltaTime) }
    }
}
/// Applies local visual correction decay after authoritative messages have been drained.
public struct NetworkMovementPresentationSystem2D: System {
    public static var phase: SystemPhase { .presentation }
    public static var dependencies: [SystemDependency] { [.after(NetworkReplicationSystem.self)] }
    public init(world: World) {}
    public mutating func update(context: UpdateContext) {
        guard let drivers = context.world.root.components[NetworkMovementDrivers.self] else { return }
        for entry in drivers.entries { entry.value?.present(context.deltaTime) }
    }
}
