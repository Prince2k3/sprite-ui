import Foundation
import Observation

struct ReplicatedComponent: Codable, Equatable, Sendable {
    let name: String
    let value: Data
}

struct ReplicatedEntity: Codable, Equatable, Sendable {
    let id: NetworkEntityID
    let parent: NetworkEntityID?
    let name: String
    let isEnabled: Bool
    let owner: NetworkPeerID?
    let interpolates: Bool
    let selected: [String]
    let components: [ReplicatedComponent]
}

struct ReplicationPacket: Codable {
    enum Kind: String, Codable { case hello, state, command, end }
    var version = 1
    let kind: Kind
    let session: UUID
    let join: UUID
    let sequence: UInt64
    var baseline = false
    var entities: [ReplicatedEntity] = []
    var command: Data? = nil
}

/// A host-authoritative replicated world. Game Center supplies the transport;
/// the core also works with ``InMemoryNetwork`` for deterministic offline tests.
///
/// Start after constructing local entities and registering matching schemas.
/// A presentation-phase system installed by `start()` drains incoming messages
/// after simulation and captures outgoing state at a bounded cadence. Pause
/// stops automatic network updates; call `update(deltaTime:)` from your host
/// lifecycle if a paused game should keep exchanging messages.
///
/// Clients must not run authoritative rules on replicas. They submit commands
/// with ``sendCommand(_:)``; only the host creates, removes or changes replicated
/// state. This is state synchronization, not deterministic lockstep or rollback.
@MainActor @Observable
public final class NetworkSession {
    public enum Role: Equatable, Sendable { case host, client(host: NetworkPeerID) }
    public enum State: Equatable, Sendable { case idle, joining, connected, stopped, failed }
    public let role: Role
    public let configuration: NetworkSessionConfiguration
    public var localPeer: NetworkPeer { transport.localPeer }
    public var isHost: Bool { role == .host }
    public private(set) var state: State = .idle
    public private(set) var peers: [NetworkPeer] = []
    public private(set) var lastError: NetworkSessionError?
    public private(set) var sequence: UInt64 = 0
    public private(set) var replicatedEntityCount = 0
    @ObservationIgnored private weak var world: World?
    @ObservationIgnored private let transport: any NetworkTransport
    @ObservationIgnored private let schema: NetworkReplicationSchema
    @ObservationIgnored private var incoming: [NetworkTransportEvent] = []
    @ObservationIgnored private var queuedBytes = 0
    @ObservationIgnored private var queueOverflow = false
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var operating = false
    @ObservationIgnored private var ownsTransport = false
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var joinID = UUID()
    @ObservationIgnored private var hostSession: UUID?
    @ObservationIgnored private var joined: [NetworkPeerID: UUID] = [:]
    @ObservationIgnored private var commandSequences: [NetworkPeerID: UInt64] = [:]
    @ObservationIgnored private var commandSequence: UInt64 = 0
    @ObservationIgnored private var sentStructure: [NetworkPeerID: [ReplicatedEntity]] = [:]
    @ObservationIgnored private var replicas: [NetworkEntityID: Entity] = [:]
    @ObservationIgnored private var replicaComponents: [NetworkEntityID: Set<String>] = [:]
    @ObservationIgnored private var smoothing: [NetworkEntityID: RemotePose] = [:]
    @ObservationIgnored private var elapsed: TimeInterval = 0
    @ObservationIgnored private var joinElapsed: TimeInterval = 0

    struct RemotePose {
        let from: Transform
        let to: Transform
        var elapsed: TimeInterval
        let parent: NetworkEntityID?
    }

    public init(world: World, transport: any NetworkTransport, role: Role,
                schema: NetworkReplicationSchema = .init(), configuration: NetworkSessionConfiguration = .init()) {
        self.world = world; self.transport = transport; self.role = role
        self.schema = schema; self.configuration = configuration
    }

    isolated deinit {
        if ownsTransport { transport.onEvent = nil }
        for entity in replicas.values { entity.removeFromParent() }
    }

