import ECSCore
import Foundation
import Gameplay
import Observation

/// Explicit portable hit proxies captured for multiplayer queries; no native body is rewound.
public struct NetworkInteractionBodyComponent: Component, Codable, Sendable {
    /// Local convex or edge hit geometry, independent of the renderer's physics body.
    public var shape: CollisionShape
    /// Local-space source/collider origin offset.
    public var offset: SIMD2<Float>
    /// Whether rays can hit this body, whether it occludes, and whether it can be interacted with.
    public var isTarget: Bool
    public var blocksRays: Bool
    public var canInteract: Bool
    /// A body lifetime; replace this component with a new instance on respawn or semantic shape replacement.
    public let incarnation: UUID
    /// Creates an opt-in body. Capture requires a synchronized entity identity.
    public init(shape: CollisionShape, offset: SIMD2<Float> = .zero, isTarget: Bool = true,
                blocksRays: Bool = true, canInteract: Bool = false) {
        self.shape = shape; self.offset = offset; self.isTarget = isTarget; self.blocksRays = blocksRays
        self.canInteract = canInteract; incarnation = UUID()
    }
    /// Gives a cloned body a fresh lifetime identity.
    public func cloned() -> Self? { .init(shape: shape, offset: offset, isTarget: isTarget, blocksRays: blocksRays, canInteract: canInteract) }
}

/// Host-controlled ranges; clients supply direction or target identity, never a hit or damage amount.
public struct NetworkInteractionRules2D: Hashable, Codable, Sendable {
    /// Maximum ray travel and center-to-center interaction range in scene units.
    public let rayRange: Float
    public let interactionRange: Float
    /// Creates rules that must be validated before use.
    public init(rayRange: Float = 1_000, interactionRange: Float = 80) { self.rayRange = rayRange; self.interactionRange = interactionRange }
    /// Validates finite positive ranges no larger than 10,000 units.
    public func validate() throws {
        guard rayRange.isFinite, interactionRange.isFinite, rayRange > 0, interactionRange > 0,
              rayRange <= 10_000, interactionRange <= 10_000 else { throw NetworkInteractionError.invalidResult }
    }
}

/// Narrow client intent. Directions must be finite unit vectors; proximity uses historical center distance and visibility.
public enum NetworkInteractionIntent2D: Codable, Sendable { case ray(direction: SIMD2<Float>), interact(with: NetworkEntityID) }
/// A confirmed query result; the app owns damage, effects, inventory, and durable reward transactions.
public struct NetworkInteractionOutcome2D: Codable, Sendable {
    /// Misses and blocked rays consume cooldown but do not grant hits or interactions.
    public enum Kind: String, Codable, Sendable { case miss, blocked, hit, interacted }
    /// The authoritative query category.
    public let kind: Kind
    /// Historical body identity/contact, absent for a miss.
    public let contact: HistoricalCollisionHit2D<NetworkEntityID>?
    /// The host-recorded source origin, not a client-provided position.
    public let origin: SIMD2<Float>
}
/// A narrow host-selected historical collision view; do not add secret or unrelated entities.
public typealias NetworkInteractionScene2D = HistoricalCollisionScene2D<NetworkEntityID>
/// Lifecycle failures require explicit application-owned controller/session recovery.
public enum NetworkInteractionControllerStatus: String, Sendable { case waitingForAuthority, running, stopped, failed }

/// Local speculative feedback and final receipts; duplicate packets never publish these events twice.
public enum NetworkInteractionEvents {
    /// Transient feedback only: no damage, achievements, or rewards may be granted here.
    public struct Predicted: Event { public let entityID: NetworkEntityID; public let command: NetworkInteractionCommand<NetworkInteractionIntent2D> }
    /// A newly committed final receipt. Only isAuthority may apply host gameplay changes.
    public struct Resolved: Event {
        public let entityID: NetworkEntityID
        public let result: NetworkInteractionResult<NetworkInteractionOutcome2D>
        public let isAuthority: Bool
    }
}

private struct InteractionHeader: Decodable { let protocolID: String?; let entity: NetworkEntityID? }
private struct InteractionPacket: Codable {
    var protocolID = "spriteui.interactions2d"
    var version = 1
    enum Kind: String, Codable { case request, view, action, result }
    let kind: Kind
    let entity: NetworkEntityID
    let client: UUID
    var rules: NetworkInteractionRules2D?
    var view: NetworkInteractionView<NetworkInteractionScene2D>?
    var command: NetworkInteractionCommand<NetworkInteractionIntent2D>?
    var result: NetworkInteractionResult<NetworkInteractionOutcome2D>?
}

