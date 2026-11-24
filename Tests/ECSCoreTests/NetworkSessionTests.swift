import Foundation
import Testing
@_spi(Backend) @testable import ECSCore

private struct NetworkTestHealth: Component, Codable, Equatable {
    var value: Int
}

private struct NetworkTestSecret: Component, Codable, Equatable {
    var value: String
}

// Cameras live in the renderer module. The core owns the selected entity and
// must preserve that selection, its local components and its local hierarchy.
private struct NetworkTestLocalCamera: Component {}

private struct NetworkTestLocalReference: EntityReferencingComponent, Codable {
    var target: Entity.ID
    mutating func remapEntityReferences(_ context: EntityReferenceRemapping) {}
}

@MainActor private final class NetworkTestTransport: NetworkTransport {
    struct Sent {
        let data: Data
        let peer: NetworkPeerID
        let reliable: Bool
    }

    let localPeer: NetworkPeer
    var connectedPeers: [NetworkPeer]
    var onEvent: (@MainActor (NetworkTransportEvent) -> Void)?
    weak var remote: NetworkTestTransport?
    var sent: [Sent] = []
    var delivers = true
    var disconnectCount = 0
    var onSend: (@MainActor () -> Void)?

    init(_ name: String, peers: [NetworkPeer] = []) {
        localPeer = NetworkPeer(id: .init(rawValue: name), displayName: name)
        connectedPeers = peers
    }

    func send(_ data: Data, to peer: NetworkPeerID, reliably: Bool) throws {
        sent.append(Sent(data: data, peer: peer, reliable: reliably))
        onSend?()
        if delivers, let remote, remote.localPeer.id == peer {
            remote.onEvent?(.received(data, from: localPeer.id))
        }
    }

    func disconnect() {
        disconnectCount += 1
        connectedPeers = []
        remote?.connectedPeers = []
        remote?.onEvent?(.disconnected(localPeer.id))
    }

    func inject(_ packet: ReplicationPacket, from sender: NetworkPeerID) throws {
        onEvent?(.received(try JSONEncoder().encode(packet), from: sender))
    }

    func lastPacket(_ kind: ReplicationPacket.Kind) throws -> ReplicationPacket {
        let packets = try sent.map { try JSONDecoder().decode(ReplicationPacket.self, from: $0.data) }
        return try #require(packets.last { $0.kind == kind })
    }
}

@MainActor private func networkTestSchema() throws -> NetworkReplicationSchema {
    var schema = NetworkReplicationSchema()
    try schema.register(NetworkTestHealth.self, named: "health") { health in
        guard (0...100).contains(health.value) else { throw NetworkSessionError.invalidState }
    }
    try schema.register(NetworkTestSecret.self, named: "secret")
    return schema
}

@MainActor private func networkTestEntity(
    _ name: String = "replicated", id: NetworkEntityID = .init(),
    components: [String] = ["transform"], interpolates: Bool = true
) -> Entity {
    Entity(name: name, components: SynchronizationComponent(
        id: id, components: components, interpolates: interpolates
    ))
}

@MainActor private struct NetworkTestRig {
    let hostWorld = World()
    let clientWorld = World()
    let hostTransport = NetworkTestTransport("host")
    let clientTransport = NetworkTestTransport("client")
    let camera = Entity(name: "local-camera", components: NetworkTestLocalCamera())
    let local = Entity(name: "local-only", components: NetworkTestSecret(value: "local"))
    let host: NetworkSession
    let client: NetworkSession

    init(entities: [Entity] = [], schema: NetworkReplicationSchema? = nil,
         configuration: NetworkSessionConfiguration = .init(),
         clientConfiguration: NetworkSessionConfiguration? = nil,
         establish: Bool = true) throws {
        hostTransport.remote = clientTransport
        clientTransport.remote = hostTransport
        hostTransport.connectedPeers = [clientTransport.localPeer]
        clientTransport.connectedPeers = [hostTransport.localPeer]
        let schema = try schema ?? networkTestSchema()
        host = NetworkSession(world: hostWorld, transport: hostTransport, role: .host,
                              schema: schema, configuration: configuration)
        client = NetworkSession(world: clientWorld, transport: clientTransport,
                                role: .client(host: hostTransport.localPeer.id),
                                schema: schema, configuration: clientConfiguration ?? configuration)
        entities.forEach(hostWorld.addEntity)
        clientWorld.addEntity(camera)
        camera.addChild(local)
        camera.position = [7, 11]
        clientWorld.activeCamera = camera
        try host.start()
        try client.start()
        if establish {
            host.update(deltaTime: 0)
            client.update(deltaTime: 0)
            try #require(host.state == .connected && client.state == .connected)
        }
    }

    func push() throws {
        try host.synchronize()
        client.update(deltaTime: 0)
    }

    func replica(_ entity: Entity) throws -> Entity {
        let id = try #require(entity.components[SynchronizationComponent.self]?.id)
        return try #require(client.entity(withNetworkID: id))
    }

    func receive(_ packet: ReplicationPacket, from sender: NetworkPeerID? = nil) throws {
        try clientTransport.inject(packet, from: sender ?? hostTransport.localPeer.id)
        client.update(deltaTime: 0)
    }

    func expectLocalEntities() {
        #expect(camera.world === clientWorld && local.world === clientWorld)
        #expect(local.parent === camera && camera.parent === clientWorld.root)
        #expect(clientWorld.activeCamera === camera)
        #expect(camera.position == SIMD2<Float>(7, 11))
        #expect(local.components[NetworkTestSecret.self]?.value == "local")
    }
}

@MainActor @Suite struct NetworkSessionTests {
    @Test func baselinePreservesLocalEntitiesAndUsesStableNetworkIdentity() throws {
        let source = networkTestEntity("player", components: ["transform", "health"])
        source.position = [13, 29]
        source.components.set(NetworkTestHealth(value: 75))
        source.components.set(NetworkTestSecret(value: "host-private"))
        let rig = try NetworkTestRig(entities: [source])
        defer { rig.client.stop(); rig.host.stop() }
        let replica = try rig.replica(source)
        #expect(replica !== source && replica.id != source.id)
        #expect(replica.components[SynchronizationComponent.self]?.id == source.components[SynchronizationComponent.self]?.id)
        #expect(replica.name == "player" && replica.transform == source.transform)
        #expect(replica.components[NetworkTestHealth.self]?.value == 75)
        #expect(replica.components[NetworkTestSecret.self] == nil)
        #expect(rig.host.replicatedEntityCount == 1 && rig.client.replicatedEntityCount == 1)
        rig.expectLocalEntities()

        source.position = [31, 47]
        try rig.push()
        #expect(try rig.replica(source) === replica)
        #expect(replica.transform == source.transform)
        rig.client.stop()
        #expect(replica.world == nil && rig.client.replicatedEntityCount == 0)
        #expect(source.world === rig.hostWorld)
        rig.expectLocalEntities()
    }

