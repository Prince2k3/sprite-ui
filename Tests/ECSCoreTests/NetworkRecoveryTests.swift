import Foundation
@testable import ECSCore
import Testing

private struct RecoveryHealth: Component, Codable { var value: Int }
private struct RecoveryLocalOnly: Component { var secret = "local" }
@MainActor private struct RecoveryFixture {
    let hub = InMemoryNetwork()
    let world = World()
    let local: InMemoryNetworkTransport
    let remote: InMemoryNetworkTransport
    let schema: NetworkReplicationSchema
    let session: NetworkSession
    let parent: Entity
    let child: Entity
    init() throws {
        local = try hub.connect(.init(id: .init(rawValue: "a"), displayName: "Host"))
        remote = try hub.connect(.init(id: .init(rawValue: "b"), displayName: "Client"))
        var schema = NetworkReplicationSchema()
        try schema.register(RecoveryHealth.self, named: "health", validate: { guard $0.value >= 0 else { throw NetworkSessionError.invalidState } })
        self.schema = schema
        parent = Entity(name: "parent", components: SynchronizationComponent())
        child = Entity(name: "child", components: SynchronizationComponent(components: ["transform", "health"]))
        child.components.set(RecoveryHealth(value: 9)); child.components.set(RecoveryLocalOnly())
        child.position = [12, 4]; parent.addChild(child); world.addEntity(parent)
        session = NetworkSession(world: world, transport: local, role: .host, schema: schema)
        try session.start()
    }
    func checkpoint() throws -> NetworkRecoveryCheckpoint { try session.recoveryCheckpoint(compatibilityID: "arena-v1", applicationState: Data("round-3".utf8)) }
}

