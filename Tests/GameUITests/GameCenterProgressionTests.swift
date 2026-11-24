import ECSCore
import Foundation
import Gameplay
@testable import GameUI
import Testing

private let progressionNow = Date(timeIntervalSince1970: 2_000)
private let progressionPlayer = NetworkPeer(id: .init(rawValue: "alice"), displayName: "Alice")

private func makeJournal(player: String = "alice") throws -> QuestJournal {
    try QuestJournal(playerID: player, quests: [QuestDefinition(id: "coins", title: "Collect coins", objectives: [
        QuestObjective(id: "coin-count", metric: "coin", target: 4)])])
}

private func makeLeague(player: String = "alice") throws -> LeagueSeason {
    try LeagueSeason(id: "week1", title: "Week one",
        window: ProgressionWindow(start: progressionNow, end: progressionNow.addingTimeInterval(100)),
        tiers: [LeagueTier(id: "bronze", title: "Bronze")],
        participants: [LeagueParticipant(id: player, displayName: player, tierID: "bronze")], rules: LeagueRules())
}

@MainActor @Suite struct GameCenterProgressionTests {
    @Test func explicitQuestReportsUsePreviewAchievements() async throws {
        let services = GameCenterServices.preview(player: progressionPlayer)
        var journal = try makeJournal()
        let mappings = [GameCenterQuestMapping(questID: "coins", achievementID: "coin-milestone")]
        try journal.record(QuestEvent(id: "one", metric: "coin", amount: 2, at: progressionNow))
        #expect(services.achievements.achievements.isEmpty)
        try await services.progression.report(journal, using: mappings, at: progressionNow)
        #expect(services.achievements.achievements.first?.percentComplete == 50)
        try journal.record(QuestEvent(id: "two", metric: "coin", amount: 2, at: progressionNow))
        try journal.claim("coins", at: progressionNow)
        try await services.progression.report(journal, using: mappings, at: progressionNow)
        #expect(services.achievements.achievements.first?.percentComplete == 100)
        #expect(services.destination == nil)
    }

    @Test func allMappingsAreValidatedBeforeAnyWrite() async throws {
        let services = GameCenterServices.preview(player: progressionPlayer)
        var journal = try makeJournal()
        try journal.record(QuestEvent(id: "one", metric: "coin", amount: 2, at: progressionNow))
        await #expect(throws: ProgressionError.unknownQuest) {
            try await services.progression.report(journal, using: [
                .init(questID: "coins", achievementID: "valid"), .init(questID: "missing", achievementID: "other")], at: progressionNow)
        }
        #expect(services.achievements.achievements.isEmpty)
        await #expect(throws: GameCenterServiceError.invalidValue) {
            try await services.progression.report(journal, using: [
                .init(questID: "coins", achievementID: "valid"), .init(questID: "coins", achievementID: "other")], at: progressionNow)
        }
        #expect(services.achievements.achievements.isEmpty)
    }

    @Test func foreignJournalCannotReportToCurrentAccount() async throws {
        let services = GameCenterServices.preview(player: progressionPlayer)
        let journal = try makeJournal(player: "bob")
        await #expect(throws: GameCenterServiceError.accountChanged) {
            try await services.progression.report(journal, using: [], at: progressionNow)
        }
        #expect(services.achievements.achievements.isEmpty)
    }

    @Test func leagueSubmitsOnlyLocalPlayersPointsWithContext() async throws {
        let services = GameCenterServices.preview(player: progressionPlayer)
        var league = try makeLeague()
        try league.record(LeagueResult(id: "match", scores: ["alice": 20], at: progressionNow))
        try await services.progression.submit(league, using: .init(seasonID: "week1", leaderboardID: "weekly", context: 42), at: progressionNow)
        let page = try await services.leaderboards.entries(for: "weekly")
        #expect(page.localPlayerEntry?.score == 20)
        #expect(page.localPlayerEntry?.context == 42)
        #expect(page.localPlayerEntry?.player.id == progressionPlayer.id)
        #expect(league.placements.isEmpty)
    }

    @Test func leagueMappingWindowAndOwnerMustMatch() async throws {
        let services = GameCenterServices.preview(player: progressionPlayer)
        let league = try makeLeague()
        await #expect(throws: GameCenterServiceError.invalidValue) {
            try await services.progression.submit(league, using: .init(seasonID: "other", leaderboardID: "weekly"), at: progressionNow)
        }
        await #expect(throws: GameCenterServiceError.invalidValue) {
            try await services.progression.submit(league, using: .init(seasonID: "week1", leaderboardID: "weekly"), at: league.window.end)
        }
        let foreign = try makeLeague(player: "bob")
        await #expect(throws: GameCenterServiceError.accountChanged) {
            try await services.progression.submit(foreign, using: .init(seasonID: "week1", leaderboardID: "weekly"), at: progressionNow)
        }
        #expect(services.leaderboards.lastResults == nil)
    }

    @Test func cancellingReportingDoesNotRollBackLocalClaims() async throws {
        let services = GameCenterServices.preview(player: progressionPlayer)
        var journal = try makeJournal()
        try journal.record(QuestEvent(id: "one", metric: "coin", amount: 4, at: progressionNow))
        try journal.claim("coins", at: progressionNow)
        let saved = journal
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await services.progression.report(saved, using: [.init(questID: "coins", achievementID: "first")], at: progressionNow)
        }
        do { try await task.value; Issue.record("Expected cancellation") } catch { }
        #expect(journal == saved)
        #expect(services.achievements.achievements.isEmpty)
    }

    @Test func resetDuringNativeReportRetiresTheResult() async throws {
        let context = GameCenterServiceContext(mode: .preview(player: progressionPlayer))
        let achievements = GameCenterAchievements(context: context, backend: .init(load: { _ in [] }, report: { _, _, _, _ in
            context.invalidate()
        }))
        let leaderboards = GameCenterLeaderboards(context: context)
        let bridge = GameCenterProgression(context: context, achievements: achievements, leaderboards: leaderboards)
        var journal = try makeJournal()
        try journal.record(QuestEvent(id: "one", metric: "coin", amount: 4, at: progressionNow))
        await #expect(throws: GameCenterServiceError.cancelled) {
            try await bridge.report(journal, using: [.init(questID: "coins", achievementID: "first")], at: progressionNow)
        }
        #expect(achievements.achievements.isEmpty)
    }
}