    @Test func selectedComponentsAddRemoveAndDeselectWithoutTouchingLocalComponents() throws {
        let source = networkTestEntity(components: ["transform", "health"])
        let rig = try NetworkTestRig(entities: [source])
        defer { rig.client.stop(); rig.host.stop() }
        let replica = try rig.replica(source)
        replica.components.set(NetworkTestSecret(value: "client-private"))
        #expect(replica.components[NetworkTestHealth.self] == nil)
        source.components.set(NetworkTestHealth(value: 40))
        try rig.push()
        #expect(replica.components[NetworkTestHealth.self]?.value == 40)
        source.components.remove(NetworkTestHealth.self)
        try rig.push()
        #expect(replica.components[NetworkTestHealth.self] == nil)
        source.components.set(NetworkTestHealth(value: 60))
        try rig.push()
        source.components[SynchronizationComponent.self]?.components = ["transform"]
        try rig.push()
        #expect(replica.components[NetworkTestHealth.self] == nil)
        #expect(source.components[NetworkTestHealth.self]?.value == 60)
        #expect(replica.components[NetworkTestSecret.self]?.value == "client-private")
        #expect(rig.hostTransport.sent.allSatisfy { $0.reliable })
    }

    @Test func reparentSurvivorBeforeRemovingOldParentAndPropagateActivation() throws {
        let parent = networkTestEntity("old-parent")
        let child = networkTestEntity("child")
        let destination = networkTestEntity("destination")
        parent.isEnabled = false
        parent.addChild(child)
        let rig = try NetworkTestRig(entities: [parent, destination])
        defer { rig.client.stop(); rig.host.stop() }
        let oldReplica = try rig.replica(parent), replica = try rig.replica(child)
        let target = try rig.replica(destination)
        #expect(replica.parent === oldReplica && replica.isEnabled && !replica.isActive)
        let revision = replica.activationRevision
        try child.setParent(destination)
        parent.removeFromParent()
        child.position = [23, 19]
        try rig.push()
        #expect(try rig.replica(child) === replica)
        #expect(replica.parent === target && replica.world === rig.clientWorld && replica.isActive)
        #expect(replica.activationRevision != revision)
        #expect(oldReplica.world == nil)
        #expect(rig.client.entity(withNetworkID: parent.components[SynchronizationComponent.self]!.id) == nil)
        #expect(replica.transform == child.transform)
        #expect(rig.clientWorld.networkPresentedTransform(for: replica) == nil)

        destination.isEnabled = false
        child.isEnabled = false
        try rig.push()
        #expect(!target.isEnabled && !replica.isEnabled && !replica.isActive)
        destination.isEnabled = true
        try rig.push()
        #expect(target.isActive && !replica.isActive)
        destination.removeFromParent()
        try rig.push()
        #expect(target.world == nil && replica.world == nil)
        #expect(rig.client.replicatedEntityCount == 0)
        rig.expectLocalEntities()
    }

    @Test func schemaRequiresExplicitSafeUniqueNamesAndTypes() throws {
        var schema = NetworkReplicationSchema()
        #expect(throws: NetworkSessionError.invalidSchema) { try schema.register(NetworkTestHealth.self, named: "") }
        #expect(throws: NetworkSessionError.invalidSchema) {
            try schema.register(NetworkTestHealth.self, named: String(repeating: "x", count: 65))
        }
        try schema.register(NetworkTestHealth.self, named: "health")
        #expect(throws: NetworkSessionError.invalidSchema) { try schema.register(NetworkTestSecret.self, named: "health") }
        #expect(throws: NetworkSessionError.invalidSchema) { try schema.register(NetworkTestHealth.self, named: "alias") }
        #expect(throws: NetworkSessionError.invalidSchema) { try schema.register(Transform.self, named: "pose") }
        #expect(throws: NetworkSessionError.invalidSchema) { try schema.register(SynchronizationComponent.self, named: "sync") }
        #expect(throws: NetworkSessionError.invalidSchema) { try schema.register(NetworkTestLocalReference.self, named: "local-reference") }
    }

    @Test func cloningCreatesFreshNetworkUUID() throws {
        let source = networkTestEntity()
        source.components[SynchronizationComponent.self]?.owner = .init(rawValue: "owner")
        let clone = source.clone()
        let original = try #require(source.components[SynchronizationComponent.self])
        let copied = try #require(clone.components[SynchronizationComponent.self])
        #expect(source.id != clone.id && original.id != copied.id)
        #expect(original.owner == copied.owner && original.components == copied.components)
    }

    @Test func clientCannotPublishAndNonHostCannotSpoofStateOrEnd() throws {
        let source = networkTestEntity()
        let rig = try NetworkTestRig(entities: [source])
        defer { rig.client.stop(); rig.host.stop() }
        #expect(throws: NetworkSessionError.notHost) { try rig.client.synchronize() }
        let replica = try rig.replica(source)
        let attacker = NetworkPeer(id: .init(rawValue: "attacker"), displayName: "Attacker")
        rig.clientTransport.onEvent?(.connected(attacker))
        rig.client.update(deltaTime: 0)
        var packet = try rig.hostTransport.lastPacket(.state)
        packet = ReplicationPacket(kind: .state, session: packet.session, join: packet.join,
                                   sequence: packet.sequence + 100, baseline: true, entities: [])
        try rig.receive(packet, from: attacker.id)
        try rig.receive(ReplicationPacket(kind: .end, session: packet.session, join: packet.join,
                                         sequence: packet.sequence), from: attacker.id)
        rig.clientTransport.onEvent?(.received(Data("malformed".utf8), from: attacker.id))
        rig.client.update(deltaTime: 0)
        #expect(rig.client.state == .connected && rig.client.lastError == nil)
        #expect(try rig.replica(source) === replica)
        #expect(rig.client.sequence < packet.sequence)
    }

    @Test(arguments: [ReplicationPacket.Kind.state, .end])
    func hostRejectsClientAuthority(kind: ReplicationPacket.Kind) throws {
        let source = networkTestEntity()
        let rig = try NetworkTestRig(entities: [source])
        defer { rig.client.stop(); rig.host.stop() }
        let state = try rig.hostTransport.lastPacket(.state)
        let attack = ReplicationPacket(kind: kind, session: state.session, join: state.join,
                                       sequence: 999, entities: [])
        try rig.hostTransport.inject(attack, from: rig.clientTransport.localPeer.id)
        rig.host.update(deltaTime: 0)
        #expect(rig.host.state == .failed && rig.host.lastError == .notHost)
        #expect(source.world === rig.hostWorld && source.position == .zero)
    }
}

