import ECSCore
import GameplayECS
import Testing

@MainActor @Suite struct NetworkSpatialInterestTests {
    @Test func radiusAndExitMarginPreventChurnAndGroupsFilterBeforeAlwaysRelevant() throws {
        let world = World(), peer = NetworkPeer(id: .init(rawValue: "p"), displayName: "P")
        let adapter = try NetworkSpatialInterest(world: world, radius: 100, exitMargin: 20)
        try adapter.setObserver(at: .zero, groups: ["red"], for: peer.id)
        let actor = Entity(components: SynchronizationComponent(), NetworkInterestComponent(groups: ["red"])); world.addEntity(actor)
        let policy = adapter.policy
        // Exercise through a real session so the policy remains opaque to applications.
        let hub = InMemoryNetwork(), h = try hub.connect(.init(id: .init(rawValue: "h"), displayName: "H")), c = try hub.connect(peer)
        let cw = World(), host = NetworkSession(world: world, transport: h, role: .host, replicationPolicy: policy), client = NetworkSession(world: cw, transport: c, role: .client(host: h.localPeer.id))
        try host.start(); try client.start(); defer { host.stop(); client.stop() }
        func tick() { for _ in 0..<4 { hub.advance(by: 0.1); world.update(deltaTime: 0.1); cw.update(deltaTime: 0.1) } }
        actor.position.x = 90; tick(); #expect(cw.entities.count == 1)
        actor.position.x = 110; tick(); #expect(cw.entities.count == 1)
        actor.position.x = 125; tick(); #expect(cw.entities.isEmpty)
        actor.position.x = 110; tick(); #expect(cw.entities.isEmpty)
        actor.components[NetworkInterestComponent.self]?.isAlwaysRelevant = true; tick(); #expect(cw.entities.count == 1)
        try adapter.setObserver(at: .zero, groups: ["blue"], for: peer.id); tick(); #expect(cw.entities.isEmpty)
        c.disconnect(); hub.advance(by: 0); world.update(deltaTime: 0); #expect(adapter.observerCount == 0)
    }
    @Test func invalidObserverChangesPreservePriorConfigurationAndRemovalClearsMemory() throws {
        let world = World(), adapter = try NetworkSpatialInterest(world: world)
        let peer = NetworkPeerID(rawValue: "p"); try adapter.setObserver(at: .zero, for: peer)
        #expect(throws: NetworkSpatialInterestError.invalidConfiguration) { try adapter.setObserver(at: [.nan, 0], for: peer) }
        #expect(throws: NetworkSpatialInterestError.invalidConfiguration) { try adapter.setObserver(at: .zero, groups: [String(repeating: "a", count: 65)], for: peer) }
        #expect(adapter.observerCount == 1); adapter.removeAllObservers(); #expect(adapter.observerCount == 0)
    }
}
