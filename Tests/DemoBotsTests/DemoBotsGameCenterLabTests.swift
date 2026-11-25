import SpriteUI
@testable import DemoBotsGame
import Testing

@MainActor private func settleLab(_ lab: DemoBotsGameCenterLab) async throws {
    for _ in 0..<300 where lab.busy { await Task.yield() }
    try #require(!lab.busy)
}
@MainActor @Suite(.serialized) struct DemoBotsGameCenterLabTests {
    @Test func challengeDiagnosticsDistinguishMissingMetadataFromMissingLeaderboard() {
        #expect(DemoBotsGameCenterLab.challengeCatalogSummary([]).contains("absent"))
        let missingBoard = GameCenterChallengeDefinition(id: DemoBotsGameCenterIDs.challenge, title: "Repair Challenge", leaderboardID: nil, isRepeatable: true)
        #expect(DemoBotsGameCenterLab.challengeCatalogSummary([missingBoard]).contains("without an associated leaderboard"))
        let linked = GameCenterChallengeDefinition(id: DemoBotsGameCenterIDs.challenge, title: "Repair Challenge", leaderboardID: DemoBotsGameCenterIDs.leaderboard, isRepeatable: true)
        #expect(DemoBotsGameCenterLab.challengeCatalogSummary([linked]).contains(DemoBotsGameCenterIDs.leaderboard))
    }
    @Test func constructionDoesNotSignInLoadStartOrReport() {
        for native in [false, true] {
            let lab = DemoBotsGameCenterLab(native: native); defer { lab.close() }
            #expect(lab.services.multiplayer.authenticationState == .unauthenticated)
            #expect(lab.services.destination == nil && lab.services.activities.activity == nil)
            #expect(lab.services.activities.definitions.isEmpty && lab.services.challenges.definitions.isEmpty)
            #expect(lab.progress == 0 && lab.reportedScore == nil && !lab.busy)
            #expect(lab.canReport == !native)
        }
    }
    @Test func missingNativeStyleChallengeMetadataDoesNotSubmitAScore() async throws {
        let lab = DemoBotsGameCenterLab(); defer { lab.close() }
        try lab.services.challenges.configurePreview([])
        lab.submitChallengeAttempt(); try await settleLab(lab)
        #expect(lab.message.contains("0 challenges") && lab.message.contains("No score was submitted"))
        #expect(lab.services.challenges.attempts.isEmpty)
        #expect(lab.services.leaderboards.lastResults == nil)
    }
    @Test func sampleProgressAndScoresUseTheSharedIDsAndHighestScorePolicy() async throws {
        let lab = DemoBotsGameCenterLab(); defer { lab.close() }
        lab.load(); try await settleLab(lab)
        #expect(lab.services.activities.definitions.map(\.id) == [DemoBotsGameCenterIDs.activity])
        lab.reportProgress(25); try await settleLab(lab); #expect(lab.progress == 25)
        lab.reportProgress(100); try await settleLab(lab); #expect(lab.progress == 100)
        lab.reportProgress(25); try await settleLab(lab); #expect(lab.progress == 100)
        lab.submitScore(100); try await settleLab(lab)
        lab.submitScore(50); try await settleLab(lab)
        #expect(lab.reportedScore == 50 && lab.services.leaderboards.lastResults?.localPlayerEntry?.score == 100)
    }
    @Test func entryPointsStayQueuedUntilExplicitAcceptanceAndActivitiesFinishWithoutRewards() async throws {
        let lab = DemoBotsGameCenterLab(); defer { lab.close() }
        lab.simulateEntryPoint(); try await settleLab(lab)
        #expect(lab.services.activities.activity == nil && lab.acceptedEntryPoints == 0)
        let request = try #require(lab.services.activities.pendingRequests.first)
        lab.acceptEntryPoint(request.id); try await settleLab(lab)
        #expect(lab.acceptedEntryPoints == 1 && lab.services.activities.activity?.state == .active)
        lab.finishActivity(); try await settleLab(lab)
        #expect(lab.services.activities.activity?.state == .ended && lab.reportedScore == nil && lab.progress == 0)
        #expect(lab.services.activities.completedAttempts.count == 1)
    }
    @Test func challengeButtonsRepresentDistinctAttemptsAndClosingCancelsPendingWork() async throws {
        let lab = DemoBotsGameCenterLab(); defer { lab.close() }
        lab.submitChallengeAttempt(); try await settleLab(lab)
        lab.submitChallengeAttempt(); try await settleLab(lab)
        let attempts = lab.services.challenges.attempts
        #expect(attempts.count == 2 && Set(attempts.map(\.id)).count == 2)
        #expect(attempts.allSatisfy { $0.challengeID == DemoBotsGameCenterIDs.challenge && $0.leaderboardID == DemoBotsGameCenterIDs.leaderboard && $0.score == 100 })
        lab.submitScore(500); lab.close(); try await settleLab(lab)
        #expect(lab.reportedScore == nil && !lab.busy && lab.services.destination == nil)
    }
}