    /// Begins a new session incarnation. A client requests a fresh baseline;
    /// packets from previous incarnations cannot overwrite this world's state.
    public func start() throws {
        guard !operating else { throw NetworkSessionError.reentrantOperation }
        operating = true; defer { operating = false }
        guard state == .idle || state == .stopped || state == .failed else { throw NetworkSessionError.invalidState }
        guard let world else { throw NetworkSessionError.worldUnavailable }
        guard world.networkSessionOwner == nil else { throw NetworkSessionError.worldInUse }
        guard transport.onEvent == nil else { throw NetworkSessionError.transportInUse }
        guard validPeer(localPeer), Set(transport.connectedPeers.map(\.id)).count == transport.connectedPeers.count,
              transport.connectedPeers.allSatisfy({ validPeer($0) && $0.id != localPeer.id }) else {
            throw NetworkSessionError.invalidState
        }
        if case .client(let host) = role, host == localPeer.id { throw NetworkSessionError.invalidState }
        try world.systems.add(NetworkReplicationSystem.self)
        generation &+= 1; sessionID = UUID(); joinID = UUID(); hostSession = nil
        sequence = 0; commandSequence = 0; lastError = nil
        elapsed = 0; joinElapsed = 0; queueOverflow = false
        incoming.removeAll(); queuedBytes = 0; joined.removeAll(); sentStructure.removeAll(); commandSequences.removeAll()
        peers = transport.connectedPeers.sorted { $0.id < $1.id }
        world.networkSessionOwner = self
        state = isHost ? .connected : .joining
        ownsTransport = true
        transport.onEvent = { [weak self] event in self?.enqueue(event) }
        let revision = generation
        do { if !isHost { try requestBaseline() } }
        catch { if generation == revision { fail(error) }; throw error }
    }

    /// Releases transport ownership. Client replicas are removed; local cameras,
    /// services and entities stay. Host entities remain available for a new match.
    /// The caller/coordinator owns disconnecting the underlying match.
    public func stop() {
        guard state != .idle && state != .stopped else { return }
        let wasOperating = operating; operating = true
        defer { operating = wasOperating }
        let wasConnectedHost = isHost && state == .connected
        let recipients = joined
        // Retire before calling the transport: a synchronous delegate may stop
        // again while termination is being sent.
        state = .stopped
        if wasConnectedHost {
            for (peer, join) in recipients {
                try? send(ReplicationPacket(kind: .end, session: sessionID, join: join, sequence: sequence), to: peer, reliably: true)
            }
        }
        tearDown()
    }

    /// Explicit update for headless worlds or application-owned paused networking.
    /// Do not call this in addition to the installed presentation system in the
    /// same frame. Reentrant updates are ignored; invalid deltas fail closed.
    public func update(deltaTime: TimeInterval) {
        guard state == .joining || state == .connected else { return }
        guard !operating else { return }
        guard deltaTime.isFinite, deltaTime >= 0 else { fail(NetworkSessionError.invalidState); return }
        guard world != nil else { fail(NetworkSessionError.worldUnavailable); return }
        operating = true
        defer { operating = false }
        let revision = generation
        do {
            guard !queueOverflow else { throw NetworkSessionError.capacityExceeded }
            let events = incoming; incoming.removeAll(keepingCapacity: true); queuedBytes = 0
            for event in events {
                guard generation == revision else { return }
                try receive(event)
            }
            guard generation == revision, state == .joining || state == .connected else { return }
            for id in Array(smoothing.keys) {
                let next = min(configuration.interpolationDuration, (smoothing[id]?.elapsed ?? 0) + min(deltaTime, 1))
                smoothing[id]?.elapsed = next
            }
            if isHost {
                elapsed += min(deltaTime, 1)
                if elapsed >= 1 / configuration.updatesPerSecond {
                    elapsed = 0; try publishState()
                }
            } else if state == .joining {
                // Retry a lost initial request. No unbounded catch-up burst.
                joinElapsed += min(deltaTime, 1)
                if joinElapsed >= 1 { joinElapsed = 0; try requestBaseline() }
            }
        } catch { if generation == revision { fail(error) } }
    }

    /// Publishes a complete host state immediately. Complete frames are bounded
    /// and self-contained, so losing one pose frame never loses a spawn forever.
    public func synchronize() throws {
        guard !operating else { throw NetworkSessionError.reentrantOperation }
        guard isHost else { throw NetworkSessionError.notHost }
        guard state == .connected else { throw NetworkSessionError.notConnected }
        operating = true; defer { operating = false }
        let revision = generation
        do { try publishState() } catch { if generation == revision { fail(error) }; throw error }
    }