@MainActor extension NetworkSessionTests {
    @Test func smoothingUsesPresentationSPIWhileCanonicalPoseAndSnapshotStayAtHostTarget() throws {
        let source = networkTestEntity()
        source.transform = Transform(translation: [0, 10], rotation: 170 * .pi / 180,
                                     scale: [1, 2], zPosition: 2)
        let rig = try NetworkTestRig(entities: [source], configuration: .init(interpolationDuration: 1))
        defer { rig.client.stop(); rig.host.stop() }
        let replica = try rig.replica(source)
        #expect(rig.clientWorld.networkPresentedTransform(for: replica) == nil)
        let initial = source.transform
        source.transform = Transform(translation: [20, 30], rotation: -170 * .pi / 180,
                                     scale: [3, 4], zPosition: 6)
        try rig.push()
        #expect(replica.transform == source.transform)
        #expect(rig.clientWorld.networkPresentedTransform(for: replica) == initial)
        rig.client.update(deltaTime: 0.5)
        let halfway = try #require(rig.clientWorld.networkPresentedTransform(for: replica))
        #expect(halfway.translation == SIMD2<Float>(10, 20))
        #expect(halfway.scale == SIMD2<Float>(2, 3) && halfway.zPosition == 4)
        #expect(abs(abs(halfway.rotation) - Float.pi) < 0.0001)
        #expect(replica.transform == source.transform)
        let saved = replica.snapshot().makeEntity()
        #expect(saved.transform == source.transform)
        rig.client.update(deltaTime: 0.5)
        let finished = try #require(rig.clientWorld.networkPresentedTransform(for: replica))
        #expect(finished.translation == source.position && replica.transform == source.transform)
        #expect(rig.hostWorld.networkPresentedTransform(for: source) == nil)
        #expect(rig.clientWorld.networkPresentedTransform(for: rig.camera) == nil)
    }

    @Test func newTargetStartsFromCurrentPresentedPoseAndLocalEditsInvalidateSmoothing() throws {
        let source = networkTestEntity()
        let rig = try NetworkTestRig(entities: [source], configuration: .init(interpolationDuration: 1))
        defer { rig.client.stop(); rig.host.stop() }
        let replica = try rig.replica(source)
        source.position.x = 20
        try rig.push()
        rig.client.update(deltaTime: 0.5)
        #expect(rig.clientWorld.networkPresentedTransform(for: replica)?.translation.x == 10)
        source.position.x = 40
        try rig.push()
        #expect(replica.position.x == 40)
        #expect(rig.clientWorld.networkPresentedTransform(for: replica)?.translation.x == 10)
        rig.client.update(deltaTime: 0.5)
        #expect(rig.clientWorld.networkPresentedTransform(for: replica)?.translation.x == 25)
        replica.position.x = 99
        #expect(rig.clientWorld.networkPresentedTransform(for: replica) == nil)
        #expect(replica.position.x == 99)
    }

    @Test(arguments: [false, true])
    func smoothingOptOutOrZeroDurationPresentsCanonicalPose(zeroDuration: Bool) throws {
        let source = networkTestEntity(interpolates: zeroDuration)
        let rig = try NetworkTestRig(entities: [source], configuration: .init(interpolationDuration: zeroDuration ? 0 : 1))
        defer { rig.client.stop(); rig.host.stop() }
        let replica = try rig.replica(source)
        source.position = [100, 200]
        try rig.push()
        #expect(replica.transform == source.transform)
        #expect(rig.clientWorld.networkPresentedTransform(for: replica) == nil)
    }

    @Test func presentationSystemUsesUnscaledCadenceAndExplicitUpdatesWorkWhilePaused() throws {
        let source = networkTestEntity()
        let rig = try NetworkTestRig(entities: [source], configuration: .init(updatesPerSecond: 4))
        defer { rig.client.stop(); rig.host.stop() }
        let replica = try rig.replica(source)
        #expect(rig.hostWorld.systems.contains(NetworkReplicationSystem.self))
        rig.hostWorld.timeScale = 0.5
        source.position.x = 5
        let sent = rig.hostTransport.sent.count
        rig.hostWorld.update(deltaTime: 0.125)
        #expect(rig.hostTransport.sent.count == sent)
        rig.hostWorld.update(deltaTime: 0.125)
        #expect(rig.hostTransport.sent.count == sent + 1)
        rig.clientWorld.update(deltaTime: 0)
        #expect(replica.position.x == 5)
        rig.hostWorld.isPaused = true
        source.position.x = 10
        rig.hostWorld.update(deltaTime: 1)
        #expect(rig.hostTransport.sent.count == sent + 1)
        rig.host.update(deltaTime: 0.25)
        rig.clientWorld.isPaused = true
        rig.client.update(deltaTime: 0)
        #expect(replica.position.x == 10)
    }

    @Test func configurationBoundsAndLargeDeltasNeverProduceCatchUpBursts() throws {
        let limits = NetworkSessionConfiguration(updatesPerSecond: .infinity, interpolationDuration: .nan,
            maximumEntities: .max, maximumPacketBytes: .max, maximumQueuedMessages: .max, maximumCommandBytes: .max)
        #expect(limits.updatesPerSecond == 10 && limits.interpolationDuration == 0.1)
        #expect(limits.maximumEntities == 512 && limits.maximumPacketBytes == 48_000)
        #expect(limits.maximumQueuedMessages == 1024 && limits.maximumCommandBytes == 16_000)
        let minimum = NetworkSessionConfiguration(updatesPerSecond: -1, interpolationDuration: -1,
            maximumEntities: 0, maximumPacketBytes: 0, maximumQueuedMessages: 0, maximumCommandBytes: 0)
        #expect(minimum.updatesPerSecond == 1 && minimum.interpolationDuration == 0)
        #expect(minimum.maximumEntities == 1 && minimum.maximumPacketBytes == 512)
        #expect(minimum.maximumQueuedMessages == 1 && minimum.maximumCommandBytes == 1)
        let rig = try NetworkTestRig()
        defer { rig.client.stop(); rig.host.stop() }
        let sent = rig.hostTransport.sent.count
        rig.host.update(deltaTime: 1_000_000)
        #expect(rig.hostTransport.sent.count == sent + 1)
        rig.host.update(deltaTime: 0)
        #expect(rig.hostTransport.sent.count == sent + 1)
    }

    @Test(arguments: [Double.nan, .infinity, -1])
    func invalidUpdateDeltasFailClosed(delta: Double) throws {
        let rig = try NetworkTestRig()
        defer { rig.client.stop(); rig.host.stop() }
        rig.client.update(deltaTime: delta)
        #expect(rig.client.state == .failed && rig.client.lastError == .invalidState)
        #expect(rig.clientTransport.onEvent == nil)
        rig.expectLocalEntities()
    }

    @Test func reentrantSynchronizeAndStartAreRejectedDuringHostSend() throws {
        let rig = try NetworkTestRig()
        defer { rig.hostTransport.onSend = nil; rig.client.stop(); rig.host.stop() }
        var errors: [NetworkSessionError] = []
        rig.hostTransport.onSend = {
            do { try rig.host.synchronize() }
            catch let error as NetworkSessionError { errors.append(error) }
            catch { Issue.record("Unexpected synchronization error: \(error)") }
            do { try rig.host.start() }
            catch let error as NetworkSessionError { errors.append(error) }
            catch { Issue.record("Unexpected start error: \(error)") }
            rig.host.update(deltaTime: 1)
        }
        let sent = rig.hostTransport.sent.count
        try rig.host.synchronize()
        #expect(errors == [.reentrantOperation, .reentrantOperation])
        #expect(rig.host.state == .connected && rig.hostTransport.sent.count == sent + 1)
    }

