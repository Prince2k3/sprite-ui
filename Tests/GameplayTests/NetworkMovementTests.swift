import ECSCore
import Foundation
import Gameplay
import GameplayECS
import Testing

private let moveHost = NetworkPeer(id: .init(rawValue: "host"), displayName: "Host")
private let moveClient = NetworkPeer(id: .init(rawValue: "client"), displayName: "Client")
@MainActor private final class MovementRig {
    let hub: InMemoryNetwork
    let hostWorld = World(), clientWorld = World()
    let hostTransport: InMemoryNetworkTransport, clientTransport: InMemoryNetworkTransport
    let hostSession: NetworkSession, clientSession: NetworkSession
    let actor: Entity, visual: Entity
    let rules = KinematicMovement2D(maximumSpeed: 120, bounds: .init(center: .zero, size: [200, 200]))
    var host: NetworkMovementController2D?, client: NetworkMovementController2D?
    init(latency: TimeInterval = 0, loss: Double = 0, capacity: Int = 256, smoothing: TimeInterval = 0.12) throws {
        hub = InMemoryNetwork(latency: latency, unreliableLossRate: loss, seed: 42)
        hostTransport = try hub.connect(moveHost); clientTransport = try hub.connect(moveClient)
        hostWorld.fixedStep = .init(); clientWorld.fixedStep = .init()
        actor = Entity(name: "authority", components: SynchronizationComponent(owner: moveClient.id)); hostWorld.addEntity(actor)
        visual = Entity(name: "local-prediction"); clientWorld.addEntity(visual)
        hostSession = NetworkSession(world: hostWorld, transport: hostTransport, role: .host)
        clientSession = NetworkSession(world: clientWorld, transport: clientTransport, role: .client(host: moveHost.id))
        try hostSession.start(); try clientSession.start()
        for _ in 0..<180 where clientSession.state != .connected { hub.advance(by: 1.0 / 60); hostWorld.update(deltaTime: 1.0 / 60); clientWorld.update(deltaTime: 1.0 / 60) }
        let config = NetworkPredictionConfiguration(maximumPendingInputs: capacity)
        host = try .host(in: hostWorld, session: hostSession, entity: actor, rules: rules, configuration: config)
        client = try .client(in: clientWorld, session: clientSession, entityID: actor.components[SynchronizationComponent.self]!.id,
            visual: visual, rules: rules, configuration: config, presentation: .init(smoothingDuration: smoothing))
    }
    func tick(_ count: Int = 1) { for _ in 0..<count { hub.advance(by: 1.0 / 60); hostWorld.update(deltaTime: 1.0 / 60); clientWorld.update(deltaTime: 1.0 / 60) } }
    func ready() throws { for _ in 0..<240 where client?.status == .waitingForAuthority { tick() }; #expect(client?.status == .running) }
    func close() { host?.stop(); client?.stop(); hostSession.stop(); clientSession.stop(); hostTransport.disconnect(); clientTransport.disconnect() }
}

@Suite struct KinematicMovementTests {
    @Test func diagonalAndBoundsRespectTheSharedSpeedLimit() throws {
        let rules = KinematicMovement2D(maximumSpeed: 120, bounds: .init(center: .zero, size: [20, 20]))
        let step = try rules.step(.init(position: [9, 9]), direction: [0.70710677, 0.70710677], deltaTime: 0.1)
        #expect(step.position == [10, 10] && step.velocity == [10, 10])
        #expect(throws: KinematicMovementError.invalidInput) { try rules.step(.init(), direction: [1, 1], deltaTime: 0.1) }
    }
    @Test func invalidNumbersAndDurationsFail() {
        let rules = KinematicMovement2D()
        #expect(throws: KinematicMovementError.invalidInput) { try rules.validate(direction: [.nan, 0]) }
        #expect(throws: KinematicMovementError.invalidState) { try rules.validate(state: .init(position: [.infinity, 0])) }
        #expect(throws: KinematicMovementError.invalidDuration) { try rules.step(.init(), direction: .zero, deltaTime: 1) }
    }
}
@MainActor @Suite(.serialized) struct NetworkMovementTests {
    @Test func localMovementIsImmediateWhileCanonicalReplicaWaitsForTheHost() throws {
        let rig = try MovementRig(latency: 0.15); defer { rig.close() }; try rig.ready()
        try rig.client?.setInput([1, 0]); rig.tick()
        #expect(rig.client!.predictedState.position.x > 0 && rig.actor.position.x == 0)
        let replica = try #require(rig.clientSession.entity(withNetworkID: rig.actor.components[SynchronizationComponent.self]!.id))
        #expect(replica.position.x == 0 && !rig.visual.components.has(SynchronizationComponent.self))
    }
    @Test func pendingInputsAreAcknowledgedAndBothSidesConverge() throws {
        let rig = try MovementRig(latency: 0.1); defer { rig.close() }; try rig.ready()
        try rig.client?.setInput([1, 0]); rig.tick(25); try rig.client?.setInput(.zero); rig.tick(120)
        #expect(rig.client?.status == .running && rig.host?.status == .running)
        #expect(rig.client!.acknowledgedInput > 0 && rig.client!.pendingInputCount > 0)
        #expect(abs(rig.client!.predictedState.position.x - rig.actor.position.x) < 0.01)
    }
    @Test func hostCorrectionsReplayPendingInputAndSmoothOnlyTheLocalVisual() throws {
        let rig = try MovementRig(latency: 0.05); defer { rig.close() }; try rig.ready()
        rig.tick(12); try rig.host?.correct(to: [40, 0]); rig.tick(15)
        #expect(rig.client!.predictedState.position.x == 40 && rig.client!.authoritativeState.position.x == 40)
        #expect(rig.client!.correctionCount > 0 && rig.visual.position.x > 0 && rig.visual.position.x < 40)
        rig.tick(120); #expect(abs(rig.visual.position.x - 40) < 0.01)
    }
    @Test func droppedAndJitteredUnreliableResultsAreRepairedByLaterCompleteStates() throws {
        let rig = try MovementRig(latency: 0.05, loss: 0.4); defer { rig.close() }; try rig.ready()
        try rig.client?.setInput([1, 0])
        for i in 0..<90 { rig.hub.latency = i.isMultiple(of: 2) ? 0.02 : 0.12; rig.tick() }
        try rig.client?.setInput(.zero); rig.hub.latency = 0.05; rig.tick(180)
        #expect(rig.client?.status == .running && rig.host?.status == .running)
        #expect(abs(rig.client!.predictedState.position.x - rig.actor.position.x) < 0.01)
    }
    @Test func historyOverflowFailsExplicitlyWithoutUnboundedGrowth() throws {
        let rig = try MovementRig(latency: 0.15, capacity: 2); defer { rig.close() }; try rig.ready(); rig.tick(6)
        #expect(rig.client?.status == .failed && rig.client?.lastError != nil)
        #expect(rig.client?.pendingInputCount == 0)
    }
    @Test func wrongFixedDurationOwnershipChangesAndSessionTeardownRetireControllers() throws {
        let rig = try MovementRig(); defer { rig.close() }; try rig.ready()
        rig.hostWorld.fixedStep = .init(stepsPerSecond: 30); rig.tick()
        rig.tick(2); #expect(rig.host?.status == .failed)
        rig.clientSession.stop(); rig.clientWorld.update(deltaTime: 0)
        #expect(rig.client?.status == .stopped)
    }
    @Test func invalidHeldInputDoesNotChangeTheNextTickAndStopClearsIt() throws {
        let rig = try MovementRig(); defer { rig.close() }; try rig.ready()
        #expect(throws: KinematicMovementError.invalidInput) { try rig.client?.setInput([10, 0]) }
        rig.tick(); #expect(rig.client?.predictedState.position == .zero)
        rig.client?.stop(); #expect(throws: NetworkMovementError.invalidSetup) { try rig.client?.setInput([1, 0]) }
    }
    @Test func missingFixedClockAndSynchronizedVisualsAreRejected() throws {
        let rig = try MovementRig(); defer { rig.close() }
        rig.client?.stop(); rig.clientWorld.fixedStep = nil
        #expect(throws: NetworkMovementError.invalidSetup) {
            try NetworkMovementController2D.client(in: rig.clientWorld, session: rig.clientSession,
                entityID: .init(), visual: rig.visual, rules: rig.rules)
        }
        rig.clientWorld.fixedStep = .init(); rig.visual.components.set(SynchronizationComponent())
        #expect(throws: NetworkMovementError.invalidSetup) {
            try NetworkMovementController2D.client(in: rig.clientWorld, session: rig.clientSession,
                entityID: .init(), visual: rig.visual, rules: rig.rules)
        }
    }
}