/// A retained adapter for exact historical ray/proximity queries over an existing connected session.
/// Views, actions, and results are reliable and bounded by session application-payload limits.
@MainActor @Observable public final class NetworkInteractionController2D {
    /// Current lifecycle; appearance or reconnect never silently restarts this controller.
    public private(set) var status: NetworkInteractionControllerStatus
    /// A diagnostic for an explicit local failure.
    public private(set) var lastError: String?
    /// The authoritative actor identity this stream acts from.
    public let entityID: NetworkEntityID
    /// Latest exact host-issued view. Render/aim from this view when claiming historical compensation.
    public private(set) var latestView: NetworkInteractionView<NetworkInteractionScene2D>?
    /// Number of unresolved speculative actions.
    public private(set) var pendingActionCount = 0
    /// Number of newly confirmed local/host receipts, including refusals.
    public private(set) var resolvedActionCount: UInt64 = 0
    /// Number of rejected malformed/unauthorized messages or excess queued actions.
    public private(set) var rejectedMessageCount: UInt64 = 0
    /// Most recent newly confirmed receipt.
    public private(set) var lastResult: NetworkInteractionResult<NetworkInteractionOutcome2D>?
    @ObservationIgnored private weak var world: World?
    @ObservationIgnored private weak var source: Entity?
    @ObservationIgnored private let session: NetworkSession
    @ObservationIgnored private let owner: NetworkPeerID
    @ObservationIgnored private let sourceIncarnation: UUID?
    @ObservationIgnored private let rules: NetworkInteractionRules2D
    @ObservationIgnored private let configuration: NetworkInteractionConfiguration
    @ObservationIgnored private let isHost: Bool
    @ObservationIgnored private let validateAction: (NetworkInteractionIntent2D, NetworkInteractionOutcome2D) throws -> Void
    @ObservationIgnored private var clientID = UUID()
    @ObservationIgnored private var remoteClientID: UUID?
    @ObservationIgnored private var authority: NetworkInteractionAuthority<NetworkInteractionScene2D, NetworkInteractionIntent2D, NetworkInteractionOutcome2D>?
    @ObservationIgnored private var client: NetworkInteractionClient<NetworkInteractionScene2D, NetworkInteractionIntent2D, NetworkInteractionOutcome2D>?
    @ObservationIgnored private var queued: [InteractionPacket] = []
    @ObservationIgnored private var subscriptions: [EventSubscription] = []
    @ObservationIgnored private var clock: TimeInterval = 0
    @ObservationIgnored private var viewClock: TimeInterval = 1
    @ObservationIgnored private var requestClock: TimeInterval = 1
    @ObservationIgnored private var lastAcceptedActionTime: TimeInterval?

