import Foundation
@testable import ECSCore
import Testing

private let interestHost = NetworkPeer(id: .init(rawValue: "host"), displayName: "Host")
private let interestA = NetworkPeer(id: .init(rawValue: "alice"), displayName: "Alice")
private let interestB = NetworkPeer(id: .init(rawValue: "bob"), displayName: "Bob")
@MainActor private final class InterestTransport: NetworkTransport {
    let base: InMemoryNetworkTransport
    var packets: [(Data, NetworkPeerID, Bool)] = []
    init(_ base: InMemoryNetworkTransport) { self.base = base }
    var localPeer: NetworkPeer { base.localPeer }
    var connectedPeers: [NetworkPeer] { base.connectedPeers }
    var onEvent: (@MainActor (NetworkTransportEvent) -> Void)? { get { base.onEvent } set { base.onEvent = newValue } }
    func send(_ data: Data, to peer: NetworkPeerID, reliably: Bool) throws { packets.append((data, peer, reliably)); try base.send(data, to: peer, reliably: reliably) }
    func disconnect() { base.disconnect() }
    var states: [(ReplicationPacket, Data, NetworkPeerID, Bool)] { packets.compactMap { item in
        guard let packet = try? JSONDecoder().decode(ReplicationPacket.self, from: item.0), packet.kind == .state || packet.kind == .poses else { return nil }
        return (packet, item.0, item.1, item.2)
    } }
}
@MainActor private final class InterestRig {
    let hub = InMemoryNetwork(seed: 4)
    let world = World(), aw = World(), bw = World()
    let ht: InterestTransport, at: InterestTransport, bt: InterestTransport
    let host: NetworkSession, a: NetworkSession, b: NetworkSession
    init(entities: [Entity], policy: NetworkReplicationPolicy = .all, budget: NetworkReplicationBudget? = nil,
         configuration: NetworkSessionConfiguration = .init()) throws {
        ht = InterestTransport(try hub.connect(interestHost)); at = InterestTransport(try hub.connect(interestA)); bt = InterestTransport(try hub.connect(interestB))
        entities.forEach(world.addEntity)
        host = NetworkSession(world: world, transport: ht, role: .host, configuration: configuration, replicationPolicy: policy, replicationBudget: budget)
        a = NetworkSession(world: aw, transport: at, role: .client(host: interestHost.id), configuration: configuration)
        b = NetworkSession(world: bw, transport: bt, role: .client(host: interestHost.id), configuration: configuration)
        try host.start(); try a.start(); try b.start(); tick(3, dt: 0)
    }
    func tick(_ count: Int = 1, dt: TimeInterval = 0.1) { for _ in 0..<count { hub.advance(by: dt); world.update(deltaTime: dt); aw.update(deltaTime: dt); bw.update(deltaTime: dt) } }
    func close() { host.stop(); a.stop(); b.stop(); ht.disconnect(); at.disconnect(); bt.disconnect() }
}
@MainActor private func interestEntity(_ name: String, owner: NetworkPeerID? = nil) -> Entity { Entity(name: name, components: SynchronizationComponent(owner: owner)) }
@MainActor @Suite(.serialized) struct NetworkInterestTests {
    @Test func perPeerMembershipRetainsOwnedEntitiesAndAllRequiredParents() throws {
        let parent = interestEntity("parent"), child = interestEntity("child"), own = interestEntity("owned", owner: interestA.id)
        parent.addChild(child)
        let rig = try InterestRig(entities: [parent, own], policy: .init { entity, peer in entity.name == "child" && peer.id == interestA.id ? .visible() : .hidden }); defer { rig.close() }
        #expect(Set(rig.aw.entities.map(\.name)) == ["parent", "owned"])
        #expect(rig.aw.allEntities.contains(where: { $0.name == "child" }) && rig.bw.entities.isEmpty)
        #expect(rig.host.replicationStatistics.first(where: { $0.peerID == interestA.id })?.relevantEntities == 3)
    }
    @Test func relevanceEntryExitIsReliableAndPosesNeverDeleteOtherReplicas() throws {
        let first = interestEntity("first"), second = interestEntity("second"); var show = false
        let rig = try InterestRig(entities: [first, second], policy: .init { entity, _ in entity.name == "first" || show ? .visible() : .hidden }, budget: .init()); defer { rig.close() }
        #expect(rig.aw.entities.count == 1)
        show = true; rig.tick(3); #expect(rig.aw.entities.count == 2)
        first.position.x = 50; rig.tick(3); #expect(rig.aw.entities.count == 2)
        show = false; rig.tick(3); #expect(rig.aw.entities.count == 1)
        #expect(rig.ht.states.filter { $0.0.kind == .state }.allSatisfy { $0.3 })
        #expect(rig.ht.states.contains(where: { $0.0.kind == .poses && !$0.3 }))
    }
    @Test func tokensBoundReplicationBytesIndependentlyForEachPeer() throws {
        let actor = interestEntity("actor")
        let budget = NetworkReplicationBudget(bytesPerSecond: 800, burstBytes: 1200, maximumPosePacketBytes: 512)
        let rig = try InterestRig(entities: [actor], budget: budget); defer { rig.close() }
        for index in 0..<100 { actor.position.x = Float(index); rig.tick() }
        for peer in [interestA.id, interestB.id] {
            let bytes = rig.ht.states.filter { $0.2 == peer }.reduce(0) { $0 + $1.1.count }
            #expect(bytes <= 1200 + 800 * 10 && bytes > 1200)
            let metric = try #require(rig.host.replicationStatistics.first(where: { $0.peerID == peer }))
            #expect(metric.replicationBytesSent == bytes && metric.deferredPublications > 0)
            #expect(metric.availableReplicationBytes ?? -1 >= 0)
        }
    }
    @Test func highPriorityLeadsAndAgingPreventsCheapUpdatesFromStarving() throws {
        let actors = (0..<4).map { interestEntity("bot-\($0)") }
        let rig = try InterestRig(entities: actors, policy: .init { entity, _ in .visible(priority: entity.name == "bot-3" ? .critical : .background) },
            budget: .init(bytesPerSecond: 10_000, maximumPosePacketBytes: 512, maximumPosePacketsPerUpdate: 1, refreshInterval: 0.2)); defer { rig.close() }
        for actor in actors { actor.position.x = 10 }
        rig.tick()
        let packet = try #require(rig.ht.states.first(where: { $0.0.kind == .poses && $0.2 == interestA.id }))
        #expect(packet.0.poses?.first?.id == actors[3].components[SynchronizationComponent.self]?.id)
        for index in 0..<30 { actors[3].position.x = Float(20 + index); rig.tick() }
        for actor in actors.prefix(3) { #expect(rig.a.entity(withNetworkID: actor.components[SynchronizationComponent.self]!.id)?.position.x == 10) }
    }
    @Test func aLostFinalStationaryPoseIsRepairedByARefresh() throws {
        let actor = interestEntity("actor"); let rig = try InterestRig(entities: [actor], budget: .init(refreshInterval: 0.2)); defer { rig.close() }
        rig.hub.unreliableLossRate = 1; actor.position.x = 99; rig.tick(3)
        #expect(rig.aw.entities.first?.position.x == 0)
        rig.hub.unreliableLossRate = 0; rig.tick(6)
        #expect(rig.aw.entities.first?.position.x == 99 && rig.a.state == .connected)
    }
    @Test func posesForAnUnappliedMembershipFrameAreIgnoredAndLaterRefreshed() throws {
        let actor = interestEntity("old"); let rig = try InterestRig(entities: [actor], budget: .init(refreshInterval: 0.2)); defer { rig.close() }
        rig.hub.latency = 0.5; actor.name = "new"; actor.position.x = 20; rig.tick()
        rig.hub.latency = 0; actor.position.x = 40; rig.tick(2)
        #expect(rig.aw.entities.first?.name == "old" && rig.aw.entities.first?.position.x == 0)
        rig.tick(12)
        #expect(rig.aw.entities.first?.name == "new" && rig.aw.entities.first?.position.x == 40)
    }
    @Test func malformedPartialFramesAreValidatedBeforeAnyPoseChanges() throws {
        let first = interestEntity("first"), second = interestEntity("second")
        let rig = try InterestRig(entities: [first, second], budget: .init()); defer { rig.close() }
        let replica = try #require(rig.a.entity(withNetworkID: first.components[SynchronizationComponent.self]!.id))
        let initial = try #require(rig.ht.states.last(where: { $0.2 == interestA.id }))
        var bad = ReplicationPacket(kind: .poses, session: initial.0.session, join: initial.0.join, sequence: initial.0.sequence + 100)
        bad.baseSequence = initial.0.sequence
        bad.poses = [.init(id: first.components[SynchronizationComponent.self]!.id, transform: try JSONEncoder().encode(Transform(translation: [99, 0]))),
                     .init(id: second.components[SynchronizationComponent.self]!.id, transform: Data("bad".utf8))]
        rig.at.onEvent?(.received(try JSONEncoder().encode(bad), from: interestHost.id)); rig.aw.update(deltaTime: 0)
        #expect(rig.a.state == .failed && replica.position == .zero)
    }
    @Test func selectiveCaptureAllowsABoundedLargerHostWorldWhileCappingEachScope() throws {
        let actors = (0..<150).map { interestEntity("\($0)") }
        let rig = try InterestRig(entities: actors, policy: .init { entity, _ in Int(entity.name)! < 2 ? .visible() : .hidden }, configuration: .init(maximumEntities: 2)); defer { rig.close() }
        #expect(rig.a.state == .connected && rig.aw.entities.count == 2 && rig.host.replicatedEntityCount == 150)
    }
    @Test func oversizeMembershipFailsExplicitlyAndDefaultSessionsKeepFullFrames() throws {
        let rig = try InterestRig(entities: [interestEntity(String(repeating: "a", count: 250))], budget: .init(burstBytes: 512)); defer { rig.close() }
        #expect(rig.host.state == .failed && rig.host.lastError == .packetTooLarge)
        let old = try InterestRig(entities: [interestEntity("actor")]); defer { old.close() }; old.tick(4)
        #expect(!old.ht.states.isEmpty && old.ht.states.allSatisfy { $0.0.kind == .state })
    }
    @Test func theSmallestPacketLimitDoesNotFailDuringGreedyPoseSelection() throws {
        let actors = [interestEntity("a"), interestEntity("b")]
        // The baseline needs a larger cap; budget pose packing itself must stay below 512.
        let rig = try InterestRig(entities: actors, budget: .init(maximumPosePacketBytes: 512)); defer { rig.close() }
        actors[0].position.x = 3; actors[1].position.x = 4; rig.tick(5)
        #expect(rig.ht.states.filter { $0.0.kind == .poses }.allSatisfy { $0.1.count <= 512 })
        #expect(rig.a.state == .connected && rig.aw.entities.count == 2)
    }
    @Test func scopeChurnWithJitterAndLossStaysBoundedAndSettlesToTheLatestWorld() throws {
        let actors = (0..<12).map { interestEntity("actor-\($0)") }; var zone = 0
        let rig = try InterestRig(entities: actors, policy: .init { entity, peer in
            let index = Int(entity.name.split(separator: "-").last!)!
            return index % 3 == (peer.id == interestA.id ? zone : (zone + 1) % 3) ? .visible() : .hidden
        }, budget: .init(bytesPerSecond: 10_000, burstBytes: 8_000, refreshInterval: 0.2))
        defer { rig.close() }
        rig.hub.unreliableLossRate = 0.65
        for frame in 0..<600 {
            if frame % 60 == 0 { zone = (zone + 1) % 3 }
            rig.hub.latency = frame % 17 < 8 ? 0.03 : 0.13
            for (index, actor) in actors.enumerated() { actor.position = [Float(frame), Float(index)] }
            rig.tick(dt: 1.0 / 60)
            #expect(rig.hub.pendingMessageCount < 1024 && rig.hub.pendingByteCount < 4 * 1024 * 1024)
            #expect(rig.aw.entities.count <= 4 && rig.bw.entities.count <= 4)
        }
        rig.hub.latency = 0; rig.hub.unreliableLossRate = 0; rig.tick(120, dt: 1.0 / 60)
        #expect(rig.host.state == .connected && rig.a.state == .connected && rig.b.state == .connected)
        for (client, expectedZone) in [(rig.a, zone), (rig.b, (zone + 1) % 3)] {
            for (index, actor) in actors.enumerated() {
                let replica = client.entity(withNetworkID: actor.components[SynchronizationComponent.self]!.id)
                if index % 3 == expectedZone { #expect(replica?.position == actor.position) }
                else { #expect(replica == nil) }
            }
        }
        rig.close(); #expect(rig.hub.pendingMessageCount == 0 && rig.hub.pendingByteCount == 0)
    }

}
