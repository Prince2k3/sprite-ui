import ECSCore
import Foundation
@testable import SpriteUIGameCenter
import Testing

private let partyAlice = NetworkPeer(id: .init(rawValue: "a"), displayName: "Alice")
private let partyBob = NetworkPeer(id: .init(rawValue: "b"), displayName: "Bob")
@MainActor private func partyService(_ player: NetworkPeer, code: String = "1234-5678") async throws -> GameCenterServices {
    let services = GameCenterServices.preview(player: player)
    try services.activities.configurePreview([.init(id: "arena", title: "Arena", supportsPartyCode: true)])
    _ = try await services.activities.load()
    _ = try await services.activities.start(definitionID: "arena", partyCode: code)
    return services
}
@MainActor private final class PartyPair {
    let a: GameCenterServices, b: GameCenterServices, preview: GameCenterPartyPreview
    let firstWorld = World(), secondWorld = World()
    init(a: GameCenterServices, b: GameCenterServices, preview: GameCenterPartyPreview) { self.a = a; self.b = b; self.preview = preview }
    static func make() async throws -> PartyPair {
        let a = try await partyService(partyAlice), b = try await partyService(partyBob)
        let fixture = try GameCenterPartyPreview(players: [partyBob, partyAlice])
        try a.party.configurePreview(fixture); try b.party.configurePreview(fixture)
        let first = Task { @MainActor in try await a.party.findMatch() }
        let second = Task { @MainActor in try await b.party.findMatch() }
        try await first.value; try await second.value
        let pair = PartyPair(a: a, b: b, preview: fixture); pair.pump(); return pair
    }
    func pump(_ count: Int = 8) { for _ in 0..<count { preview.advance() } }
    func ready() throws {
        try a.party.prepare(in: firstWorld, compatibilityID: "arena.v1")
        try b.party.prepare(in: secondWorld, compatibilityID: "arena.v1")
        try a.party.setReady(true); try b.party.setReady(true); pump()
    }
    func close() { a.shutdown(); b.shutdown() }
}

