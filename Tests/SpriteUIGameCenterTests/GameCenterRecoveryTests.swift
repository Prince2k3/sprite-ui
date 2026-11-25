import ECSCore
import Foundation
@testable import SpriteUIGameCenter
import Testing

private let recoveryA = NetworkPeer(id: .init(rawValue: "a"), displayName: "Alice")
private let recoveryB = NetworkPeer(id: .init(rawValue: "b"), displayName: "Bob")
@MainActor private final class RecoveryPair {
    let a = GameCenterServices.preview(player: recoveryA), b = GameCenterServices.preview(player: recoveryB)
    let fixture: GameCenterPartyPreview
    var hostWorld = World(), clientWorld = World()
    init() throws {
        fixture = try GameCenterPartyPreview(players: [recoveryA, recoveryB])
        for services in [a, b] {
            try services.activities.configurePreview([.init(id: "arena", title: "Arena", supportsPartyCode: true)])
            try services.party.configurePreview(fixture)
        }
    }
    func start() async throws {
        for services in [a, b] { _ = try await services.activities.load(); _ = try await services.activities.start(definitionID: "arena", partyCode: "1234-5678") }
        try await match()
        hostWorld.addEntity(Entity(name: "actor", components: SynchronizationComponent()))
        hostWorld.entities[0].position = [36, 5]
        try a.party.prepare(in: hostWorld, compatibilityID: "arena-v1"); try b.party.prepare(in: clientWorld, compatibilityID: "arena-v1")
        try readyAndLaunch(); tick()
    }
    func match() async throws {
        async let first: Void = a.party.findMatch(); async let second: Void = b.party.findMatch()
        _ = try await (first, second); pump()
    }
    func readyAndLaunch() throws { try a.party.setReady(true); try b.party.setReady(true); pump(); try a.party.startSession(); pump() }
    func pump(_ count: Int = 8) { for _ in 0..<count { fixture.advance() } }
    func tick(_ count: Int = 10) { for _ in 0..<count { hostWorld.update(deltaTime: 0.1); clientWorld.update(deltaTime: 0.1); pump() } }
    func interrupt() { a.party.interrupt(reason: .backgrounded); pump() }
    func prepare(_ checkpoint: NetworkRecoveryCheckpoint) throws {
        try a.party.offerRecovery(checkpoint); pump()
        hostWorld = World(); clientWorld = World()
        try a.party.prepareRecovery(in: hostWorld, accepting: checkpoint.descriptor, compatibilityID: "arena-v1")
        try b.party.prepareRecovery(in: clientWorld, accepting: checkpoint.descriptor, compatibilityID: "arena-v1")
    }
    func close() { a.shutdown(); b.shutdown() }
}