    @Test func stopDuringHostSendCancelsRemainingRecipients() throws {
        let rig = try NetworkTestRig()
        defer { rig.hostTransport.onSend = nil; rig.client.stop(); rig.host.stop() }
        let other = NetworkPeer(id: .init(rawValue: "zzz"), displayName: "Other")
        rig.hostTransport.onEvent?(.connected(other))
        try rig.hostTransport.inject(ReplicationPacket(kind: .hello, session: UUID(), join: UUID(), sequence: 0), from: other.id)
        rig.host.update(deltaTime: 0)
        var stopped = false
        rig.hostTransport.onSend = {
            guard !stopped else { return }
            stopped = true
            rig.host.stop()
        }
        let sent = rig.hostTransport.sent.count
        try rig.host.synchronize()
        let after = try rig.hostTransport.sent.dropFirst(sent).map { try JSONDecoder().decode(ReplicationPacket.self, from: $0.data) }
        #expect(stopped && rig.host.state == .stopped)
        #expect(after.filter { $0.kind == .state }.count == 1)
        #expect(rig.hostTransport.onEvent == nil && rig.hostWorld.networkSessionOwner == nil)
    }

    @Test func stopReenteredFromEndSendDoesNotRecursivelySendEnd() throws {
        let rig = try NetworkTestRig()
        defer { rig.hostTransport.onSend = nil; rig.client.stop(); rig.host.stop() }
        var callbacks = 0
        rig.hostTransport.onSend = {
            callbacks += 1
            // Bound a regression to one extra call instead of overflowing the
            // stack: stop must mark itself stopped before sending its end frame.
            if callbacks == 1 { rig.host.stop() }
        }
        let sent = rig.hostTransport.sent.count
        rig.host.stop()
        #expect(callbacks == 1 && rig.hostTransport.sent.count == sent + 1)
        #expect(rig.host.state == .stopped && rig.hostTransport.onEvent == nil)
        #expect(rig.hostTransport.disconnectCount == 0)
        rig.client.update(deltaTime: 0)
        #expect(rig.client.lastError == .hostDisconnected)
    }

    @Test func inMemoryLatencyLossLateJoinAndDisconnectConvergeWithControlledClock() throws {
        let network = InMemoryNetwork(latency: 0.25, unreliableLossRate: 1, seed: 42)
        let hostPeer = NetworkPeer(id: .init(rawValue: "host"), displayName: "Host")
        let clientPeer = NetworkPeer(id: .init(rawValue: "client"), displayName: "Client")
        let hostTransport = try network.connect(hostPeer)
        let hostWorld = World(), clientWorld = World()
        let source = networkTestEntity("player")
        hostWorld.addEntity(source)
        let host = NetworkSession(world: hostWorld, transport: hostTransport, role: .host)
        try host.start()
        let clientTransport = try network.connect(clientPeer)
        let client = NetworkSession(world: clientWorld, transport: clientTransport, role: .client(host: hostPeer.id))
        try client.start()
        defer { client.stop(); host.stop(); clientTransport.disconnect(); hostTransport.disconnect() }
        let step: @MainActor (TimeInterval) -> Void = { delta in
            network.advance(by: delta)
            host.update(deltaTime: 0)
            client.update(deltaTime: 0)
        }
        step(0)
        #expect(client.state == .joining)
        step(0.25)
        #expect(client.state == .joining) // Hello arrived, baseline remains in flight.
        step(0.25)
        try #require(client.state == .connected)
        let id = try #require(source.components[SynchronizationComponent.self]?.id)
        let replica = try #require(client.entity(withNetworkID: id))
        #expect(replica.position == .zero && replica.id != source.id)

        source.position.x = 10
        try host.synchronize() // Pose-only packet is deliberately lost.
        step(1)
        #expect(replica.position == .zero)
        network.unreliableLossRate = 0
        try host.synchronize() // A complete later frame repairs the missed pose.
        step(0)
        #expect(replica.position == .zero)
        step(0.25)
        #expect(replica.position.x == 10)

        // Structural changes must arrive reliably even with total pose loss.
        network.unreliableLossRate = 1
        let spawned = networkTestEntity("spawned")
        hostWorld.addEntity(spawned)
        try host.synchronize()
        step(0.25)
        let spawnedID = try #require(spawned.components[SynchronizationComponent.self]?.id)
        #expect(client.entity(withNetworkID: spawnedID) != nil)

        let lateWorld = World()
        let lateTransport = try network.connect(NetworkPeer(id: .init(rawValue: "late"), displayName: "Late"))
        let late = NetworkSession(world: lateWorld, transport: lateTransport, role: .client(host: hostPeer.id))
        try late.start()
        defer { late.stop(); lateTransport.disconnect() }
        step(0)
        late.update(deltaTime: 0)
        step(0.25)
        late.update(deltaTime: 0)
        step(0.25)
        late.update(deltaTime: 0)
        #expect(late.state == .connected && late.replicatedEntityCount == 2)
        #expect(late.entity(withNetworkID: id)?.position.x == 10)
        #expect(late.entity(withNetworkID: id)?.id != replica.id)
        spawned.removeFromParent()
        try host.synchronize()
        step(0.25)
        late.update(deltaTime: 0)
        #expect(client.entity(withNetworkID: spawnedID) == nil && late.entity(withNetworkID: spawnedID) == nil)
        hostTransport.disconnect()
        step(0)
        late.update(deltaTime: 0)
        #expect(client.state == .failed && late.state == .failed)
        #expect(client.lastError == .hostDisconnected && late.lastError == .hostDisconnected)
        #expect(replica.world == nil && client.replicatedEntityCount == 0)
    }
}

private enum NetworkTestInvalidFrame: String, CaseIterable, Sendable {
    case unknownSchema, malformedComponent, nonfiniteTransform, customValidation
    case cycle, selfParent, missingParent, duplicateIdentity, duplicateSelection
    case unselectedComponent, duplicateComponent, oversizedName, invalidOwner, tooManySelected
}

@MainActor private func networkTestRecord(
    _ original: ReplicatedEntity, id: NetworkEntityID? = nil, parent: NetworkEntityID? = nil,
    name: String? = nil, owner: NetworkPeerID? = nil,
    selected: [String]? = nil, components: [ReplicatedComponent]? = nil
) -> ReplicatedEntity {
    ReplicatedEntity(id: id ?? original.id, parent: parent, name: name ?? original.name,
                     isEnabled: original.isEnabled, owner: owner ?? original.owner,
                     interpolates: original.interpolates, selected: selected ?? original.selected,
                     components: components ?? original.components)
}