@MainActor @Suite(.serialized) struct GameCenterPartyTests {
    @Test func constructionDoesNothingAndPreviewRequiresAnExplicitFixture() async throws {
        let services = GameCenterServices.preview()
        #expect(services.party.state == .idle && services.party.members.isEmpty && services.networkSession == nil)
        #expect(services.destination == nil && services.multiplayer.authenticationState == .unauthenticated)
        await #expect(throws: GameCenterServiceError.activityEnded) { try await services.party.findMatch() }
        let configured = try await partyService(partyAlice)
        await #expect(throws: GameCenterServiceError.unavailable) { try await configured.party.findMatch() }
        #expect(configured.party.state == .failed && configured.activities.activity?.state == .active)
    }
    @Test func fixtureRejectsInvalidRostersAndLiveInjection() throws {
        #expect(throws: GameCenterServiceError.invalidData) { try GameCenterPartyPreview(players: [partyAlice]) }
        #expect(throws: GameCenterServiceError.invalidData) { try GameCenterPartyPreview(players: [partyAlice, partyAlice]) }
        let services = GameCenterServices()
        #expect(throws: GameCenterServiceError.unavailable) { try services.party.configurePreview(GameCenterPartyPreview(players: [partyAlice, partyBob])) }
    }
    @Test func lobbyUsesTheCompleteFixedRosterAndDeterministicHost() async throws {
        let pair = try await PartyPair.make(); defer { pair.close() }
        #expect(pair.a.party.state == .lobby && pair.b.party.state == .lobby)
        #expect(pair.a.party.members.map(\.id) == [partyAlice.id, partyBob.id])
        #expect(pair.a.party.hostPeerID == partyAlice.id && pair.b.party.hostPeerID == partyAlice.id)
        #expect(pair.a.party.members.allSatisfy { !$0.isReady } && !pair.a.party.canStart)
        #expect(pair.a.networkSession == nil && pair.b.networkSession == nil)
    }
    @Test func preparationAndReadinessAreExplicitAndCompatibilityMustMatch() async throws {
        let pair = try await PartyPair.make(); defer { pair.close() }
        #expect(throws: GameCenterServiceError.invalidValue) { try pair.a.party.setReady(true) }
        try pair.a.party.prepare(in: pair.firstWorld, compatibilityID: "arena.v1")
        try pair.b.party.prepare(in: pair.secondWorld, compatibilityID: "arena.v2")
        try pair.a.party.setReady(true); try pair.b.party.setReady(true); pair.pump()
        #expect(!pair.a.party.canStart)
        #expect(throws: GameCenterServiceError.invalidValue) { try pair.a.party.startSession() }
        try pair.b.party.prepare(in: pair.secondWorld, compatibilityID: "arena.v1"); pair.pump()
        #expect(!pair.a.party.canStart)
        try pair.b.party.setReady(true); pair.pump()
        #expect(pair.a.party.canStart && !pair.b.party.canStart)
    }
    @Test func hostCommitsOnlyAfterEveryPreparedWorldAcknowledges() async throws {
        let pair = try await PartyPair.make(); defer { pair.close() }; try pair.ready()
        #expect(throws: GameCenterServiceError.invalidValue) { try pair.b.party.startSession() }
        try pair.a.party.startSession()
        #expect(pair.a.party.state == .starting && pair.b.party.state == .lobby)
        pair.preview.advance()
        #expect(pair.b.party.state == .starting && pair.a.party.state == .starting)
        pair.pump()
        #expect(pair.a.party.state == .playing && pair.b.party.state == .playing)
        #expect(pair.a.networkSession?.isHost == true && pair.b.networkSession?.isHost == false)
    }
    @Test func handoffReplicatesIntoPreparedWorldWhileOldGameplayIsUntouched() async throws {
        let pair = try await PartyPair.make(); defer { pair.close() }
        let original = World(), previousPlayer = Entity(name: "previous-player"); original.addEntity(previousPlayer)
        let actor = Entity(name: "shared", components: SynchronizationComponent()); actor.position = [42, 7]; pair.firstWorld.addEntity(actor)
        try pair.ready(); try pair.a.party.startSession(); pair.pump()
        for _ in 0..<12 { pair.firstWorld.update(deltaTime: 0.1); pair.secondWorld.update(deltaTime: 0.1); pair.pump() }
        #expect(pair.b.networkSession?.state == .connected)
        #expect(pair.secondWorld.entities.first(where: { $0.name == "shared" })?.position == [42, 7])
        #expect(original.entities.count == 1 && previousPlayer.world === original)
        pair.a.party.leave(); pair.pump()
        #expect(pair.firstWorld.entities.contains(where: { $0.id == actor.id }))
        #expect(!pair.secondWorld.entities.contains(where: { $0.name == "shared" }))
    }
    @Test func readinessWithdrawalPreventsStart() async throws {
        let pair = try await PartyPair.make(); defer { pair.close() }; try pair.ready()
        try pair.b.party.setReady(false); pair.pump()
        #expect(!pair.a.party.canStart)
        #expect(throws: GameCenterServiceError.invalidValue) { try pair.a.party.startSession() }
    }
    @Test func activityCannotBeReplacedFinishedOrDiscardedWhilePartyOwnsIt() async throws {
        let pair = try await PartyPair.make(); defer { pair.close() }
        #expect(throws: GameCenterServiceError.operationInProgress) { try pair.a.activities.finish() }
        #expect(throws: GameCenterServiceError.operationInProgress) { try pair.a.activities.discard() }
        try await pair.a.activities.setScore(17, for: "score")
        pair.a.party.leave()
        #expect(pair.a.activities.activity?.scores["score"]?.value == 17 && pair.a.activities.completedAttempts.isEmpty)
        try pair.a.activities.finish(); #expect(pair.a.activities.completedAttempts.count == 1)
    }
    @Test func leaveAndDisconnectEndTheWholeFixedPartyWithoutScoreReports() async throws {
        let pair = try await PartyPair.make(); defer { pair.close() }; try pair.ready()
        try pair.a.party.startSession(); pair.pump()
        pair.b.disconnect(); pair.pump()
        #expect(pair.a.party.state == .failed && pair.b.party.state == .idle)
        #expect(pair.a.networkSession == nil && pair.b.networkSession == nil)
        #expect(pair.a.activities.activity?.state == .active && pair.b.activities.completedAttempts.isEmpty)
    }
    @Test func shutdownReleasesPartyAndAccountChangeRetiresItsSession() async throws {
        let pair = try await PartyPair.make(); defer { pair.close() }; try pair.ready(); try pair.a.party.startSession(); pair.pump()
        pair.a.updateAuthenticatedIdentity(partyAlice.id)
        pair.a.updateAuthenticatedIdentity(.init(rawValue: "someone-else")); pair.pump()
        #expect(pair.a.party.state == .idle && pair.a.networkSession == nil)
        #expect(pair.a.party.activity == nil && pair.a.party.members.isEmpty)
        #expect(pair.b.party.state == .failed)
    }
    @Test func preparedWorldIsWeakAndDisappearingClientFailsTheBarrier() async throws {
        let pair = try await PartyPair.make(); defer { pair.close() }
        try pair.a.party.prepare(in: pair.firstWorld, compatibilityID: "v1")
        var detached: World? = World(); weak var weakWorld = detached
        try pair.b.party.prepare(in: #require(detached), compatibilityID: "v1")
        try pair.a.party.setReady(true); try pair.b.party.setReady(true); detached = nil; pair.pump()
        #expect(weakWorld == nil)
        try pair.a.party.startSession(); pair.pump()
        #expect(pair.a.party.state == .failed && pair.b.party.state == .failed)
    }
    @Test func worldAlreadyInUseFailsWithoutStoppingTheOriginalSession() async throws {
        let pair = try await PartyPair.make(); defer { pair.close() }; try pair.ready()
        let hub = InMemoryNetwork(), transport = try hub.connect(.init(id: .init(rawValue: "old"), displayName: "Old"))
        let old = NetworkSession(world: pair.firstWorld, transport: transport, role: .host); try old.start(); defer { old.stop() }
        #expect(throws: NetworkSessionError.worldInUse) { try pair.a.party.startSession() }; pair.pump()
        #expect(old.state == .connected && pair.b.party.state == .failed)
    }
    @Test func cancellationOfPartialMatchIsPromptAndRetryUsesAFreshConnection() async throws {
        let a = try await partyService(partyAlice), b = try await partyService(partyBob)
        defer { a.shutdown(); b.shutdown() }
        let fixture = try GameCenterPartyPreview(players: [partyAlice, partyBob])
        try a.party.configurePreview(fixture); try b.party.configurePreview(fixture)
        let first = Task { @MainActor in try await a.party.findMatch() }
        while a.party.state != .matching { await Task.yield() }
        first.cancel()
        await #expect(throws: GameCenterServiceError.cancelled) { try await first.value }
        #expect(a.party.state == .failed && a.activities.activity?.state == .active)
        let retry = Task { @MainActor in try await a.party.findMatch() }
        let second = Task { @MainActor in try await b.party.findMatch() }
        try await retry.value; try await second.value
        #expect(a.party.state == .lobby && b.party.state == .lobby)
    }
    @Test func incorrectPartyCodeDoesNotJoinAnotherFixtureParty() async throws {
        let a = try await partyService(partyAlice), b = try await partyService(partyBob, code: "1111-2222")
        defer { a.shutdown(); b.shutdown() }
        let fixture = try GameCenterPartyPreview(players: [partyAlice, partyBob])
        try a.party.configurePreview(fixture); try b.party.configurePreview(fixture)
        let first = Task { @MainActor in try await a.party.findMatch() }
        while a.party.state != .matching { await Task.yield() }
        for _ in 0..<5 { await Task.yield() }
        await #expect(throws: GameCenterServiceError.invalidData) { try await b.party.findMatch() }
        a.party.leave(); await #expect(throws: GameCenterServiceError.cancelled) { try await first.value }
    }
    @Test func ordinaryMatchmakingCannotOverlapThePartyLobby() async throws {
        let pair = try await PartyPair.make(); defer { pair.close() }
        pair.a.present(.matchmaking)
        #expect(pair.a.destination == nil && pair.a.lastError == .operationInProgress)
        #expect(throws: GameCenterServiceError.operationInProgress) { try pair.a.presentMatchmaking() }
        let hub = InMemoryNetwork(), transport = try hub.connect(.init(id: .init(rawValue: "separate"), displayName: "Separate"))
        #expect(throws: GameCenterServiceError.operationInProgress) {
            try pair.a.attachSession(in: World(), transport: transport, host: transport.localPeer.id)
        }
    }
    @Test func missingAcknowledgmentTimesOutAndDiscardsHandoff() async throws {
        let pair = try await PartyPair.make(); defer { pair.close() }; try pair.ready()
        pair.a.party.handoffTimeout = 0.01
        try pair.a.party.startSession()
        try await Task.sleep(for: .milliseconds(30))
        #expect(pair.a.party.state == .failed && pair.a.networkSession == nil)
    }
}