@MainActor @Suite(.serialized) struct GameCenterRecoveryTests {
    @Test func interruptionPreservesTheApplicationCheckpointAndActivityWithoutAutomaticRejoin() async throws {
        let pair = try RecoveryPair(); defer { pair.close() }; try await pair.start()
        let checkpoint = try pair.a.party.recoveryCheckpoint(applicationState: Data("round-4".utf8))
        pair.interrupt()
        #expect(pair.a.party.state == .interrupted && pair.a.party.interruption?.reason == .backgrounded)
        #expect(pair.b.party.state == .failed && pair.a.networkSession == nil)
        #expect(pair.a.activities.activity?.state == .active && pair.a.activities.completedAttempts.isEmpty)
        #expect(checkpoint.applicationState == Data("round-4".utf8))
    }
    @Test func recoveryRequiresAnExactHostOfferAndExplicitContentCompatibility() async throws {
        let pair = try RecoveryPair(); defer { pair.close() }; try await pair.start()
        let checkpoint = try pair.a.party.recoveryCheckpoint(); pair.interrupt(); try await pair.match()
        #expect(throws: NetworkRecoveryError.incompatibleCheckpoint) { try pair.b.party.prepareRecovery(in: World(), accepting: checkpoint.descriptor, compatibilityID: "arena-v1") }
        try pair.a.party.offerRecovery(checkpoint); pair.pump()
        #expect(pair.b.party.recoveryOffer == checkpoint.descriptor && !pair.a.party.canStart)
        #expect(throws: NetworkRecoveryError.incompatibleCheckpoint) { try pair.b.party.prepareRecovery(in: World(), accepting: checkpoint.descriptor, compatibilityID: "arena-v2") }
        #expect(throws: NetworkRecoveryError.incompatibleCheckpoint) { try pair.b.party.prepare(in: World(), compatibilityID: "arena-v1") }
    }
    @Test func clientsCannotOfferCheckpointsAndForeignRostersAreRejected() async throws {
        let pair = try RecoveryPair(); defer { pair.close() }; try await pair.start()
        let checkpoint = try pair.a.party.recoveryCheckpoint(); pair.interrupt(); try await pair.match()
        #expect(throws: NetworkSessionError.notHost) { try pair.b.party.offerRecovery(checkpoint) }
        let other = GameCenterServices.preview(player: .init(id: .init(rawValue: "c"), displayName: "Other"))
        #expect(other.party.recoveryOffer == nil)
    }
    @Test func staleOfferDoesNotPrepareAnOlderCheckpoint() async throws {
        let pair = try RecoveryPair(); defer { pair.close() }; try await pair.start()
        let older = try pair.a.party.recoveryCheckpoint()
        pair.hostWorld.entities[0].position = [90, 0]; let current = try pair.a.party.recoveryCheckpoint()
        pair.interrupt(); try await pair.match(); try pair.a.party.offerRecovery(current); pair.pump()
        let untouched = World()
        #expect(throws: NetworkRecoveryError.incompatibleCheckpoint) { try pair.a.party.prepareRecovery(in: untouched, accepting: older.descriptor, compatibilityID: "arena-v1") }
        #expect(untouched.entities.isEmpty)
    }
    @Test func recoveryDoesNotPlayUntilClientsApplyTheFreshHostBaseline() async throws {
        let pair = try RecoveryPair(); defer { pair.close() }; try await pair.start()
        let checkpoint = try pair.a.party.recoveryCheckpoint()
        let oldWorld = pair.hostWorld, oldEntity = try #require(oldWorld.entities.first)
        pair.interrupt(); try await pair.match(); try pair.prepare(checkpoint); try pair.readyAndLaunch()
        #expect(pair.a.party.state == .resynchronizing && pair.b.party.state == .resynchronizing)
        #expect(pair.clientWorld.entities.isEmpty)
        pair.tick()
        #expect(pair.a.party.state == .playing && pair.b.party.state == .playing)
        #expect(pair.b.networkSession?.state == .connected && pair.clientWorld.entities.first?.position == [36, 5])
        #expect(oldEntity.world === oldWorld && oldEntity.position == [36, 5])
        #expect(pair.a.activities.completedAttempts.isEmpty && pair.b.party.interruption == nil)
    }
    @Test func existingSynchronizedStateIsNeverOverwrittenByRecovery() async throws {
        let pair = try RecoveryPair(); defer { pair.close() }; try await pair.start()
        let checkpoint = try pair.a.party.recoveryCheckpoint(); pair.interrupt(); try await pair.match()
        try pair.a.party.offerRecovery(checkpoint); pair.pump()
        #expect(throws: NetworkRecoveryError.worldNotEmpty) { try pair.a.party.prepareRecovery(in: pair.hostWorld, accepting: checkpoint.descriptor, compatibilityID: "arena-v1") }
        #expect(pair.hostWorld.entities.first?.position == [36, 5])
    }
    @Test func backgroundPolicyCanBeExplicitlyOptedOutAndDefaultsToInterrupt() async throws {
        let pair = try RecoveryPair(); defer { pair.close() }; try await pair.start()
        pair.a.party.recoveryConfiguration = .init(interruptsOnBackground: false)
        pair.a.party.applicationDidEnterBackground(); #expect(pair.a.party.state == .playing)
        pair.a.party.recoveryConfiguration = .init()
        pair.a.party.applicationDidEnterBackground(); #expect(pair.a.party.state == .interrupted)
    }
    @Test func resynchronizationTimeoutReleasesTheFreshMatch() async throws {
        let pair = try RecoveryPair(); defer { pair.close() }; try await pair.start()
        let checkpoint = try pair.a.party.recoveryCheckpoint(); pair.interrupt(); try await pair.match(); try pair.prepare(checkpoint)
        pair.a.party.synchronizationTimeoutOverride = 0.01
        try pair.readyAndLaunch(); pair.fixture.advance(by: 0.03)
        #expect(pair.a.party.state == .failed && pair.a.party.lastError == .timedOut)
        #expect(pair.a.party.interruption?.reason == .timedOut && pair.a.networkSession == nil)
    }
    @Test func freshMatchTimeoutDoesNotStartAnAutomaticRetry() async throws {
        let pair = try RecoveryPair(); defer { pair.close() }
        _ = try await pair.a.activities.load(); _ = try await pair.a.activities.start(definitionID: "arena", partyCode: "1234-5678")
        pair.a.party.matchingTimeoutOverride = 0.01
        let attempt = Task { @MainActor in try await pair.a.party.findMatch() }
        for _ in 0..<100 { await Task.yield(); if pair.a.party.state == .matching { break } }
        try #require(pair.a.party.state == .matching)
        pair.fixture.advance(by: 0.03)
        await #expect(throws: GameCenterServiceError.timedOut) { try await attempt.value }
        #expect(pair.a.party.state == .failed && pair.a.party.lastError == .timedOut)
        #expect(pair.a.activities.activity?.state == .active)
        pair.a.party.leave(); #expect(pair.a.party.state == .idle && pair.a.party.interruption == nil)
    }
    @Test func shutdownAndAccountChangesClearRecoveryOffersAndDoNotAutoRestore() async throws {
        let pair = try RecoveryPair(); defer { pair.close() }; try await pair.start()
        let checkpoint = try pair.a.party.recoveryCheckpoint(); pair.interrupt(); try await pair.match(); try pair.a.party.offerRecovery(checkpoint)
        pair.a.updateAuthenticatedIdentity(recoveryA.id); pair.a.updateAuthenticatedIdentity(recoveryB.id); pair.pump()
        #expect(pair.a.party.recoveryOffer == nil && pair.a.party.state == .idle && pair.a.party.interruption == nil)
        #expect(pair.b.party.state == .failed)
    }
    @Test func configurationBoundsAreFinite() {
        let policy = GameCenterRecoveryConfiguration(matchmakingTimeout: -.infinity, resynchronizationTimeout: 999)
        #expect(policy.matchmakingTimeout == 60 && policy.resynchronizationTimeout == 120)
    }
}