@MainActor @Suite struct NetworkRecoveryTests {
    @Test func checkpointKeepsOnlySelectedInertValuesAndPreservesNetworkHierarchy() throws {
        let source = try RecoveryFixture(); defer { source.session.stop() }
        let checkpoint = try source.checkpoint(), decoded = try NetworkRecoveryCheckpoint(data: checkpoint.jsonData())
        let target = World(), camera = Entity(name: "local-camera"); target.addEntity(camera)
        let entities = try decoded.restore(in: target, approving: checkpoint.descriptor, schema: source.schema)
        let id = try #require(source.child.components[SynchronizationComponent.self]?.id)
        let child = try #require(entities[id])
        #expect(child.parent?.name == "parent" && child.position == [12, 4])
        #expect(child.components[RecoveryHealth.self]?.value == 9 && child.components[RecoveryLocalOnly.self] == nil)
        #expect(child.id != source.child.id && camera.world === target)
        #expect(decoded.applicationState == Data("round-3".utf8))
        #expect(decoded.descriptor.hostPeerID == source.local.localPeer.id)
        #expect(decoded.descriptor.peerIDs == [source.local.localPeer.id, source.remote.localPeer.id])
    }
    @Test func checksumRejectsTamperedValuesAndMetadata() throws {
        let fixture = try RecoveryFixture(); defer { fixture.session.stop() }
        let checkpoint = try fixture.checkpoint()
        for key in ["compatibilityID", "sequence"] {
            var json = try #require(JSONSerialization.jsonObject(with: checkpoint.jsonData()) as? [String: Any])
            var body = try #require(json["body"] as? [String: Any])
            body[key] = key == "sequence" ? 999 : "wrong-arena"
            json["body"] = body
            #expect(throws: NetworkRecoveryError.invalidCheckpoint) { try NetworkRecoveryCheckpoint(data: JSONSerialization.data(withJSONObject: json)) }
        }
    }
    @Test func staleCheckpointRequiresTheExactNewApproval() throws {
        let fixture = try RecoveryFixture(); defer { fixture.session.stop() }
        let old = try fixture.checkpoint(); fixture.child.position = [50, 0]
        let current = try fixture.checkpoint(), target = World()
        #expect(throws: NetworkRecoveryError.incompatibleCheckpoint) { try old.restore(in: target, approving: current.descriptor, schema: fixture.schema) }
        #expect(target.entities.isEmpty)
    }
    @Test func incompatibleSchemaAndInvalidValuesDoNotPartiallyRestore() throws {
        let fixture = try RecoveryFixture(); defer { fixture.session.stop() }
        let checkpoint = try fixture.checkpoint(), target = World()
        #expect(throws: NetworkSessionError.invalidSchema) { try checkpoint.restore(in: target, approving: checkpoint.descriptor) }
        #expect(target.entities.isEmpty)
        var badSchema = NetworkReplicationSchema()
        try badSchema.register(RecoveryHealth.self, named: "health", validate: { _ in throw NetworkSessionError.invalidState })
        #expect(throws: NetworkSessionError.invalidState) { try checkpoint.restore(in: target, approving: checkpoint.descriptor, schema: badSchema) }
        #expect(target.entities.isEmpty)
    }
    @Test func existingSynchronizedEntitiesAndOccupiedWorldsAreProtected() throws {
        let fixture = try RecoveryFixture(); defer { fixture.session.stop() }; let checkpoint = try fixture.checkpoint()
        #expect(throws: NetworkRecoveryError.worldInUse) { try checkpoint.restore(in: fixture.world, approving: checkpoint.descriptor, schema: fixture.schema) }
        fixture.session.stop()
        #expect(throws: NetworkRecoveryError.worldNotEmpty) { try checkpoint.restore(in: fixture.world, approving: checkpoint.descriptor, schema: fixture.schema) }
        #expect(fixture.child.position == [12, 4])
    }
    @Test func fileAndCodableRoundTripsValidateTheSameArchive() throws {
        let fixture = try RecoveryFixture(); defer { fixture.session.stop() }; let checkpoint = try fixture.checkpoint()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try checkpoint.write(to: url)
        #expect(try NetworkRecoveryCheckpoint(contentsOf: url).descriptor == checkpoint.descriptor)
        #expect(try JSONDecoder().decode(NetworkRecoveryCheckpoint.self, from: JSONEncoder().encode(checkpoint)).descriptor == checkpoint.descriptor)
    }
    @Test func boundsAndInvalidMetadataFailBeforeRestoringEntities() throws {
        let fixture = try RecoveryFixture(); defer { fixture.session.stop() }
        #expect(throws: NetworkRecoveryError.capacityExceeded) { try fixture.session.recoveryCheckpoint(compatibilityID: "v1", applicationState: Data(repeating: 0, count: 65_537)) }
        #expect(throws: NetworkRecoveryError.invalidCheckpoint) { try fixture.session.recoveryCheckpoint(compatibilityID: " ") }
        #expect(throws: NetworkRecoveryError.capacityExceeded) { try NetworkRecoveryCheckpoint(data: Data(repeating: 0, count: NetworkRecoveryCheckpoint.maximumBytes + 1)) }
    }
    @Test func clientsAndStoppedHostsCannotAuthorCheckpoints() throws {
        let fixture = try RecoveryFixture(); defer { fixture.session.stop() }
        let clientWorld = World(), client = NetworkSession(world: clientWorld, transport: fixture.remote, role: .client(host: fixture.local.localPeer.id))
        try client.start(); defer { client.stop() }
        #expect(throws: NetworkSessionError.notHost) { try client.recoveryCheckpoint(compatibilityID: "v1") }
        fixture.session.stop()
        #expect(throws: NetworkSessionError.invalidState) { try fixture.checkpoint() }
    }
    @Test func duplicateIDsAndCyclesAreRejectedBeforeAttachment() throws {
        let fixture = try RecoveryFixture(); defer { fixture.session.stop() }; let original = try fixture.checkpoint()
        for records in [original.records + [original.records[0]], original.records.map {
            ReplicatedEntity(id: $0.id, parent: $0.id, name: $0.name, isEnabled: $0.isEnabled, owner: $0.owner,
                             interpolates: $0.interpolates, selected: $0.selected, components: $0.components)
        }] {
            let invalid = try NetworkRecoveryCheckpoint(records: records, compatibilityID: "v1", host: original.descriptor.hostPeerID,
                peers: original.descriptor.peerIDs, sessionID: original.descriptor.sessionID, sequence: 0, applicationState: Data(), at: Date())
            let target = World()
            #expect(throws: NetworkSessionError.invalidPacket) { try invalid.restore(in: target, approving: invalid.descriptor, schema: fixture.schema) }
            #expect(target.entities.isEmpty)
        }
    }
}