    /// Sends an ordered, reliable application command to the host. Host-side
    /// validation is mandatory; the data never directly edits a component.
    public func sendCommand(_ data: Data) throws {
        guard !operating else { throw NetworkSessionError.reentrantOperation }
        guard case .client(let host) = role, state == .connected, let hostSession else {
            throw NetworkSessionError.notConnected
        }
        guard data.count <= configuration.maximumCommandBytes else { throw NetworkSessionError.packetTooLarge }
        guard commandSequence < UInt64.max else { throw NetworkSessionError.capacityExceeded }
        commandSequence += 1
        try send(ReplicationPacket(kind: .command, session: hostSession, join: joinID,
                                   sequence: commandSequence, command: data), to: host, reliably: true)
    }

    /// Finds a replica or authoritative entity by network identity. O(n) on a host.
    public func entity(withNetworkID id: NetworkEntityID) -> Entity? {
        if !isHost { return replicas[id] }
        return world?.allEntities.first { $0.components[SynchronizationComponent.self]?.id == id }
    }

    func presentedTransform(for entity: Entity) -> Transform? {
        guard !isHost, state == .connected, let sync = entity.components[SynchronizationComponent.self],
              sync.interpolates, replicas[sync.id] === entity, let pose = smoothing[sync.id],
              entity.transform == pose.to, configuration.interpolationDuration > 0 else { return nil }
        return Self.mix(pose.from, pose.to, alpha: min(1, pose.elapsed / configuration.interpolationDuration))
    }

    private func enqueue(_ event: NetworkTransportEvent) {
        guard state == .joining || state == .connected else { return }
        let bytes: Int
        if case .received(let data, _) = event { bytes = data.count } else { bytes = 0 }
        guard bytes <= configuration.maximumPacketBytes, incoming.count < configuration.maximumQueuedMessages,
              queuedBytes + bytes <= configuration.maximumPacketBytes * configuration.maximumQueuedMessages else {
            queueOverflow = true; return
        }
        incoming.append(event); queuedBytes += bytes
    }

    private func receive(_ event: NetworkTransportEvent) throws {
        switch event {
        case .failed(let message): throw NetworkSessionError.transport(message)
        case .connected(let peer):
            guard validPeer(peer), peer.id != localPeer.id else { throw NetworkSessionError.invalidPacket }
            if !peers.contains(where: { $0.id == peer.id }) { peers.append(peer); peers.sort { $0.id < $1.id } }
            if case .client(let host) = role, host == peer.id, state == .joining { try requestBaseline() }
        case .disconnected(let peer):
            guard peers.contains(where: { $0.id == peer }) else { return }
            peers.removeAll { $0.id == peer }; joined[peer] = nil; commandSequences[peer] = nil; sentStructure[peer] = nil
            if case .client(let host) = role, peer == host { throw NetworkSessionError.hostDisconnected }
            world?.publish(NetworkEvents.PeerLeft(peerID: peer))
        case .received(let data, let sender):
            guard peers.contains(where: { $0.id == sender }) else { return }
            if case .client(let host) = role, sender != host { return }
            let packet: ReplicationPacket
            do { packet = try JSONDecoder().decode(ReplicationPacket.self, from: data) }
            catch { throw NetworkSessionError.invalidPacket }
            guard packet.version == 1 else { throw NetworkSessionError.incompatibleVersion }
            if isHost { try receiveOnHost(packet, sender: sender) }
            else { try receiveOnClient(packet, sender: sender) }
        }
    }