@MainActor @Suite(.serialized) struct GameCenterRecoveryBoundaryTests {
    @Test func aDifferentFreshRosterCannotRecoverTheOriginalGame() async throws {
        let source = try RecoveryPair(); defer { source.close() }; try await source.start()
        let checkpoint = try source.a.party.recoveryCheckpoint(); source.interrupt()
        let other = GameCenterServices.preview(player: .init(id: .init(rawValue: "c"), displayName: "Other"))
        defer { other.shutdown() }
        let fixture = try GameCenterPartyPreview(players: [recoveryA, try #require(other.localPlayer)])
        try source.a.party.configurePreview(fixture); try other.party.configurePreview(fixture)
        try other.activities.configurePreview([.init(id: "arena", title: "Arena", supportsPartyCode: true)])
        _ = try await other.activities.load(); _ = try await other.activities.start(definitionID: "arena", partyCode: "1234-5678")
        async let a: Void = source.a.party.findMatch(); async let b: Void = other.party.findMatch(); _ = try await (a, b)
        #expect(throws: NetworkRecoveryError.incompatibleCheckpoint) { try source.a.party.offerRecovery(checkpoint) }
        #expect(source.a.party.recoveryOffer == nil && source.a.party.state == .lobby)
    }
    @Test func cancellingRejoinRetiresItsLateCallbacksAndKeepsTheCheckpoint() async throws {
        let pair = try RecoveryPair(); defer { pair.close() }; try await pair.start()
        let checkpoint = try pair.a.party.recoveryCheckpoint(); pair.interrupt()
        let retry = Task { @MainActor in try await pair.a.party.findMatch() }
        for _ in 0..<100 where pair.a.party.state != .rejoining { await Task.yield() }
        #expect(pair.a.party.state == .rejoining)
        pair.a.party.interrupt(reason: .applicationRequested)
        await #expect(throws: GameCenterServiceError.cancelled) { try await retry.value }
        #expect(pair.a.party.state == .interrupted && pair.a.party.recoveryOffer == nil)
        #expect(checkpoint.descriptor.compatibilityID == "arena-v1")
    }
}

@MainActor @Suite(.serialized) struct GameCenterRecoveryScopeTests {
    @Test func theSameRosterCannotRestoreIntoADifferentPartyCode() async throws {
        let pair = try RecoveryPair(); defer { pair.close() }; try await pair.start()
        let checkpoint = try pair.a.party.recoveryCheckpoint(); pair.interrupt()
        for services in [pair.a, pair.b] {
            try services.activities.discard()
            _ = try await services.activities.start(definitionID: "arena", partyCode: "9999-8888")
        }
        try await pair.match()
        #expect(throws: NetworkRecoveryError.incompatibleCheckpoint) { try pair.a.party.offerRecovery(checkpoint) }
        #expect(pair.a.party.recoveryOffer == nil)
    }
}