@MainActor private final class RecoveryRecordingTransport: NetworkTransport {
    let base: InMemoryNetworkTransport
    var sent: [Data] = []
    init(_ base: InMemoryNetworkTransport) { self.base = base }
    var localPeer: NetworkPeer { base.localPeer }
    var connectedPeers: [NetworkPeer] { base.connectedPeers }
    var onEvent: (@MainActor (NetworkTransportEvent) -> Void)? { get { base.onEvent } set { base.onEvent = newValue } }
    func send(_ data: Data, to peer: NetworkPeerID, reliably: Bool) throws { sent.append(data); try base.send(data, to: peer, reliably: reliably) }
    func disconnect() { base.disconnect() }
}
@MainActor @Suite struct NetworkRecoveryPacketTests {
    @Test func oldAuthenticatedHostPacketsCannotOverwriteTheFreshRejoin() throws {
        let a = NetworkPeer(id: .init(rawValue: "a"), displayName: "Host"), b = NetworkPeer(id: .init(rawValue: "b"), displayName: "Client")
        let oldHub = InMemoryNetwork(), oldHost = RecoveryRecordingTransport(try oldHub.connect(a)), oldClient = try oldHub.connect(b)
        let oldHostWorld = World(), oldClientWorld = World()
        let actor = Entity(name: "actor", components: SynchronizationComponent()); actor.position = [10, 0]; oldHostWorld.addEntity(actor)
        let oldSession = NetworkSession(world: oldHostWorld, transport: oldHost, role: .host)
        let oldReplica = NetworkSession(world: oldClientWorld, transport: oldClient, role: .client(host: a.id))
        try oldSession.start(); try oldReplica.start()
        for _ in 0..<8 { oldHub.advance(by: 0); oldHostWorld.update(deltaTime: 0.1); oldClientWorld.update(deltaTime: 0.1) }
        let stale = try #require(oldHost.sent.first(where: { (try? JSONDecoder().decode(ReplicationPacket.self, from: $0).kind) == .state }))
        let checkpoint = try oldSession.recoveryCheckpoint(compatibilityID: "v1")
        oldSession.stop(); oldReplica.stop(); oldHost.disconnect(); oldClient.disconnect()
        let hub = InMemoryNetwork(), hostTransport = try hub.connect(a), clientTransport = try hub.connect(b)
        let restored = World(), clientWorld = World()
        try checkpoint.restore(in: restored, approving: checkpoint.descriptor)
        restored.entities.first?.position = [90, 0]
        let freshHost = NetworkSession(world: restored, transport: hostTransport, role: .host)
        let freshClient = NetworkSession(world: clientWorld, transport: clientTransport, role: .client(host: a.id))
        try freshHost.start(); try freshClient.start(); defer { freshHost.stop(); freshClient.stop() }
        for _ in 0..<8 { hub.advance(by: 0); restored.update(deltaTime: 0.1); clientWorld.update(deltaTime: 0.1) }
        #expect(clientWorld.entities.first?.position == [90, 0])
        try hostTransport.send(stale, to: b.id, reliably: true); hub.advance(by: 0); clientWorld.update(deltaTime: 0.1)
        #expect(freshClient.state == .connected && clientWorld.entities.first?.position == [90, 0])
    }
}