@MainActor extension NetworkSessionTests {
    @Test(arguments: NetworkTestInvalidFrame.allCases)
    fileprivate func invalidFramesPreflightEveryEntityBeforeWorldWrites(_ invalid: NetworkTestInvalidFrame) throws {
        let first = networkTestEntity("first", components: ["transform", "health"])
        first.components.set(NetworkTestHealth(value: 10))
        let second = networkTestEntity("second")
        let rig = try NetworkTestRig(entities: [first, second])
        defer { rig.client.stop(); rig.host.stop() }
        let firstReplica = try rig.replica(first), secondReplica = try rig.replica(second)
        let originalSequence = rig.client.sequence
        var packet = try rig.hostTransport.lastPacket(.state)
        let a = try #require(packet.entities.first { $0.name == "first" })
        let b = try #require(packet.entities.first { $0.name == "second" })
        let changed = networkTestRecord(a, name: "must-not-apply", components: [
            ReplicatedComponent(name: "transform", value: try JSONEncoder().encode(Transform(translation: [99, 99]))),
            ReplicatedComponent(name: "health", value: try JSONEncoder().encode(NetworkTestHealth(value: 90)))
        ])
        var bad = b
        switch invalid {
        case .unknownSchema:
            bad = networkTestRecord(b, selected: ["unknown"])
        case .malformedComponent:
            bad = networkTestRecord(b, components: [.init(name: "transform", value: Data("{}".utf8))])
        case .nonfiniteTransform:
            let encoder = JSONEncoder()
            encoder.nonConformingFloatEncodingStrategy = .convertToString(
                positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
            bad = networkTestRecord(b, components: [.init(name: "transform", value: try encoder.encode(
                Transform(translation: [.nan, 0])))])
        case .customValidation:
            bad = networkTestRecord(b, selected: ["health"], components: [.init(name: "health", value:
                try JSONEncoder().encode(NetworkTestHealth(value: -1)))])
        case .cycle:
            bad = networkTestRecord(b, parent: a.id)
        case .selfParent:
            bad = networkTestRecord(b, parent: b.id)
        case .missingParent:
            bad = networkTestRecord(b, parent: .init())
        case .duplicateIdentity:
            bad = networkTestRecord(b, id: a.id)
        case .duplicateSelection:
            bad = networkTestRecord(b, selected: ["transform", "transform"])
        case .unselectedComponent:
            bad = networkTestRecord(b, selected: ["health"])
        case .duplicateComponent:
            bad = networkTestRecord(b, selected: ["transform", "health"], components: b.components + b.components)
        case .oversizedName:
            bad = networkTestRecord(b, name: String(repeating: "é", count: 129))
        case .invalidOwner:
            bad = networkTestRecord(b, owner: .init(rawValue: ""))
        case .tooManySelected:
            bad = networkTestRecord(b, selected: (0..<17).map { "component-\($0)" })
        }
        packet = ReplicationPacket(kind: .state, session: packet.session, join: packet.join,
                                   sequence: packet.sequence + 1,
                                   entities: [invalid == .cycle ? networkTestRecord(changed, parent: b.id) : changed, bad])
        var added = 0, applied = 0, componentAdds = 0
        let tokens = [
            rig.clientWorld.subscribe(to: WorldEvents.DidAddEntity.self) { _ in added += 1 },
            rig.clientWorld.subscribe(to: NetworkEvents.DidApplyState.self) { _ in applied += 1 },
            rig.clientWorld.subscribe(to: ComponentEvents.DidAdd.self) { _ in componentAdds += 1 }
        ]
        defer { tokens.forEach { $0.cancel() } }
        try rig.receive(packet)
        #expect(rig.client.state == .failed && rig.client.lastError != nil)
        #expect(rig.client.sequence == originalSequence)
        #expect(firstReplica.name == "first" && firstReplica.position == .zero)
        #expect(firstReplica.components[NetworkTestHealth.self]?.value == 10)
        #expect(secondReplica.name == "second" && secondReplica.position == .zero)
        #expect(added == 0 && componentAdds == 0 && applied == 0)
        // Fail-closed teardown may detach old replicas, but cannot write any of
        // the unvalidated new values or mutate the client's local scene.
        rig.expectLocalEntities()
    }

    @Test(arguments: [false, true])
    func malformedOrIncompatibleEnvelopeFailsBeforeApplying(incompatible: Bool) throws {
        let source = networkTestEntity()
        let rig = try NetworkTestRig(entities: [source])
        defer { rig.client.stop(); rig.host.stop() }
        let replica = try rig.replica(source)
        var packet = try rig.hostTransport.lastPacket(.state)
        packet.version = 999
        let bytes = incompatible ? try JSONEncoder().encode(packet) : Data("{broken".utf8)
        rig.clientTransport.onEvent?(.received(bytes, from: rig.hostTransport.localPeer.id))
        rig.client.update(deltaTime: 0)
        #expect(rig.client.lastError == (incompatible ? .incompatibleVersion : .invalidPacket))
        #expect(rig.client.state == .failed && replica.position == .zero)
        rig.expectLocalEntities()
    }

    @Test(arguments: ["entities", "packet", "queue"])
    func incomingCapacityFailureAppliesNothing(limit: String) throws {
        let first = networkTestEntity("first")
        let rig = try NetworkTestRig(entities: [first], clientConfiguration: .init(
            maximumEntities: 1, maximumPacketBytes: 1024, maximumQueuedMessages: 1))
        defer { rig.client.stop(); rig.host.stop() }
        let replica = try rig.replica(first)
        let originalSequence = rig.client.sequence
        var packet = try rig.hostTransport.lastPacket(.state)
        packet = ReplicationPacket(kind: .state, session: packet.session, join: packet.join,
                                   sequence: packet.sequence + 1, entities: packet.entities)
        if limit == "entities" {
            packet.entities.append(networkTestRecord(packet.entities[0], id: .init(), name: "second"))
            try rig.clientTransport.inject(packet, from: rig.hostTransport.localPeer.id)
        } else if limit == "packet" {
            rig.clientTransport.onEvent?(.received(Data(repeating: 0, count: 1025), from: rig.hostTransport.localPeer.id))
        } else {
            try rig.clientTransport.inject(packet, from: rig.hostTransport.localPeer.id)
            try rig.clientTransport.inject(packet, from: rig.hostTransport.localPeer.id)
        }
        rig.client.update(deltaTime: 0)
        #expect(rig.client.state == .failed && rig.client.lastError == .capacityExceeded)
        #expect(rig.client.sequence == originalSequence && replica.name == "first")
        rig.expectLocalEntities()
    }

    @Test(arguments: ["schema", "nan", "capacity", "parent", "duplicate", "packet"])
    func invalidOutgoingStateSendsNoPartialFrame(invalid: String) throws {
        let first = networkTestEntity("first")
        let rig = try NetworkTestRig(entities: [first], configuration: .init(maximumEntities: 2, maximumPacketBytes: 2048))
        defer { rig.client.stop(); rig.host.stop() }
        let replica = try rig.replica(first)
        let sends = rig.hostTransport.sent.count
        switch invalid {
        case "schema": first.components[SynchronizationComponent.self]?.components = ["unregistered"]
        case "nan": first.transform.rotation = .nan
        case "capacity":
            rig.hostWorld.addEntity(networkTestEntity("second"))
            rig.hostWorld.addEntity(networkTestEntity("third"))
        case "parent":
            let parent = Entity()
            rig.hostWorld.addEntity(parent)
            try first.setParent(parent)
        case "duplicate":
            rig.hostWorld.addEntity(networkTestEntity("duplicate", id: first.components[SynchronizationComponent.self]!.id))
        default:
            first.name = String(repeating: "x", count: 250)
            first.components.set(NetworkTestSecret(value: String(repeating: "x", count: 3000)))
            first.components[SynchronizationComponent.self]?.components = ["transform", "secret"]
        }
        #expect(throws: (any Error).self) { try rig.host.synchronize() }
        #expect(rig.host.state == .failed && rig.hostTransport.sent.count == sends)
        #expect(replica.position == .zero && rig.client.state == .connected)
    }
}

@MainActor private final class NetworkTestValidationHook {
    var action: (@MainActor () throws -> Void)?
}

@MainActor extension NetworkSessionTests {
    @Test(arguments: [false, true])
    func stoppingInsideSchemaValidationInvalidatesTheEntireFrame(throwsAfterStop: Bool) throws {
        let hook = NetworkTestValidationHook()
        var schema = NetworkReplicationSchema()
        try schema.register(NetworkTestHealth.self, named: "health") { _ in try hook.action?() }
        let source = networkTestEntity("before", components: ["transform", "health"])
        source.components.set(NetworkTestHealth(value: 1))
        let rig = try NetworkTestRig(entities: [source], schema: schema)
        defer { hook.action = nil; rig.client.stop(); rig.host.stop() }
        let replica = try rig.replica(source)
        let old = try rig.hostTransport.lastPacket(.state)
        let packet = ReplicationPacket(kind: .state, session: old.session, join: old.join,
            sequence: old.sequence + 1, entities: [networkTestRecord(old.entities[0], name: "after-stop")])
        var additions = 0, applies = 0
        let tokens = [
            rig.clientWorld.subscribe(to: WorldEvents.DidAddEntity.self) { _ in additions += 1 },
            rig.clientWorld.subscribe(to: NetworkEvents.DidApplyState.self) { _ in applies += 1 }
        ]
        defer { tokens.forEach { $0.cancel() } }
        hook.action = { [weak client = rig.client] in
            client?.stop()
            if throwsAfterStop { throw NetworkSessionError.invalidState }
        }
        try rig.receive(packet)
        #expect(rig.client.state == .stopped && rig.client.replicatedEntityCount == 0)
        #expect(replica.name == "before" && replica.world == nil)
        #expect(additions == 0 && applies == 0)
        #expect(rig.clientWorld.networkSessionOwner == nil && rig.clientTransport.onEvent == nil)
        #expect(rig.clientWorld.allEntities.count == 2)
        rig.expectLocalEntities()
    }