    private func receiveOnHost(_ packet: ReplicationPacket, sender: NetworkPeerID) throws {
        switch packet.kind {
        case .hello:
            guard packet.entities.isEmpty, packet.command == nil else { throw NetworkSessionError.invalidPacket }
            let revision = generation
            let changed = joined[sender] != packet.join
            joined[sender] = packet.join
            if changed { commandSequences[sender] = 0; sentStructure[sender] = nil }
            try publishState(only: sender, baseline: true)
            guard generation == revision else { return }
            if changed, let peer = peers.first(where: { $0.id == sender }) {
                world?.publish(NetworkEvents.PeerJoined(peer: peer))
            }
        case .command:
            guard packet.session == sessionID, joined[sender] == packet.join else { return }
            guard let data = packet.command, packet.entities.isEmpty,
                  data.count <= configuration.maximumCommandBytes else { throw NetworkSessionError.invalidPacket }
            guard packet.sequence > (commandSequences[sender] ?? 0) else { return }
            commandSequences[sender] = packet.sequence
            world?.publish(NetworkEvents.CommandReceived(data: data, sender: sender))
        case .state, .end:
            // A client never has authority to publish entity state or end a match.
            throw NetworkSessionError.notHost
        }
    }

    private func receiveOnClient(_ packet: ReplicationPacket, sender: NetworkPeerID) throws {
        guard case .client(let host) = role, sender == host, packet.join == joinID else { return }
        if packet.kind == .end {
            guard packet.session == hostSession else { return }
            throw NetworkSessionError.hostDisconnected
        }
        guard packet.kind == .state else { throw NetworkSessionError.invalidPacket }
        guard hostSession != nil || packet.baseline else { return }
        guard hostSession == nil || hostSession == packet.session else { return }
        guard packet.sequence > sequence else { return }
        let revision = generation
        let decoded: [NetworkEntityID: [String: any Component]]
        do { decoded = try validate(packet.entities) }
        catch { throw error as? NetworkSessionError ?? .invalidPacket }
        guard generation == revision else { return }
        let first = hostSession == nil
        try apply(packet.entities, decoded: decoded, first: first, revision: revision)
        guard generation == revision else { return }
        hostSession = packet.session; sequence = packet.sequence; state = .connected
        replicatedEntityCount = replicas.count
        if first, let peer = peers.first(where: { $0.id == host }) { world?.publish(NetworkEvents.PeerJoined(peer: peer)) }
        guard generation == revision else { return }
        world?.publish(NetworkEvents.DidApplyState(sequence: sequence, entityCount: replicas.count))
    }

    private func requestBaseline() throws {
        guard case .client(let host) = role, peers.contains(where: { $0.id == host }) else { return }
        try send(ReplicationPacket(kind: .hello, session: sessionID, join: joinID, sequence: 0), to: host, reliably: true)
    }

    private func publishState(only recipient: NetworkPeerID? = nil, baseline: Bool = false) throws {
        guard let world else { throw NetworkSessionError.worldUnavailable }
        let revision = generation
        let records = try capture(world)
        guard revision == generation else { return }
        guard sequence < UInt64.max else { throw NetworkSessionError.capacityExceeded }
        sequence += 1; replicatedEntityCount = records.count
        for peer in joined.keys.sorted() where recipient == nil || recipient == peer {
            guard revision == generation, let join = joined[peer] else { return }
            let structure = records.map { record in
                ReplicatedEntity(id: record.id, parent: record.parent, name: record.name, isEnabled: record.isEnabled,
                                 owner: record.owner, interpolates: record.interpolates, selected: record.selected,
                                 components: record.components.map {
                                     $0.name == "transform" ? ReplicatedComponent(name: "transform", value: Data()) : $0
                                 })
            }
            let packet = ReplicationPacket(kind: .state, session: sessionID, join: join,
                                           sequence: sequence, baseline: baseline, entities: records)
            let data = try encode(packet)
            let reliable = baseline || sentStructure[peer] != structure || data.count > 1000
            try transport.send(data, to: peer, reliably: reliable)
            guard revision == generation else { return }
            sentStructure[peer] = structure
        }
    }