@MainActor @Suite(.serialized) struct GameCenterPartyBoundaryTests {
    private func rawLobby() async throws -> (GameCenterServices, InMemoryNetwork, InMemoryNetworkTransport, InMemoryNetworkTransport) {
        let service = try await partyService(partyAlice), hub = InMemoryNetwork()
        let local = try hub.connect(partyAlice), remote = try hub.connect(partyBob)
        service.party.findOverride = { _ in GameCenterPartyMatch(transport: local) }
        try await service.party.findMatch()
        return (service, hub, local, remote)
    }
    @Test func aNonHostCannotLaunchOrCommitTheParty() async throws {
        let (service, hub, _, remote) = try await rawLobby(); defer { service.shutdown() }
        let world = World(); try service.party.prepare(in: world, compatibilityID: "v1"); try service.party.setReady(true)
        let packet = GameCenterPartyPacket(kind: .launch, definition: "arena", code: "1234-5678", roster: [partyAlice.id, partyBob.id], compatibility: "v1", ready: true, launch: UUID())
        try remote.send(GameCenterPartyChannel.prefix + JSONEncoder().encode(packet), to: partyAlice.id, reliably: true)
        hub.advance(by: 0)
        #expect(service.party.state == .failed && service.networkSession == nil && world.entities.isEmpty)
    }
    @Test func mismatchedRosterAndMalformedControlFailClosed() async throws {
        for malformed in [true, false] {
            let (service, hub, _, remote) = try await rawLobby(); defer { service.shutdown() }
            let packet = GameCenterPartyPacket(kind: .status, definition: "arena", code: "1234-5678", roster: [partyBob.id])
            let payload = malformed ? Data("invalid json".utf8) : try JSONEncoder().encode(packet)
            try remote.send(GameCenterPartyChannel.prefix + payload, to: partyAlice.id, reliably: true); hub.advance(by: 0)
            #expect(service.party.state == .failed && service.networkSession == nil)
        }
    }
    @Test func preHandoffDataIsBoundedInsteadOfGrowingWithoutLimit() async throws {
        let (service, hub, _, remote) = try await rawLobby(); defer { service.shutdown() }
        for _ in 0..<65 { try remote.send(Data([42]), to: partyAlice.id, reliably: true) }
        hub.advance(by: 0)
        #expect(service.party.state == .failed && service.party.lastError != nil)
    }
    @Test func lateRosterGrowthEndsTheFixedParty() async throws {
        let (service, hub, _, _) = try await rawLobby(); defer { service.shutdown() }
        _ = try hub.connect(.init(id: .init(rawValue: "late"), displayName: "Late player"))
        hub.advance(by: 0)
        #expect(service.party.state == .failed && service.networkSession == nil)
    }
    @Test func retirementRejectsALateSuccessfulMatchAndDisconnectsIt() async throws {
        let service = try await partyService(partyAlice); defer { service.shutdown() }
        let hub = InMemoryNetwork(), local = try hub.connect(partyAlice), remote = try hub.connect(partyBob)
        var release: CheckedContinuation<Void, Never>?
        service.party.findOverride = { _ in
            await withCheckedContinuation { release = $0 }
            return GameCenterPartyMatch(transport: local)
        }
        let task = Task { @MainActor in try await service.party.findMatch() }
        for _ in 0..<100 where release == nil { await Task.yield() }
        #expect(release != nil)
        service.party.leave()
        await #expect(throws: GameCenterServiceError.cancelled) { try await task.value }
        release?.resume()
        for _ in 0..<20 { await Task.yield() }
        #expect(service.party.state == .idle && service.party.members.isEmpty)
        #expect(remote.connectedPeers.isEmpty)
    }
    @Test func stoppingTheAttachedSessionRetiresThePartyOnNextObservation() async throws {
        let pair = try await PartyPair.make(); defer { pair.close() }; try pair.ready(); try pair.a.party.startSession(); pair.pump()
        pair.a.networkSession?.stop()
        #expect(pair.a.party.state == .failed && pair.a.networkSession == nil)
    }
    @Test func idleServicesDoNotRetainTheirFacade() {
        var service: GameCenterServices? = .preview()
        weak var weakParty = service?.party
        service = nil
        #expect(weakParty == nil)
    }
}