    @Test(arguments: ["component", "activation", "attach", "applied", "joined"])
    func stoppingInsideApplyCallbackCannotFinishOldGeneration(callback: String) throws {
        let source = networkTestEntity("source", components: ["transform", "health"])
        let rig = try NetworkTestRig(entities: [source], establish: callback != "joined")
        defer { rig.client.stop(); rig.host.stop() }
        var fired = false, restartError: NetworkSessionError?
        let stop: @MainActor () -> Void = {
            guard !fired else { return }
            fired = true
            rig.client.stop()
            do { try rig.client.start() }
            catch { restartError = error as? NetworkSessionError }
            rig.client.update(deltaTime: 0)
        }
        var tokens: [EventSubscription] = []
        switch callback {
        case "component":
            tokens.append(rig.clientWorld.subscribe(to: ComponentEvents.DidAdd.self) { event in
                if event.componentType == NetworkTestHealth.self { stop() }
            })
            source.components.set(NetworkTestHealth(value: 2))
        case "activation":
            tokens.append(rig.clientWorld.subscribe(to: WorldEvents.DidChangeEntityActivation.self) { _ in stop() })
            source.isEnabled = false
        case "attach":
            tokens.append(rig.clientWorld.subscribe(to: WorldEvents.DidAddEntity.self) { _ in stop() })
            rig.hostWorld.addEntity(networkTestEntity("new"))
        case "applied":
            tokens.append(rig.clientWorld.subscribe(to: NetworkEvents.DidApplyState.self) { _ in stop() })
        default:
            tokens.append(rig.clientWorld.subscribe(to: NetworkEvents.PeerJoined.self) { _ in stop() })
        }
        defer { tokens.forEach { $0.cancel() } }
        if callback == "joined" { rig.host.update(deltaTime: 0); rig.client.update(deltaTime: 0) }
        else { try rig.push() }
        #expect(fired && restartError == .reentrantOperation)
        #expect(rig.client.state == .stopped && rig.client.replicatedEntityCount == 0)
        #expect(rig.clientWorld.networkSessionOwner == nil && rig.clientTransport.onEvent == nil)
        #expect(rig.clientWorld.allEntities.count == 2)
        rig.expectLocalEntities()
    }

    @Test func failureTeardownRejectsRestartFromRemovalAndFailureCallbacks() throws {
        let source = networkTestEntity()
        let rig = try NetworkTestRig(entities: [source])
        defer { rig.client.stop(); rig.host.stop() }
        var errors: [NetworkSessionError] = []
        let restart: @MainActor () -> Void = {
            do { try rig.client.start() }
            catch let error as NetworkSessionError { errors.append(error) }
            catch { Issue.record("Unexpected restart error: \(error)") }
        }
        let tokens = [
            rig.clientWorld.subscribe(to: WorldEvents.WillRemoveEntity.self) { _ in restart() },
            rig.clientWorld.subscribe(to: NetworkEvents.Failed.self) { _ in restart() }
        ]
        defer { tokens.forEach { $0.cancel() } }
        rig.clientTransport.onEvent?(.failed("link failed"))
        rig.client.update(deltaTime: 0)
        #expect(errors == [.reentrantOperation, .reentrantOperation])
        #expect(rig.client.state == .failed && rig.client.lastError == .transport("link failed"))
        #expect(rig.clientTransport.onEvent == nil && rig.clientWorld.networkSessionOwner == nil)
        try rig.client.start()
        rig.host.update(deltaTime: 0)
        rig.client.update(deltaTime: 0)
        #expect(rig.client.state == .connected && rig.client.lastError == nil)
    }