    private func capture(_ world: World) throws -> [ReplicatedEntity] {
        let entities = world.allEntities.filter { $0.components.has(SynchronizationComponent.self) }
        guard entities.count <= configuration.maximumEntities else { throw NetworkSessionError.capacityExceeded }
        let records = try entities.map { entity -> ReplicatedEntity in
            let sync = entity.components[SynchronizationComponent.self]!
            let parent: NetworkEntityID?
            if entity.parent === world.root { parent = nil }
            else {
                guard let value = entity.parent?.components[SynchronizationComponent.self]?.id else { throw NetworkSessionError.invalidState }
                parent = value
            }
            var components: [ReplicatedComponent] = []
            for name in sync.components.sorted() {
                guard let entry = schema.entries[name] else { throw NetworkSessionError.invalidSchema }
                if let value = entity.storage[ObjectIdentifier(entry.type)] {
                    components.append(ReplicatedComponent(name: name, value: try entry.encode(value)))
                }
            }
            return ReplicatedEntity(id: sync.id, parent: parent, name: entity.name, isEnabled: entity.isEnabled,
                                    owner: sync.owner, interpolates: sync.interpolates,
                                    selected: sync.components.sorted(), components: components)
        }.sorted { $0.id < $1.id }
        _ = try validate(records)
        return records
    }

    private func validate(_ records: [ReplicatedEntity]) throws -> [NetworkEntityID: [String: any Component]] {
        try NetworkRecordValidation.decode(records, schema: schema, maximumEntities: configuration.maximumEntities)
    }

    private func apply(_ records: [ReplicatedEntity], decoded: [NetworkEntityID: [String: any Component]],
                       first: Bool, revision: UInt64) throws {
        guard let world else { throw NetworkSessionError.worldUnavailable }
        let keep = Set(records.map(\.id))
        var reparented = Set<NetworkEntityID>()
        // Detach survivors first: a surviving child may be reparented while its
        // old parent disappears. Do not remove it as a side effect of despawn.
        for record in records {
            guard generation == revision else { return }
            if let entity = replicas[record.id], entity.parent?.components[SynchronizationComponent.self]?.id != record.parent {
                reparented.insert(record.id)
                entity.removeFromParent()
            }
        }
        for id in replicas.keys.sorted() where !keep.contains(id) {
            guard generation == revision else { return }
            let entity = replicas.removeValue(forKey: id)
            replicaComponents[id] = nil; smoothing[id] = nil
            entity?.removeFromParent()
        }
        for record in records {
            guard generation == revision else { return }
            if replicas[record.id] == nil { replicas[record.id] = Entity() }
            let entity = replicas[record.id]!
            let oldParent = entity.parent?.components[SynchronizationComponent.self]?.id
            let oldPose = presentedTransform(for: entity) ?? entity.transform
            let isNew = replicaComponents[record.id] == nil
            entity.name = record.name
            entity.isEnabled = record.isEnabled
            guard generation == revision else { return }
            let values = decoded[record.id]!
            for name in replicaComponents[record.id, default: []].subtracting(values.keys) {
                schema.entries[name]?.remove(entity)
                guard generation == revision else { return }
            }
            for name in values.keys.sorted() {
                entity.components.set([values[name]!])
                guard generation == revision else { return }
            }
            entity.components.set(SynchronizationComponent(id: record.id, owner: record.owner,
                                                          components: record.selected, interpolates: record.interpolates))
            guard generation == revision else { return }
            replicaComponents[record.id] = Set(values.keys)
            if !first, !isNew, !reparented.contains(record.id), oldParent == record.parent, record.interpolates, let target = values["transform"] as? Transform {
                smoothing[record.id] = RemotePose(from: oldPose, to: target, elapsed: 0, parent: record.parent)
            } else { smoothing[record.id] = nil }
        }
        // All identities and values exist before attachment events run.
        var attached = Set<NetworkEntityID>()
        func attach(_ record: ReplicatedEntity) throws {
            guard generation == revision, !attached.contains(record.id) else { return }
            if let parentID = record.parent, let parentRecord = records.first(where: { $0.id == parentID }) { try attach(parentRecord) }
            guard generation == revision, let entity = replicas[record.id] else { return }
            let parent = record.parent.flatMap { replicas[$0] } ?? world.root
            if entity.parent !== parent { try entity.setParent(parent) }
            attached.insert(record.id)
        }
        for record in records { try attach(record) }
    }