    /// Creates host authority for one remotely owned synchronized actor with an explicit hit body.
    /// The pure validator may reject cooldown-independent game rules; apply effects only from a new Resolved event.
    public static func host(in world: World, session: NetworkSession, entity: Entity,
                            rules: NetworkInteractionRules2D = .init(), configuration: NetworkInteractionConfiguration = .init(),
                            validateAction: @escaping (NetworkInteractionIntent2D, NetworkInteractionOutcome2D) throws -> Void = { _, _ in }) throws -> NetworkInteractionController2D {
        guard session.isHost, let sync = entity.components[SynchronizationComponent.self], let owner = sync.owner,
              owner != session.localPeer.id, session.peers.contains(where: { $0.id == owner }),
              entity.components.has(NetworkInteractionBodyComponent.self) else { throw NetworkSessionError.invalidState }
        return try .init(world: world, session: session, source: entity, id: sync.id, owner: owner, rules: rules,
                         configuration: configuration, isHost: true, validateAction: validateAction)
    }
    /// Creates local feedback bookkeeping after the owned canonical replica baseline is present.
    public static func client(in world: World, session: NetworkSession, entityID: NetworkEntityID,
                              rules: NetworkInteractionRules2D = .init(), configuration: NetworkInteractionConfiguration = .init()) throws -> NetworkInteractionController2D {
        guard !session.isHost, let entity = session.entity(withNetworkID: entityID),
              entity.components[SynchronizationComponent.self]?.owner == session.localPeer.id else { throw NetworkSessionError.invalidState }
        return try .init(world: world, session: session, source: entity, id: entityID, owner: session.localPeer.id,
                         rules: rules, configuration: configuration, isHost: false, validateAction: { _, _ in })
    }
    private init(world: World, session: NetworkSession, source: Entity, id: NetworkEntityID, owner: NetworkPeerID,
                 rules: NetworkInteractionRules2D, configuration: NetworkInteractionConfiguration, isHost: Bool,
                 validateAction: @escaping (NetworkInteractionIntent2D, NetworkInteractionOutcome2D) throws -> Void) throws {
        guard session.state == .connected, session.isAttached(to: world), source.world === world, source.isActive else { throw NetworkSessionError.invalidState }
        try rules.validate()
        let drivers = world.root.components[InteractionDrivers.self] ?? InteractionDrivers()
        drivers.entries.removeAll { $0.value == nil || $0.value?.isActive == false }
        guard drivers.entries.count < 16, !drivers.entries.contains(where: { $0.value?.entityID == id }) else { throw NetworkSessionError.capacityExceeded }
        self.world = world; self.session = session; self.source = source; entityID = id; self.owner = owner
        sourceIncarnation = source.components[NetworkInteractionBodyComponent.self]?.incarnation
        self.rules = rules; self.configuration = configuration; self.isHost = isHost; self.validateAction = validateAction
        status = isHost ? .running : .waitingForAuthority
        try world.systems.add(NetworkInteractionSystem2D.self); world.root.components.set(drivers); drivers.entries.append(.init(self))
        subscriptions = [world.subscribe(to: NetworkEvents.CommandReceived.self) { [weak self] in self?.receiveCommand($0) },
            world.subscribe(to: NetworkEvents.ResponseReceived.self) { [weak self] in self?.receiveResponse($0.data) },
            world.subscribe(to: NetworkEvents.PeerLeft.self) { [weak self] in if $0.peerID == self?.owner { self?.stop() } },
            world.subscribe(to: NetworkEvents.Failed.self) { [weak self] _ in self?.stop() }]
    }
    isolated deinit { for token in subscriptions { token.cancel() } }
    private var isActive: Bool { status == .running || status == .waitingForAuthority }
    /// Sends narrow intent and publishes one transient local prediction after successful reliable send.
    /// No speculative hit/damage is inferred. Reject/finalize that feedback from the matching Resolved receipt.
    @discardableResult public func perform(_ intent: NetworkInteractionIntent2D) throws -> UInt64 {
        guard !isHost, status == .running, var client, let world else { throw NetworkSessionError.notConnected }
        try validateLifetime()
        try validateIntent(intent)
        let command = try client.predict(intent)
        try session.sendCommand(JSONEncoder().encode(InteractionPacket(kind: .action, entity: entityID, client: clientID, command: command)))
        self.client = client; pendingActionCount = client.pendingActionCount
        world.publish(NetworkInteractionEvents.Predicted(entityID: entityID, command: command))
        return command.sequence
    }
    /// Retires view tokens, pending actions, and subscriptions without stopping the shared session.
    public func stop() {
        for token in subscriptions { token.cancel() }; subscriptions = []; queued = []; authority = nil; client = nil
        latestView = nil; pendingActionCount = 0; status = .stopped
    }
    fileprivate func update(_ duration: TimeInterval) {
        guard isActive else { return }
        do {
            try validateLifetime()
            guard duration.isFinite, duration >= 0, duration <= 10, clock + duration < Double.greatestFiniteMagnitude else { throw NetworkInteractionError.invalidTime }
            clock += duration
            if isHost { try updateHost(duration) }
            else if client == nil {
                requestClock += duration
                if requestClock >= 0.5 { requestClock = 0; try session.sendCommand(JSONEncoder().encode(InteractionPacket(kind: .request, entity: entityID, client: clientID, rules: rules))) }
            }
        } catch { fail(error) }
    }
    private func validateLifetime() throws {
        guard let world, let source, session.isAttached(to: world), session.state == .connected,
              source.world === world, source.isActive, let sync = source.components[SynchronizationComponent.self],
              sync.id == entityID, sync.owner == owner, sync.components.contains("transform") else { throw NetworkSessionError.invalidState }
        if isHost {
            guard session.peers.contains(where: { $0.id == owner }), source.components[NetworkInteractionBodyComponent.self]?.incarnation == sourceIncarnation else { throw NetworkInteractionError.wrongStream }
        }
    }
    private func updateHost(_ duration: TimeInterval) throws {
        guard let world else { throw NetworkSessionError.worldUnavailable }
        if var authority, duration > 0 {
            let scene = try capture(in: world)
            try authority.record(scene, at: clock, validate: { try $0.validate() }); self.authority = authority
        }
        let commands = queued; queued = []
        for packet in commands {
            guard isActive else { return }
            try validateLifetime()
            if packet.kind == .request {
                if remoteClientID != packet.client {
                    var fresh = NetworkInteractionAuthority<NetworkInteractionScene2D, NetworkInteractionIntent2D, NetworkInteractionOutcome2D>(
                        stream: .init(entity: entityID, owner: owner), configuration: configuration)
                    try fresh.record(capture(in: world), at: clock, validate: { try $0.validate() })
                    authority = fresh; remoteClientID = packet.client
                }
                viewClock = 1
            } else if packet.client == remoteClientID, let command = packet.command, var authority {
                do {
                    let decision = try authority.resolve(command, from: owner, at: clock) { scene, intent in
                        if let last = self.lastAcceptedActionTime, self.clock - last + 1e-9 < self.configuration.cooldown { throw NetworkInteractionRejection.cooldown }
                        let outcome = try self.outcome(in: scene, intent: intent)
                        try self.validateCurrent(outcome, in: world)
                        try self.validateAction(intent, outcome)
                        return outcome
                    }
                    self.authority = authority
                    // Cache before publishing; handlers can stop the controller or change game state.
                    if decision.isNew {
                        lastResult = decision.result; resolvedActionCount &+= 1
                        if case .accepted = decision.result.resolution { lastAcceptedActionTime = clock }
                        world.publish(NetworkInteractionEvents.Resolved(entityID: entityID, result: decision.result, isAuthority: true))
                    }
                    guard isActive else { return }
                    do { try send(InteractionPacket(kind: .result, entity: entityID, client: packet.client, result: decision.result)) }
                    catch { fail(error); return }
                } catch { rejectedMessageCount &+= 1 }
            }
        }
        guard isActive, let remoteClientID, var authority else { return }
        viewClock += duration
        let interval = 1 / session.configuration.updatesPerSecond
        if viewClock + 1e-9 >= interval {
            viewClock = 0; let view = try authority.issueView(); self.authority = authority; latestView = view
            try send(InteractionPacket(kind: .view, entity: entityID, client: remoteClientID, rules: rules, view: view))
        }
    }
    private func capture(in world: World) throws -> NetworkInteractionScene2D {
        let bodies = world.allEntities.filter(\.isActive).compactMap { entity -> HistoricalCollisionBody2D<NetworkEntityID>? in
            guard let marker = entity.components[NetworkInteractionBodyComponent.self], let sync = entity.components[SynchronizationComponent.self] else { return nil }
            let matrix = entity.sceneTransformMatrix * AffineTransform2D(tx: marker.offset.x, ty: marker.offset.y)
            return .init(id: sync.id, incarnation: marker.incarnation, shape: marker.shape, position: [matrix.tx, matrix.ty],
                xAxis: [matrix.a, matrix.b], yAxis: [matrix.c, matrix.d], isTarget: marker.isTarget, blocksRays: marker.blocksRays, canInteract: marker.canInteract)
        }.sorted { $0.id < $1.id }
        let scene = NetworkInteractionScene2D(bodies: bodies); try scene.validate()
        guard bodies.contains(where: { $0.id == entityID }) else { throw HistoricalCollisionError.missingSource }
        return scene
    }
    private func outcome(in scene: NetworkInteractionScene2D, intent: NetworkInteractionIntent2D) throws -> NetworkInteractionOutcome2D {
        try validateIntent(intent)
        guard let origin = scene.bodies.first(where: { $0.id == entityID })?.position else { throw NetworkInteractionRejection.invalidIntent }
        let contact: HistoricalCollisionHit2D<NetworkEntityID>?
        let kind: NetworkInteractionOutcome2D.Kind
        switch intent {
        case .ray(let direction):
            contact = try scene.raycast(from: entityID, direction: direction, range: rules.rayRange)
            kind = contact.map { $0.isTarget ? .hit : .blocked } ?? .miss
        case .interact(let target):
            contact = try scene.interaction(from: entityID, with: target, range: rules.interactionRange)
            guard let contact else { throw NetworkInteractionRejection.targetUnavailable }
            kind = contact.isTarget ? .interacted : .blocked
        }
        return .init(kind: kind, contact: contact, origin: origin)
    }
    private func validateCurrent(_ outcome: NetworkInteractionOutcome2D, in world: World) throws {
        guard let contact = outcome.contact, outcome.kind == .hit || outcome.kind == .interacted else { return }
        guard let target = session.entity(withNetworkID: contact.id), target.world === world, target.isActive,
              let body = target.components[NetworkInteractionBodyComponent.self], body.incarnation == contact.incarnation,
              outcome.kind == .hit ? body.isTarget : body.canInteract else { throw NetworkInteractionRejection.targetUnavailable }
    }
    private func validateIntent(_ intent: NetworkInteractionIntent2D) throws {
        if case .ray(let direction) = intent {
            let n = direction.x * direction.x + direction.y * direction.y
            guard direction.x.isFinite, direction.y.isFinite, abs(n - 1) <= 0.0001 else { throw NetworkInteractionRejection.invalidIntent }
        } else if case .interact(let target) = intent, target == entityID { throw NetworkInteractionRejection.invalidIntent }
    }
    private func receiveCommand(_ event: NetworkEvents.CommandReceived) {
        guard isHost, isActive, event.sender == owner,
              let header = try? JSONDecoder().decode(InteractionHeader.self, from: event.data),
              header.protocolID == "spriteui.interactions2d", header.entity == entityID else { return }
        do {
            let packet = try JSONDecoder().decode(InteractionPacket.self, from: event.data)
            guard packet.version == 1, packet.view == nil, packet.result == nil,
                  (packet.kind == .request && packet.rules == rules && packet.command == nil) ||
                  (packet.kind == .action && packet.rules == nil && packet.command != nil), queued.count < 32 else { throw NetworkSessionError.invalidPacket }
            queued.append(packet)
        } catch { rejectedMessageCount &+= 1 }
    }
    private func receiveResponse(_ data: Data) {
        guard !isHost, isActive,
              let header = try? JSONDecoder().decode(InteractionHeader.self, from: data),
              header.protocolID == "spriteui.interactions2d", header.entity == entityID else { return }
        do {
            try validateLifetime()
            let packet = try JSONDecoder().decode(InteractionPacket.self, from: data)
            guard packet.client == clientID else { return }
            guard packet.version == 1, packet.command == nil else { throw NetworkSessionError.invalidPacket }
            if packet.kind == .view, let view = packet.view, packet.result == nil, packet.rules == rules {
                try view.state.validate()
                guard view.reference.stream.entity == entityID, view.reference.stream.owner == owner,
                      view.state.bodies.contains(where: { $0.id == entityID }) else { throw NetworkInteractionError.wrongStream }
                if var client { if try client.receive(view) { self.client = client; latestView = view } }
                else { client = .init(view: view, configuration: configuration); latestView = view; status = .running }
            } else if packet.kind == .result, packet.rules == nil, packet.view == nil, let result = packet.result, var client {
                try validateResult(result)
                if try client.receive(result) {
                    self.client = client; pendingActionCount = client.pendingActionCount; lastResult = result; resolvedActionCount &+= 1
                    world?.publish(NetworkInteractionEvents.Resolved(entityID: entityID, result: result, isAuthority: false))
                }
            } else { throw NetworkSessionError.invalidPacket }
        } catch { fail(error) }
    }
    private func validateResult(_ result: NetworkInteractionResult<NetworkInteractionOutcome2D>) throws {
        guard case .accepted(let outcome) = result.resolution else { return }
        func finite(_ point: SIMD2<Float>) -> Bool { point.x.isFinite && point.y.isFinite && abs(point.x) <= 2_000_000 && abs(point.y) <= 2_000_000 }
        guard finite(outcome.origin) else { throw NetworkInteractionError.invalidResult }
        if outcome.kind == .miss { guard outcome.contact == nil else { throw NetworkInteractionError.invalidResult }; return }
        guard let hit = outcome.contact, hit.id != entityID, finite(hit.position), hit.distance.isFinite, hit.distance >= 0,
              hit.distance <= (outcome.kind == .interacted ? rules.interactionRange : outcome.kind == .blocked ? max(rules.rayRange, rules.interactionRange) : rules.rayRange) + 0.01,
              hit.isTarget == (outcome.kind != .blocked) else { throw NetworkInteractionError.invalidResult }
    }
    private func send(_ packet: InteractionPacket) throws {
        try session.sendResponse(JSONEncoder().encode(packet), to: owner)
    }
    private func fail(_ error: any Error) { let message = String(describing: error); stop(); status = .failed; lastError = message }
}

@MainActor private final class WeakInteractionController {
    weak var value: NetworkInteractionController2D?
    init(_ value: NetworkInteractionController2D) { self.value = value }
}
@MainActor private final class InteractionDrivers: Component { var entries: [WeakInteractionController] = [] }
/// Records host hit proxies and resolves queued actions after networking, without rewinding the world.
public struct NetworkInteractionSystem2D: System {
    public static var phase: SystemPhase { .presentation }
    public static var dependencies: [SystemDependency] { [.after(NetworkReplicationSystem.self)] }
    public init(world: World) {}
    public mutating func update(context: UpdateContext) {
        guard let drivers = context.world.root.components[InteractionDrivers.self] else { return }
        drivers.entries.removeAll { $0.value == nil }
        for entry in drivers.entries { entry.value?.update(context.unscaledDeltaTime) }
    }
}