    @Test(arguments: [false, true])
    func stoppingOldSessionDoesNotReleaseNewOwnersCallback(failed: Bool) throws {
        let world = World(), transport = NetworkTestTransport("host")
        let old = NetworkSession(world: world, transport: transport, role: .host)
        try old.start()
        if failed { old.update(deltaTime: .nan) } else { old.stop() }
        let fresh = NetworkSession(world: world, transport: transport, role: .host)
        try fresh.start()
        defer { fresh.stop() }
        old.stop()
        #expect(transport.onEvent != nil && world.networkSessionOwner === fresh)
        transport.onEvent?(.failed("new owner receives this"))
        fresh.update(deltaTime: 0)
        #expect(fresh.state == .failed && fresh.lastError == .transport("new owner receives this"))
    }

    @Test func droppingActiveSessionReleasesTransportAndWorldLease() throws {
        let world = World(), transport = NetworkTestTransport("host")
        var session: NetworkSession? = NetworkSession(world: world, transport: transport, role: .host)
        weak let weakSession = session
        try session?.start()
        #expect(transport.onEvent != nil && world.networkSessionOwner === session)
        session = nil
        #expect(weakSession == nil && transport.onEvent == nil && world.networkSessionOwner == nil)
        let next = NetworkSession(world: world, transport: transport, role: .host)
        try next.start()
        defer { next.stop() }
        #expect(next.state == .connected && transport.onEvent != nil)
    }

    @Test func sessionDoesNotRetainWorldAndFailsClosedWhenWorldDisappears() throws {
        let transport = NetworkTestTransport("host")
        var world: World? = World()
        weak let weakWorld = world
        let session = NetworkSession(world: world!, transport: transport, role: .host)
        try session.start()
        world = nil
        #expect(weakWorld == nil)
        session.update(deltaTime: 0)
        #expect(session.state == .failed && session.lastError == .worldUnavailable)
        #expect(transport.onEvent == nil)
        #expect(throws: NetworkSessionError.worldUnavailable) { try session.start() }
    }

    @Test func competingWorldAndTransportOwnersAreRejectedWithoutStealingLease() throws {
        let world = World(), transport = NetworkTestTransport("host")
        let owner = NetworkSession(world: world, transport: transport, role: .host)
        try owner.start()
        defer { owner.stop() }
        let sameWorld = NetworkSession(world: world, transport: NetworkTestTransport("second"), role: .host)
        #expect(throws: NetworkSessionError.worldInUse) { try sameWorld.start() }
        // Keep the second world alive: the session deliberately retains it weakly.
        let otherWorld = World()
        let competitor = NetworkSession(world: otherWorld, transport: transport, role: .host)
        #expect(throws: NetworkSessionError.transportInUse) { try competitor.start() }
        competitor.stop()
        #expect(world.networkSessionOwner === owner && transport.onEvent != nil)
        #expect(throws: NetworkSessionError.invalidState) { try owner.start() }
    }

    @Test(arguments: ["stop", "disconnect", "end"])
    func hostDropFailsClientAndPreservesLocalWorld(cause: String) throws {
        let source = networkTestEntity()
        let rig = try NetworkTestRig(entities: [source])
        defer { rig.client.stop(); rig.host.stop() }
        let replica = try rig.replica(source)
        var failures: [NetworkSessionError] = []
        let token = rig.clientWorld.subscribe(to: NetworkEvents.Failed.self) { failures.append($0.error) }
        defer { token.cancel() }
        if cause == "stop" { rig.host.stop() }
        else if cause == "disconnect" { rig.hostTransport.disconnect() }
        else {
            let old = try rig.hostTransport.lastPacket(.state)
            try rig.clientTransport.inject(ReplicationPacket(kind: .end, session: old.session, join: old.join,
                sequence: old.sequence), from: rig.hostTransport.localPeer.id)
        }
        rig.client.update(deltaTime: 0)
        #expect(rig.client.state == .failed && rig.client.lastError == .hostDisconnected)
        #expect(failures == [.hostDisconnected] && replica.world == nil)
        #expect(source.world === rig.hostWorld && rig.clientTransport.onEvent == nil)
        #expect(rig.clientTransport.disconnectCount == 0)
        rig.expectLocalEntities()
    }

    @Test func peerDisconnectKeepsHostAndItsAuthoritativeEntitiesAlive() throws {
        let source = networkTestEntity()
        let rig = try NetworkTestRig(entities: [source])
        defer { rig.client.stop(); rig.host.stop() }
        var left: [NetworkPeerID] = []
        let token = rig.hostWorld.subscribe(to: NetworkEvents.PeerLeft.self) { left.append($0.peerID) }
        defer { token.cancel() }
        rig.clientTransport.disconnect()
        rig.hostTransport.onEvent?(.disconnected(rig.clientTransport.localPeer.id))
        rig.host.update(deltaTime: 0)
        #expect(rig.host.state == .connected && rig.host.peers.isEmpty)
        #expect(left == [rig.clientTransport.localPeer.id] && source.world === rig.hostWorld)
        try rig.host.synchronize()
        #expect(rig.host.replicatedEntityCount == 1)
    }
}

@MainActor extension NetworkSessionTests {
    @Test func staleSequencesAndOldHostSessionsCannotReplaceCurrentState() throws {
        let source = networkTestEntity()
        let rig = try NetworkTestRig(entities: [source])
        defer { rig.client.stop(); rig.host.stop() }
        let baseline = try rig.hostTransport.lastPacket(.state)
        let replica = try rig.replica(source)
        source.position = [8, 12]
        try rig.push()
        let sequence = rig.client.sequence
        var applied = 0
        let token = rig.clientWorld.subscribe(to: NetworkEvents.DidApplyState.self) { _ in applied += 1 }
        defer { token.cancel() }
        try rig.receive(baseline)
        var current = try rig.hostTransport.lastPacket(.state)
        current.entities = []
        try rig.receive(current)
        try rig.receive(ReplicationPacket(kind: .state, session: UUID(), join: baseline.join,
                                         sequence: sequence + 100, baseline: true, entities: []))
        try rig.receive(ReplicationPacket(kind: .end, session: UUID(), join: baseline.join, sequence: sequence + 100))
        #expect(rig.client.sequence == sequence && applied == 0 && rig.client.state == .connected)
        #expect(try rig.replica(source) === replica)
        #expect(replica.position == SIMD2<Float>(8, 12))
    }

