import ECSCore
@testable import SpriteUIGameCenter
import Testing

@MainActor @Suite(.serialized) struct GameCenterReplicationPolicyTests {
    @Test func preparedActivitySessionsRetainTheirHostPolicyAndBudget() async throws {
        let a = GameCenterServices.preview(player: .init(id: .init(rawValue: "a"), displayName: "A"))
        let b = GameCenterServices.preview(player: .init(id: .init(rawValue: "b"), displayName: "B"))
        defer { a.shutdown(); b.shutdown() }
        let fixture = try GameCenterPartyPreview(players: [a.localPlayer!, b.localPlayer!])
        for services in [a, b] {
            try services.activities.configurePreview([.init(id: "arena", title: "Arena", supportsPartyCode: true)])
            try services.party.configurePreview(fixture); _ = try await services.activities.load()
            _ = try await services.activities.start(definitionID: "arena", partyCode: "1234-5678")
        }
        async let first: Void = a.party.findMatch(); async let second: Void = b.party.findMatch(); _ = try await (first, second)
        let hw = World(), cw = World(), budget = NetworkReplicationBudget(bytesPerSecond: 2000)
        hw.addEntity(Entity(name: "hidden", components: SynchronizationComponent()))
        try a.party.prepare(in: hw, compatibilityID: "policy-v1", replicationPolicy: .init { _, _ in .hidden }, replicationBudget: budget)
        try b.party.prepare(in: cw, compatibilityID: "policy-v1")
        try a.party.setReady(true); try b.party.setReady(true); for _ in 0..<8 { fixture.advance() }
        try a.party.startSession()
        for _ in 0..<20 { fixture.advance(by: 0.1); hw.update(deltaTime: 0.1); cw.update(deltaTime: 0.1) }
        #expect(a.party.state == .playing && b.party.state == .playing && cw.entities.isEmpty)
        #expect(a.networkSession?.replicationBudget == budget)
    }
    @Test func ordinaryReadySessionForwardingKeepsTheEnginePolicyOptional() throws {
        let hub = InMemoryNetwork(), hw = World(), cw = World()
        let h = try hub.connect(.init(id: .init(rawValue: "h"), displayName: "H")), c = try hub.connect(.init(id: .init(rawValue: "c"), displayName: "C"))
        let host = GameCenterServices.preview(player: h.localPeer), client = GameCenterServices.preview(player: c.localPeer)
        defer { host.shutdown(); client.shutdown() }
        hw.addEntity(Entity(name: "hidden", components: SynchronizationComponent()))
        let session = try host.attachSession(in: hw, transport: h, host: h.localPeer.id, replicationPolicy: .init { _, _ in .hidden }, replicationBudget: .init())
        _ = try client.attachSession(in: cw, transport: c, host: h.localPeer.id)
        for _ in 0..<10 { hub.advance(by: 0.1); hw.update(deltaTime: 0.1); cw.update(deltaTime: 0.1) }
        #expect(session.replicationBudget != nil && client.networkSession?.state == .connected && cw.entities.isEmpty)
    }
}