@MainActor @Suite(.serialized) struct NetworkMovementLifecycleTests {
    @Test func unrelatedApplicationMessagesDoNotRetireMovement() throws {
        let rig = try MovementRig(); defer { rig.close() }; try rig.ready()
        try rig.hostSession.sendResponse(Data("another application protocol".utf8), to: moveClient.id)
        try rig.clientSession.sendCommand(Data("another input protocol".utf8)); rig.tick(10)
        #expect(rig.client?.status == .running && rig.host?.status == .running && rig.host?.rejectedCommandCount == 0)
    }
    @Test func clientCannotPredictAForeignOrMissingReplica() throws {
        let rig = try MovementRig(); defer { rig.close() }; rig.client?.stop()
        #expect(throws: NetworkMovementError.invalidSetup) { try NetworkMovementController2D.client(in: rig.clientWorld, session: rig.clientSession, entityID: .init(), visual: rig.visual, rules: rig.rules) }
        let id = rig.actor.components[SynchronizationComponent.self]!.id
        let source = try #require(rig.clientSession.entity(withNetworkID: id)); source.components[SynchronizationComponent.self]?.owner = moveHost.id
        #expect(throws: NetworkMovementError.invalidSetup) { try NetworkMovementController2D.client(in: rig.clientWorld, session: rig.clientSession, entityID: id, visual: rig.visual, rules: rig.rules) }
    }
    @Test func ownershipChangesRetireBothControllersWithoutWritingTheReplica() throws {
        let rig = try MovementRig(); defer { rig.close() }; try rig.ready()
        rig.actor.components[SynchronizationComponent.self]?.owner = moveHost.id
        rig.tick(20)
        #expect(rig.host?.status == .failed && rig.client?.status == .failed)
    }
    @Test func rebuiltClientRequestsAFreshHostEpochAndCannotReuseOldPendingInput() throws {
        let rig = try MovementRig(); defer { rig.close() }; try rig.ready()
        let old = try #require(rig.client?.stream)
        try rig.client?.setInput([1, 0]); rig.tick(4); rig.client?.stop()
        let id = rig.actor.components[SynchronizationComponent.self]!.id
        rig.client = try .client(in: rig.clientWorld, session: rig.clientSession, entityID: id, visual: rig.visual, rules: rig.rules)
        try rig.ready(); let new = try #require(rig.client?.stream)
        #expect(old.epoch != new.epoch && old.owner == new.owner)
        #expect(rig.client?.pendingInputCount == 0 && rig.client?.acknowledgedInput == 0)
    }
    @Test func peerDepartureAndReleasedControllersDoNotKeepSimulationAlive() throws {
        let rig = try MovementRig(); defer { rig.close() }; try rig.ready()
        weak var old = rig.client; rig.client = nil
        #expect(old == nil)
        rig.clientTransport.disconnect(); rig.hub.advance(by: 0); rig.hostWorld.update(deltaTime: 1.0 / 60)
        #expect(rig.host?.status == .stopped)
    }
    @Test func zeroSmoothingAndLargeCorrectionsSnapImmediately() throws {
        let rig = try MovementRig(smoothing: 0); defer { rig.close() }; try rig.ready()
        try rig.host?.correct(to: [40, 0]); rig.tick(12)
        #expect(rig.visual.position == [40, 0] && rig.client?.correctionCount == 1)
    }
}

@MainActor @Suite(.serialized) struct NetworkMovementLossTests {
    @Test func totalUnreliableLossLeavesAcknowledgmentsPendingUntilAReliableCorrection() throws {
        let rig = try MovementRig(loss: 1); defer { rig.close() }; try rig.ready()
        try rig.client?.setInput([1, 0]); rig.tick(30)
        #expect(rig.actor.position.x > 0 && rig.client?.acknowledgedInput == 0 && rig.client!.pendingInputCount >= 30)
        try rig.client?.setInput(.zero); try rig.host?.correct(to: [40, 0]); rig.tick(12)
        #expect(rig.client!.acknowledgedInput > 0 && rig.client!.pendingInputCount < 30)
        #expect(rig.client?.status == .running)
    }
}