    private func encode(_ packet: ReplicationPacket) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(packet)
        guard data.count <= configuration.maximumPacketBytes else { throw NetworkSessionError.packetTooLarge }
        return data
    }
    private func send(_ packet: ReplicationPacket, to peer: NetworkPeerID, reliably: Bool) throws {
        try transport.send(encode(packet), to: peer, reliably: reliably)
    }
    private func validPeer(_ peer: NetworkPeer) -> Bool {
        !peer.id.rawValue.isEmpty && peer.id.rawValue.utf8.count <= 256 && peer.displayName.utf8.count <= 512
    }
    private func fail(_ error: any Error) {
        let failure = error as? NetworkSessionError ?? .transport(String(describing: error))
        let wasOperating = operating; operating = true
        defer { operating = wasOperating }
        state = .failed; lastError = failure; tearDown()
        world?.publish(NetworkEvents.Failed(error: failure))
    }
    private func tearDown() {
        generation &+= 1
        if ownsTransport { transport.onEvent = nil; ownsTransport = false }
        if world?.networkSessionOwner === self { world?.networkSessionOwner = nil }
        incoming.removeAll(); queuedBytes = 0; queueOverflow = false
        joined.removeAll(); sentStructure.removeAll(); commandSequences.removeAll(); peers.removeAll()
        let removed = replicas.values
        replicas.removeAll(); replicaComponents.removeAll(); smoothing.removeAll(); replicatedEntityCount = 0
        for entity in removed { entity.removeFromParent() }
    }
    private static func mix(_ a: Transform, _ b: Transform, alpha: Double) -> Transform {
        func lerp(_ x: Float, _ y: Float) -> Float { Float(Double(x) + (Double(y) - Double(x)) * alpha) }
        var angle = (Double(b.rotation) - Double(a.rotation)).truncatingRemainder(dividingBy: 2 * .pi)
        if angle > .pi { angle -= 2 * .pi }; if angle < -.pi { angle += 2 * .pi }
        return Transform(translation: [lerp(a.translation.x, b.translation.x), lerp(a.translation.y, b.translation.y)],
                         rotation: Float(Double(a.rotation) + angle * alpha),
                         scale: [lerp(a.scale.x, b.scale.x), lerp(a.scale.y, b.scale.y)], zPosition: lerp(a.zPosition, b.zPosition))
    }
}

/// Installed automatically by a started session. It runs after simulation and
/// native physics; rules needing incoming commands first may call the session
/// explicitly and disable this system through `world.systems`.
public struct NetworkReplicationSystem: System {
    public static var phase: SystemPhase { .presentation }
    public init(world: World) {}
    public mutating func update(context: UpdateContext) { context.world.networkSessionOwner?.update(deltaTime: context.unscaledDeltaTime) }
}

extension World {
    /// Whether a replication session currently owns this world.
    public var isNetworkSessionActive: Bool { networkSessionOwner != nil }

    @_spi(Backend)
    public var hasNetworkTransformPresentation: Bool {
        guard let owner = networkSessionOwner else { return false }
        return !owner.isHost && owner.state == .connected
    }

    /// Read-only remote presentation. Canonical transforms and snapshot/query
    /// values always remain the latest validated host values.
    @_spi(Backend)
    public func networkPresentedTransform(for entity: Entity) -> Transform? {
        networkSessionOwner?.presentedTransform(for: entity)
    }
}

extension NetworkSession {
    /// Captures a host-approved inert checkpoint using only this session's replication allowlist.
    /// Persist the returned value in application-owned storage before an interruption. Client replicas cannot author one.
    public func recoveryCheckpoint(compatibilityID: String, scope: String? = nil, applicationState: Data = Data(), at date: Date = Date()) throws -> NetworkRecoveryCheckpoint {
        guard isHost else { throw NetworkSessionError.notHost }
        guard state == .connected, !operating, let world else { throw NetworkSessionError.invalidState }
        operating = true; defer { operating = false }
        let revision = generation
        let records = try capture(world)
        guard generation == revision, state == .connected else { throw NetworkSessionError.invalidState }
        _ = try encode(ReplicationPacket(kind: .state, session: sessionID, join: UUID(), sequence: sequence, baseline: true, entities: records))
        return try NetworkRecoveryCheckpoint(records: records, compatibilityID: compatibilityID, scope: scope, host: localPeer.id,
            peers: ([localPeer.id] + peers.map(\.id)).sorted(), sessionID: sessionID, sequence: sequence,
            applicationState: applicationState, at: date)
    }
}