    @Test func restartRequiresNewJoinAndFreshBaselineAndLocalIDs() throws {
        let source = networkTestEntity()
        let rig = try NetworkTestRig(entities: [source])
        defer { rig.client.stop(); rig.host.stop() }
        let old = try rig.hostTransport.lastPacket(.state)
        let firstReplica = try rig.replica(source)
        rig.client.stop()
        try rig.client.start()
        #expect(rig.client.state == .joining && rig.client.sequence == 0)
        try rig.receive(old)
        #expect(rig.client.state == .joining && rig.client.replicatedEntityCount == 0)
        let hello = try rig.clientTransport.lastPacket(.hello)
        #expect(hello.join != old.join)
        try rig.receive(ReplicationPacket(kind: .state, session: old.session, join: hello.join,
                                         sequence: 100, baseline: false, entities: old.entities))
        #expect(rig.client.state == .joining)
        rig.host.update(deltaTime: 0)
        rig.client.update(deltaTime: 0)
        let newReplica = try rig.replica(source)
        #expect(rig.client.state == .connected && firstReplica.world == nil)
        #expect(newReplica.id != firstReplica.id && newReplica.id != source.id)
        #expect(newReplica.components[SynchronizationComponent.self]?.id == firstReplica.components[SynchronizationComponent.self]?.id)
        try rig.receive(ReplicationPacket(kind: .end, session: old.session, join: old.join, sequence: UInt64.max))
        #expect(rig.client.state == .connected)
        rig.expectLocalEntities()
    }

    @Test func commandsAreAuthenticatedOrderedAndOwnershipIsValidatedByApplication() throws {
        let owned = networkTestEntity("owned")
        let rig = try NetworkTestRig(entities: [owned])
        defer { rig.client.stop(); rig.host.stop() }
        owned.components[SynchronizationComponent.self]?.owner = rig.clientTransport.localPeer.id
        var senders: [NetworkPeerID] = [], payloads: [Data] = []
        let token = rig.hostWorld.subscribe(to: NetworkEvents.CommandReceived.self) { event in
            senders.append(event.sender)
            payloads.append(event.data)
            // Core authenticates the sender. Only application rules may decide
            // whether this command may change this particular entity.
            if owned.components[SynchronizationComponent.self]?.owner == event.sender,
               event.data == Data("move".utf8) {
                owned.position.x += 1
            }
        }
        defer { token.cancel() }
        try rig.client.sendCommand(Data("move".utf8))
        let first = try rig.clientTransport.lastPacket(.command)
        rig.host.update(deltaTime: 0)
        #expect(owned.position.x == 1 && senders == [rig.clientTransport.localPeer.id])
        #expect(rig.clientTransport.sent.last?.reliable == true)
        try rig.hostTransport.inject(first, from: rig.clientTransport.localPeer.id)
        rig.host.update(deltaTime: 0)
        #expect(senders.count == 1 && owned.position.x == 1)

        let other = NetworkPeer(id: .init(rawValue: "other"), displayName: "Other")
        rig.hostTransport.onEvent?(.connected(other))
        let join = UUID()
        try rig.hostTransport.inject(ReplicationPacket(kind: .hello, session: UUID(), join: join, sequence: 0), from: other.id)
        rig.host.update(deltaTime: 0)
        try rig.hostTransport.inject(ReplicationPacket(kind: .command, session: first.session, join: join,
            sequence: 1, command: Data("move".utf8)), from: other.id)
        rig.host.update(deltaTime: 0)
        #expect(senders == [rig.clientTransport.localPeer.id, other.id])
        #expect(payloads == [Data("move".utf8), Data("move".utf8)] && owned.position.x == 1)

        for packet in [
            ReplicationPacket(kind: .command, session: UUID(), join: first.join, sequence: 999, command: Data("move".utf8)),
            ReplicationPacket(kind: .command, session: first.session, join: UUID(), sequence: 999, command: Data("move".utf8))
        ] {
            try rig.hostTransport.inject(packet, from: rig.clientTransport.localPeer.id)
        }
        try rig.hostTransport.inject(first, from: .init(rawValue: "unconnected"))
        rig.host.update(deltaTime: 0)
        #expect(senders.count == 2)
        try rig.client.sendCommand(Data("move".utf8))
        rig.host.update(deltaTime: 0)
        #expect(senders.count == 3 && owned.position.x == 2)
    }

    @Test func oldJoinCommandsAreIgnoredAfterRejoinAndSequenceRestarts() throws {
        let rig = try NetworkTestRig()
        defer { rig.client.stop(); rig.host.stop() }
        var commands = 0
        let token = rig.hostWorld.subscribe(to: NetworkEvents.CommandReceived.self) { _ in commands += 1 }
        defer { token.cancel() }
        try rig.client.sendCommand(Data([1]))
        let old = try rig.clientTransport.lastPacket(.command)
        rig.host.update(deltaTime: 0)
        rig.client.stop()
        try rig.client.start()
        rig.host.update(deltaTime: 0)
        rig.client.update(deltaTime: 0)
        try rig.hostTransport.inject(old, from: rig.clientTransport.localPeer.id)
        try rig.client.sendCommand(Data([2]))
        let fresh = try rig.clientTransport.lastPacket(.command)
        #expect(fresh.sequence == 1 && fresh.join != old.join)
        rig.host.update(deltaTime: 0)
        #expect(commands == 2)
    }

    @Test func commandSizeAndLifecycleGuardsDoNotSendInvalidCommands() throws {
        let rig = try NetworkTestRig(configuration: .init(maximumCommandBytes: 4), establish: false)
        defer { rig.client.stop(); rig.host.stop() }
        #expect(throws: NetworkSessionError.notConnected) { try rig.client.sendCommand(Data([1])) }
        rig.host.update(deltaTime: 0)
        rig.client.update(deltaTime: 0)
        #expect(throws: NetworkSessionError.notConnected) { try rig.host.sendCommand(Data([1])) }
        let count = rig.clientTransport.sent.count
        #expect(throws: NetworkSessionError.packetTooLarge) { try rig.client.sendCommand(Data(repeating: 0, count: 5)) }
        #expect(rig.clientTransport.sent.count == count && rig.client.state == .connected)
        try rig.client.sendCommand(Data(repeating: 0, count: 4))
        #expect(try rig.clientTransport.lastPacket(.command).sequence == 1)
        rig.client.stop()
        #expect(throws: NetworkSessionError.notConnected) { try rig.client.sendCommand(Data()) }
    }

    @Test(arguments: ["oversized", "entities", "missing"])
    func malformedCommandIsRejectedBeforeApplication(invalid: String) throws {
        let source = networkTestEntity()
        let rig = try NetworkTestRig(entities: [source], configuration: .init(maximumCommandBytes: 4))
        defer { rig.client.stop(); rig.host.stop() }
        let state = try rig.hostTransport.lastPacket(.state)
        let packet = ReplicationPacket(kind: .command, session: state.session, join: state.join,
            sequence: 1, entities: invalid == "entities" ? state.entities : [],
            command: invalid == "missing" ? nil : Data(repeating: 0, count: invalid == "oversized" ? 5 : 1))
        var commands = 0
        let token = rig.hostWorld.subscribe(to: NetworkEvents.CommandReceived.self) { _ in commands += 1 }
        defer { token.cancel() }
        try rig.hostTransport.inject(packet, from: rig.clientTransport.localPeer.id)
        rig.host.update(deltaTime: 0)
        #expect(rig.host.state == .failed && rig.host.lastError == .invalidPacket && commands == 0)
        #expect(source.world === rig.hostWorld && source.position == .zero)
    }
}
