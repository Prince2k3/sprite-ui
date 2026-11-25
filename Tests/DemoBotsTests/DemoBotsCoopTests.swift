import Foundation
import SpriteUI
@testable import DemoBotsGame
import Testing

@MainActor private func coopPump(_ game: DemoBotsCoopSession, _ count: Int = 30) async {
    for _ in 0..<count { game.advance(deltaTime: 1.0 / 60); await Task.yield() }
}
@MainActor private func readyCoop() async throws -> DemoBotsCoopSession {
    let game = DemoBotsCoopSession(usesArtwork: false); game.previewPartnerMoves = false; game.previewPartnerFires = false; game.start()
    for _ in 0..<1000 { await coopPump(game, 1); if game.phase == "playing" && !game.busy { break } }
    try #require(game.phase == "playing", Comment(rawValue: game.message)); await coopPump(game, 20); return game
}
@MainActor @Suite(.serialized) struct DemoBotsCoopTests {
    @Test func constructionDoesNotAuthenticateMatchOrTouchTheCampaign() {
        let game = DemoBotsCoopSession(usesArtwork: false)
        #expect(game.phase == "menu" && game.services.party.state == .idle && game.services.networkSession == nil)
        #expect(game.services.multiplayer.authenticationState == .unauthenticated && game.services.destination == nil)
        #expect(game.localWorld.entities.isEmpty && !game.hasRecoveryPoint)
        game.leave()
    }
    @Test func twoIndependentPartiesReachPlayingAndOwnDifferentWorlds() async throws {
        let game = try await readyCoop(); defer { game.leave() }
        #expect(game.services.party.members.count == 2 && game.partner?.party.state == .playing)
        #expect(game.services.networkSession?.isHost == false && game.partner?.networkSession?.isHost == true)
        #expect(game.localWorld !== game.partnerWorld && game.localWorld.entities.filter { $0.components.has(CoopActor.self) }.count == 6)
        #expect(game.statistics.first?.relevantEntities ?? 0 > 0)
    }
    @Test func clientCannotBypassTheHandshakeThroughTheLocalFixtureHost() async throws {
        let game = DemoBotsCoopSession(usesArtwork: false); game.previewPartnerFires = false; game.previewPartnerMoves = false; game.start(); defer { game.leave() }
        for _ in 0..<1000 { await coopPump(game, 1); if game.phase == "playing" && !game.busy { break } }
        try #require(game.phase == "playing")
        #expect(!game.canControl); game.fire()
        #expect(game.partnerWorld?.entities.compactMap { $0.components[CoopActor.self] }.filter { $0.kind == .bot }.allSatisfy { $0.corruption == 100 } == true)
        await coopPump(game, 20); #expect(game.canControl)
    }
    @Test func localMovementIsPredictedThenBothPlayersAgreeAndStopStaysNeutral() async throws {
        let game = try await readyCoop(); defer { game.leave() }
        let owner = try #require(game.services.localPlayer?.id)
        let source = try #require(game.partnerWorld?.entities.first { $0.components[SynchronizationComponent.self]?.owner == owner })
        let before = source.position
        game.move([1, 0]); await coopPump(game, 60); game.move(.zero); await coopPump(game, 30)
        #expect(source.position.x > before.x + 100)
        let replica = try #require(game.localWorld.entities.first { $0.components[SynchronizationComponent.self]?.owner == owner })
        #expect(abs(replica.position.x - source.position.x) < 0.01)
        let stopped = source.position; await coopPump(game, 60); #expect(source.position == stopped)
    }
    @Test func confirmedBeamsCureBotsAndTheSharedRoundCanBeWon() async throws {
        let game = try await readyCoop(); defer { game.leave() }
        game.move([1, 0]); await coopPump(game, 85); game.move(.zero); await coopPump(game, 20)
        for _ in 0..<16 where !game.finished { game.fire(); await coopPump(game, 30) }
        #expect(game.cured == 4 && game.score == 400 && game.finished && game.phase == "won")
        let score = game.score; for _ in 0..<5 { game.fire() }; await coopPump(game, 30)
        #expect(game.score == score && game.pendingActions == 0)
    }
    @Test func beamBurstsCannotBypassCooldownAndCureTheSameBotRepeatedly() async throws {
        let game = try await readyCoop(); defer { game.leave() }
        for _ in 0..<5 { game.fire() }; await coopPump(game, 30)
        #expect(game.score == 0 && game.confirmedBeams == 5 && game.pendingActions == 0)
        let corruptions = game.partnerWorld!.entities.compactMap { $0.components[CoopActor.self] }.filter { $0.kind == .bot }.map(\.corruption)
        #expect(corruptions.filter { $0 == 50 }.count == 1 && corruptions.filter { $0 == 0 }.isEmpty)
    }
    @Test func explicitRecoveryRestoresSavedProgressAndDoesNotReplayHeldMovementOrActions() async throws {
        let game = try await readyCoop(); defer { game.leave() }
        game.fire(); await coopPump(game, 30); game.saveRecoveryPoint(); #expect(game.hasRecoveryPoint)
        let saved = try #require(game.partnerWorld?.entities.first { $0.name == "bot-0" }?.components[CoopActor.self]?.corruption)
        game.fire(); await coopPump(game, 30); #expect(game.cured == 1)
        let oldWorld = game.localWorld
        game.move([1, 0]); game.fire(); game.interrupt(); await coopPump(game, 10)
        #expect(game.phase == "interrupted" && !game.canControl && game.pendingActions == 0)
        game.rejoinSavedRound()
        for _ in 0..<1000 { await coopPump(game, 1); if !game.busy && game.phase == "playing" { break } }
        #expect(game.phase == "playing", Comment(rawValue: game.message)); await coopPump(game, 30)
        #expect(game.localWorld !== oldWorld && game.cured == 0 && game.score == 0)
        #expect(game.partnerWorld?.entities.first { $0.name == "bot-0" }?.components[CoopActor.self]?.corruption == saved)
        let owner = game.services.localPlayer!.id
        let source = try #require(game.partnerWorld?.entities.first { $0.components[SynchronizationComponent.self]?.owner == owner })
        let position = source.position; await coopPump(game, 90); #expect(source.position == position && game.pendingActions == 0)
    }
    @Test func leavingWhileMatchingCancelsLateWorkAndDoesNotReviveTheRound() async {
        let game = DemoBotsCoopSession(usesArtwork: false); game.start(); game.leave(); await coopPump(game, 60)
        #expect(game.phase == "menu" && !game.busy && game.services.networkSession == nil && !game.canControl)
    }
    @Test func inputSessionCancellationNeutralizesMovementAndRequiresAReleasedFireButton() async throws {
        let game = try await readyCoop(); defer { game.leave() }
        let controls = CoopInput(game: game); controls.setActive(true)
        controls.hub.submit([(.key("d"), .button(false))], device: .keyboard)
        controls.hub.submit([(.key("d"), .button(true))], device: .keyboard); await coopPump(game, 30)
        controls.setActive(false); let count = game.confirmedBeams; controls.fire(); await coopPump(game, 30)
        #expect(game.confirmedBeams == count)
        let owner = game.services.localPlayer!.id, host = game.partnerWorld!
        let actor = try #require(host.entities.first { $0.components[SynchronizationComponent.self]?.owner == owner })
        let position = actor.position; await coopPump(game, 30); #expect(actor.position == position)
        controls.setActive(true); controls.hub.submit([(.key("d"), .button(false))], device: .keyboard); controls.fire(); await coopPump(game, 30)
        #expect(game.confirmedBeams == count + 1)
        controls.suspend()
    }
}
