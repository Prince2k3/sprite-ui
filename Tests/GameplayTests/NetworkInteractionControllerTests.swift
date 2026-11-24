import Foundation
@testable import ECSCore
import Gameplay
import GameplayECS
import Testing

private let interactionHost = NetworkPeer(id: .init(rawValue: "host"), displayName: "Host")
private let interactionOwner = NetworkPeer(id: .init(rawValue: "owner"), displayName: "Owner")
@MainActor private final class InteractionSpyTransport: NetworkTransport {
    let base: InMemoryNetworkTransport
    var sent: [Data] = []
    init(_ base: InMemoryNetworkTransport) { self.base = base }
    var localPeer: NetworkPeer { base.localPeer }
    var connectedPeers: [NetworkPeer] { base.connectedPeers }
    var onEvent: (@MainActor (NetworkTransportEvent) -> Void)? { get { base.onEvent } set { base.onEvent = newValue } }
    func send(_ data: Data, to peer: NetworkPeerID, reliably: Bool) throws { sent.append(data); try base.send(data, to: peer, reliably: reliably) }
    func disconnect() { base.disconnect() }
    func payload(kind: String) -> Data? {
        for data in sent.reversed() {
            if let packet = try? JSONDecoder().decode(ReplicationPacket.self, from: data), let payload = packet.command,
               let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any], object["kind"] as? String == kind { return payload }
        }
        return nil
    }
}
@MainActor private final class InteractionRig {
    let hub: InMemoryNetwork
    let hostWorld = World(), clientWorld = World()
    let ht: InteractionSpyTransport, ct: InteractionSpyTransport
    let hs: NetworkSession, cs: NetworkSession
    let source: Entity, target: Entity
    var host: NetworkInteractionController2D?, client: NetworkInteractionController2D?
    var hostEvents: [NetworkInteractionResult<NetworkInteractionOutcome2D>] = []
    var clientEvents: [NetworkInteractionResult<NetworkInteractionOutcome2D>] = []
    var predicted = 0
    var tokens: [EventSubscription] = []
    init(latency: TimeInterval = 0.1, rewind: TimeInterval = 0.5, cooldown: TimeInterval = 0.2, payloadBytes: Int = 4096,
         validate: @escaping (NetworkInteractionIntent2D, NetworkInteractionOutcome2D) throws -> Void = { _, _ in }) throws {
        hub = InMemoryNetwork(latency: latency, unreliableLossRate: 0.6, seed: 7)
        ht = InteractionSpyTransport(try hub.connect(interactionHost)); ct = InteractionSpyTransport(try hub.connect(interactionOwner))
        source = Entity(name: "source", components: SynchronizationComponent(owner: interactionOwner.id), NetworkInteractionBodyComponent(shape: .circle(radius: 3), isTarget: false)); hostWorld.addEntity(source)
        target = Entity(name: "target", components: SynchronizationComponent(), NetworkInteractionBodyComponent(shape: .circle(radius: 5), canInteract: true)); target.position = [100, 0]; hostWorld.addEntity(target)
        hs = NetworkSession(world: hostWorld, transport: ht, role: .host, configuration: .init(maximumCommandBytes: payloadBytes)); cs = NetworkSession(world: clientWorld, transport: ct, role: .client(host: interactionHost.id), configuration: .init(maximumCommandBytes: payloadBytes))
        try hs.start(); try cs.start()
        for _ in 0..<240 where cs.state != .connected { hub.advance(by: 1.0 / 60); hostWorld.update(deltaTime: 1.0 / 60); clientWorld.update(deltaTime: 1.0 / 60) }
        let configuration = NetworkInteractionConfiguration(maximumRewind: rewind, cooldown: cooldown)
        host = try .host(in: hostWorld, session: hs, entity: source, configuration: configuration, validateAction: validate)
        client = try .client(in: clientWorld, session: cs, entityID: source.components[SynchronizationComponent.self]!.id, configuration: configuration)
        tokens = [hostWorld.subscribe(to: NetworkInteractionEvents.Resolved.self) { [weak self] in self?.hostEvents.append($0.result); #expect($0.isAuthority) },
            clientWorld.subscribe(to: NetworkInteractionEvents.Resolved.self) { [weak self] in self?.clientEvents.append($0.result); #expect(!$0.isAuthority) },
            clientWorld.subscribe(to: NetworkInteractionEvents.Predicted.self) { [weak self] _ in self?.predicted += 1 }]
    }
    func tick(_ count: Int = 1) { for _ in 0..<count { hub.advance(by: 1.0 / 60); hostWorld.update(deltaTime: 1.0 / 60); clientWorld.update(deltaTime: 1.0 / 60) } }
    func ready() { for _ in 0..<240 where client?.status != .running { tick() }; #expect(client?.status == .running) }
    func close() { host?.stop(); client?.stop(); hs.stop(); cs.stop(); ht.disconnect(); ct.disconnect(); for token in tokens { token.cancel() } }
    func lastOutcome() -> NetworkInteractionOutcome2D? { if let result = clientEvents.last, case .accepted(let outcome) = result.resolution { outcome } else { nil } }
}
@MainActor @Suite(.serialized) struct NetworkInteractionControllerTests {
    @Test func movingTargetIsHitAtTheExactIssuedViewWithoutMovingTheLiveTarget() throws {
        let rig = try InteractionRig(); defer { rig.close() }; rig.ready()
        rig.target.position = [100, 80]
        try rig.client?.perform(.ray(direction: [1, 0])); #expect(rig.predicted == 1 && rig.hostEvents.isEmpty)
        rig.tick(30)
        #expect(rig.lastOutcome()?.kind == .hit && rig.lastOutcome()?.contact?.id == rig.target.components[SynchronizationComponent.self]?.id)
        #expect(rig.target.position == [100, 80] && rig.hostEvents.count == 1 && rig.clientEvents.count == 1 && rig.client?.pendingActionCount == 0)
    }
    @Test func staleIssuedViewIsRejectedInsteadOfChoosingAnArbitraryNewTime() throws {
        let rig = try InteractionRig(rewind: 0.05); defer { rig.close() }; rig.ready()
        try rig.client?.perform(.ray(direction: [1, 0])); rig.tick(30)
        let result = try #require(rig.clientEvents.last)
        if case .accepted = result.resolution { Issue.record("Expired view accepted") }
        #expect(rig.client?.pendingActionCount == 0)
    }
    @Test func duplicateActionsAndReceiptsCannotRepeatHostOrClientEffects() throws {
        let rig = try InteractionRig(); defer { rig.close() }; rig.ready()
        try rig.client?.perform(.ray(direction: [1, 0])); rig.tick(30)
        let action = try #require(rig.ct.payload(kind: "action")); try rig.cs.sendCommand(action); rig.tick(30)
        let result = try #require(rig.ht.payload(kind: "result")); try rig.hs.sendResponse(result, to: interactionOwner.id); rig.tick(30)
        #expect(rig.hostEvents.count == 1 && rig.clientEvents.count == 1 && rig.predicted == 1)
    }
    @Test func burstsRespectHostCooldownAndEveryPredictionReceivesOneFinalReceipt() throws {
        let rig = try InteractionRig(); defer { rig.close() }; rig.ready()
        for _ in 0..<3 { try rig.client?.perform(.ray(direction: [1, 0])) }; rig.tick(30)
        #expect(rig.hostEvents.count == 3 && rig.clientEvents.count == 3 && rig.predicted == 3)
        #expect(rig.clientEvents.filter { if case .rejected(.cooldown) = $0.resolution { true } else { false } }.count == 2)
    }
    @Test func despawnAndRespawnCannotReceiveDamageFromTheOldBodyLifetime() throws {
        let rig = try InteractionRig(); defer { rig.close() }; rig.ready()
        try rig.client?.perform(.ray(direction: [1, 0]))
        rig.target.components.set(NetworkInteractionBodyComponent(shape: .circle(radius: 5)))
        rig.tick(30)
        let result = try #require(rig.clientEvents.last)
        if case .rejected(.targetUnavailable) = result.resolution {} else { Issue.record("Respawn accepted an old hit") }
    }
    @Test func removedTargetAndApplicationRulesRejectWithoutGrantingEffects() throws {
        let rig = try InteractionRig(validate: { _, _ in throw NetworkInteractionRejection.invalidIntent }); defer { rig.close() }; rig.ready()
        try rig.client?.perform(.ray(direction: [1, 0])); rig.tick(30)
        if case .rejected(.invalidIntent) = rig.clientEvents.last?.resolution {} else { Issue.record("Application policy ignored") }
    }
    @Test func proximalInteractionAndWallOcclusionUseHostRangesAndHistoricalBodies() throws {
        let rig = try InteractionRig(latency: 0); defer { rig.close() }; rig.target.position = [40, 0]; rig.ready(); rig.tick(12)
        let targetID = rig.target.components[SynchronizationComponent.self]!.id
        try rig.client?.perform(.interact(with: targetID)); rig.tick(20)
        #expect(rig.lastOutcome()?.kind == .interacted)
        let wall = Entity(components: SynchronizationComponent(), NetworkInteractionBodyComponent(shape: .rectangle(size: [2, 40]), isTarget: false)); wall.position = [20, 0]; rig.hostWorld.addEntity(wall); rig.tick(20)
        try rig.client?.perform(.ray(direction: [1, 0])); rig.tick(20)
        #expect(rig.lastOutcome()?.kind == .blocked)
    }
    @Test func invalidInputAndUnrelatedProtocolsCannotPublishSpeculativeOrHostEffects() throws {
        let rig = try InteractionRig(); defer { rig.close() }; rig.ready()
        #expect(throws: NetworkInteractionRejection.invalidIntent) { try rig.client?.perform(.ray(direction: [.nan, 0])) }
        try rig.cs.sendCommand(Data("another protocol".utf8)); try rig.hs.sendResponse(Data("another result".utf8), to: interactionOwner.id); rig.tick(20)
        #expect(rig.client?.status == .running && rig.host?.status == .running && rig.predicted == 0 && rig.hostEvents.isEmpty)
    }
    @Test func ownershipChangeStopsBothStreamsAndNewClientAttemptGetsAFreshEpoch() throws {
        let rig = try InteractionRig(); defer { rig.close() }; rig.ready(); let old = rig.client?.latestView?.reference.stream
        rig.client?.stop(); rig.client = try .client(in: rig.clientWorld, session: rig.cs, entityID: rig.source.components[SynchronizationComponent.self]!.id)
        rig.ready(); #expect(old != rig.client?.latestView?.reference.stream)
        rig.source.components[SynchronizationComponent.self]?.owner = interactionHost.id; rig.tick(30)
        #expect(rig.host?.status == .failed && rig.client?.status == .failed)
    }
    @Test func freshClientEpochCannotResetTheHostsCooldown() throws {
        let rig = try InteractionRig(latency: 0, cooldown: 10); defer { rig.close() }; rig.ready()
        try rig.client?.perform(.ray(direction: [1, 0])); rig.tick(10)
        #expect(rig.lastOutcome()?.kind == .hit)
        rig.client?.stop()
        rig.client = try .client(in: rig.clientWorld, session: rig.cs, entityID: rig.source.components[SynchronizationComponent.self]!.id)
        rig.ready(); try rig.client?.perform(.ray(direction: [1, 0])); rig.tick(10)
        if case .rejected(.cooldown) = rig.clientEvents.last?.resolution {} else { Issue.record("Epoch reset bypassed cooldown") }
    }
    @Test func removedTargetsCannotReceiveAnOldHitAndBodyClonesHaveNewIncarnations() throws {
        let rig = try InteractionRig(); defer { rig.close() }; rig.ready()
        let body = try #require(rig.target.components[NetworkInteractionBodyComponent.self])
        #expect(body.incarnation != body.cloned()?.incarnation)
        try rig.client?.perform(.ray(direction: [1, 0])); rig.target.removeFromParent(); rig.tick(30)
        if case .rejected(.targetUnavailable) = rig.clientEvents.last?.resolution {} else { Issue.record("Removed target accepted hit") }
    }
    @Test func ownershipChangesInsideAReceiptHandlerStopTheRemainingBatch() throws {
        let rig = try InteractionRig(latency: 0, cooldown: 0); defer { rig.close() }; rig.ready()
        let token = rig.hostWorld.subscribe(to: NetworkInteractionEvents.Resolved.self) { _ in
            rig.source.components[SynchronizationComponent.self]?.owner = interactionHost.id
        }; defer { token.cancel() }
        for _ in 0..<3 { try rig.client?.perform(.ray(direction: [1, 0])) }
        rig.tick(20)
        #expect(rig.hostEvents.count == 1 && rig.host?.status == .failed)
    }
    @Test func oversizedViewsFailExplicitlyWithoutPublishingGameplayEffects() throws {
        let rig = try InteractionRig(latency: 0, payloadBytes: 512); defer { rig.close() }; rig.tick(30)
        #expect(rig.host?.status == .failed && rig.host?.lastError != nil)
        #expect(rig.hostEvents.isEmpty && rig.clientEvents.isEmpty)
    }
    @Test func sessionTeardownAndReleasedControllersRetireAllRuntimeState() throws {
        let rig = try InteractionRig(); defer { rig.close() }; rig.ready()
        weak var old = rig.host; rig.host = nil; #expect(old == nil)
        rig.cs.stop(); rig.clientWorld.update(deltaTime: 0)
        #expect(rig.client?.status == .stopped || rig.client?.status == .failed)
        #expect(rig.client?.latestView == nil && rig.client?.pendingActionCount == 0)
    }
}
