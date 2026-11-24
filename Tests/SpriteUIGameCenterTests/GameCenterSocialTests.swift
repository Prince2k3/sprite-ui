import ECSCore
import Foundation
@testable import SpriteUIGameCenter
import Testing

private let socialDefinition = GameCenterActivityDefinition(id: "score-attack", title: "Score attack", defaultProperties: ["level": "arena"], supportsPartyCode: true)
private let socialChallenge = GameCenterChallengeDefinition(id: "sprint", title: "Sprint", leaderboardID: "scores", isRepeatable: true)
private let socialPlayer = NetworkPeer(id: .init(rawValue: "alice"), displayName: "Alice")
@MainActor private func socialPreview() throws -> GameCenterServices {
    let services = GameCenterServices.preview(player: socialPlayer)
    try services.activities.configurePreview([socialDefinition]); try services.activities.configureRoutes([socialDefinition.id])
    try services.challenges.configurePreview([socialChallenge], activeChallengeIDs: [socialChallenge.id])
    return services
}

@MainActor private final class SocialPause {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func resume() { continuation?.resume(); continuation = nil }
}
@MainActor private final class SocialHandle: GameCenterActivityHandle {
    var phase = GameCenterActivityState.initialized
    var cleared = false
    var snapshot: GameCenterActivity {
        .init(id: id, definitionID: socialDefinition.id, properties: ["level": "arena"], partyCode: nil, partyURL: nil,
              state: phase, createdAt: createdAt, scores: [:], achievementProgress: [:])
    }
    let id: String
    private let createdAt = Date()
    init(id: String = UUID().uuidString) { self.id = id }
    func activate() { phase = .active }; func pause() { phase = .paused }; func resume() { phase = .active }
    func setScore(_ score: GameCenterActivityScore, for identifier: String) async throws {}
    func setProgress(_ progress: Double, for identifier: String) {}
    func clearResults() { cleared = true }; func end() { phase = .ended }
}
@MainActor private func socialDriver(
    load: @escaping @MainActor () async throws -> [GameCenterActivityDefinition] = { [socialDefinition] },
    listen: @escaping @MainActor (@escaping @MainActor (String, any GameCenterActivityHandle) -> Bool) throws -> (() -> Void) = { _ in {} }
) -> GameCenterActivitiesDriver {
    .init(load: load, make: { _, _, _ in SocialHandle() }, listen: listen, hasPending: { true }, validatesPartyCode: { _ in true })
}

@MainActor @Suite(.serialized) struct GameCenterActivitiesTests {
    @Test func constructionAndConfigurationDoNotListenOrAuthenticate() throws {
        let services = try socialPreview()
        #expect(!services.activities.isListening && services.activities.definitions.isEmpty)
        #expect(services.activities.pendingRequests.isEmpty && services.activities.activity == nil)
        #expect(services.multiplayer.authenticationState == .unauthenticated && services.destination == nil)
    }
    @Test func lifecycleStagesLatestScoreUntilOneExplicitFinish() async throws {
        let services = try socialPreview()
        _ = try await services.activities.load()
        let started = try await services.activities.start(definitionID: socialDefinition.id, partyCode: "1234-5678", properties: ["level": "second"])
        #expect(started.state == .active && started.properties["level"] == "second")
        try services.activities.pause(); #expect(services.activities.activity?.state == .paused)
        try services.activities.resume(); #expect(services.activities.activity?.state == .active)
        try await services.activities.setScore(100, for: "scores", context: UInt64.max)
        try await services.activities.setScore(40, for: "scores", context: 7)
        try services.activities.setAchievementProgress(50, for: "medal")
        #expect(services.activities.completedAttempts.isEmpty)
        #expect(services.leaderboards.lastResults == nil && services.achievements.achievements.isEmpty)
        let finished = try services.activities.finish()
        #expect(finished.activity.state == .ended && finished.activity.scores["scores"] == .init(40, context: 7))
        #expect(finished.activity.achievementProgress["medal"] == 50)
        #expect(services.activities.completedAttempts.count == 1)
        #expect(throws: GameCenterServiceError.activityEnded) { try services.activities.finish() }
    }
    @Test func subsequentActivitiesKeepLowerAttemptScores() async throws {
        let services = try socialPreview(); _ = try await services.activities.load()
        for score in [100, 20] {
            _ = try await services.activities.start(definitionID: socialDefinition.id)
            try await services.activities.setScore(score, for: "scores"); try services.activities.finish()
        }
        #expect(services.activities.completedAttempts.map { $0.activity.scores["scores"]?.value } == [100, 20])
    }
    @Test func discardClearsResultsAndDoesNotRecordACompletedAttempt() async throws {
        let services = try socialPreview(); _ = try await services.activities.load()
        _ = try await services.activities.start(definitionID: socialDefinition.id)
        try await services.activities.setScore(10, for: "scores")
        try services.activities.setAchievementProgress(100, for: "medal")
        try services.activities.discard()
        #expect(services.activities.activity?.state == .ended && services.activities.activity?.scores.isEmpty == true)
        #expect(services.activities.completedAttempts.isEmpty)
    }
    @Test func incomingIntentWaitsForApplicationAndDoesNotReplaceRunningActivity() async throws {
        let services = try socialPreview(); try services.activities.startListening(); _ = try await services.activities.load()
        let current = try await services.activities.start(definitionID: socialDefinition.id)
        let request = try #require(try services.activities.simulateIncomingActivity(definitionID: socialDefinition.id, instanceID: "invite", properties: ["level": "invited"]))
        #expect(services.activities.activity?.id == current.id && services.activities.pendingRequests.count == 1)
        #expect(throws: GameCenterServiceError.operationInProgress) { try services.activities.accept(request: request.id) }
        try services.activities.discard()
        let accepted = try services.activities.accept(request: request.id)
        #expect(accepted.id == "invite" && accepted.properties["level"] == "invited" && accepted.state == .active)
        #expect(services.activities.pendingRequests.isEmpty)
    }
    @Test func duplicateAndDeclinedIncomingInstancesDoNotRequeue() throws {
        let services = try socialPreview(); try services.activities.startListening()
        let first = try #require(try services.activities.simulateIncomingActivity(definitionID: socialDefinition.id, instanceID: "one"))
        #expect(try services.activities.simulateIncomingActivity(definitionID: socialDefinition.id, instanceID: "one")?.id == first.id)
        try services.activities.decline(request: first.id)
        #expect(throws: GameCenterServiceError.notFound) { try services.activities.simulateIncomingActivity(definitionID: socialDefinition.id, instanceID: "one") }
        #expect(services.activities.pendingRequests.isEmpty)
    }
    @Test func routesAndBoundsRejectUnsupportedIncomingWork() throws {
        let services = try socialPreview()
        #expect(throws: GameCenterServiceError.notFound) { try services.activities.simulateIncomingActivity(definitionID: socialDefinition.id) }
        try services.activities.startListening()
        for i in 0..<16 { try services.activities.simulateIncomingActivity(definitionID: socialDefinition.id, instanceID: "request-\(i)") }
        #expect(services.activities.pendingRequests.count == 16)
        #expect(throws: GameCenterServiceError.notFound) { try services.activities.simulateIncomingActivity(definitionID: socialDefinition.id, instanceID: "overflow") }
        try services.activities.configureRoutes([])
        #expect(services.activities.pendingRequests.isEmpty)
    }
    @Test func stopAndRestartCanReceiveAnUnconsumedIntentAgain() throws {
        let services = try socialPreview(); try services.activities.startListening()
        try services.activities.simulateIncomingActivity(definitionID: socialDefinition.id, instanceID: "pending")
        services.activities.stopListening(); try services.activities.startListening()
        try services.activities.simulateIncomingActivity(definitionID: socialDefinition.id, instanceID: "pending")
        #expect(services.activities.pendingRequests.count == 1)
    }
    @Test func invalidInputsDoNotChangeCurrentActivity() async throws {
        let services = try socialPreview(); _ = try await services.activities.load()
        await #expect(throws: GameCenterServiceError.invalidValue) { try await services.activities.start(definitionID: socialDefinition.id, partyCode: "wrong") }
        #expect(services.activities.activity == nil)
        _ = try await services.activities.start(definitionID: socialDefinition.id)
        #expect(throws: GameCenterServiceError.invalidValue) { try services.activities.setAchievementProgress(.nan, for: "medal") }
        await #expect(throws: GameCenterServiceError.invalidIdentifier) { try await services.activities.setScore(1, for: "") }
        #expect(services.activities.activity?.achievementProgress.isEmpty == true)
    }
    @Test func malformedCatalogNeverPublishesPartialDefinitions() throws {
        let services = try socialPreview()
        #expect(throws: GameCenterServiceError.invalidData) { try services.activities.configurePreview([socialDefinition, socialDefinition]) }
        #expect(services.activities.definitions.isEmpty)
        #expect(throws: GameCenterServiceError.capacityExceeded) {
            try services.activities.configureRoutes(Set((0...256).map { "route-\($0)" }))
        }
    }
    @Test func stageLimitsAllowReplacementWithoutGrowingTheAttempt() async throws {
        let services = try socialPreview(); _ = try await services.activities.load()
        _ = try await services.activities.start(definitionID: socialDefinition.id)
        for i in 0..<64 {
            try await services.activities.setScore(i, for: "board-\(i)")
            try services.activities.setAchievementProgress(10, for: "achievement-\(i)")
        }
        await #expect(throws: GameCenterServiceError.capacityExceeded) { try await services.activities.setScore(99, for: "overflow") }
        #expect(throws: GameCenterServiceError.capacityExceeded) { try services.activities.setAchievementProgress(50, for: "overflow") }
        try await services.activities.setScore(1, for: "board-0")
        #expect(services.activities.activity?.scores.count == 64)
    }
    @Test func listenerAcceptsSynchronousRegistrationDelivery() throws {
        let context = GameCenterServiceContext(mode: .preview(player: socialPlayer))
        var accepted = false, stopped = false
        let service = GameCenterActivities(context: context, driver: socialDriver(listen: { receiver in
            accepted = receiver("alice", SocialHandle(id: "cold-start")); return { stopped = true }
        }))
        try service.configureRoutes([socialDefinition.id]); try service.startListening()
        #expect(accepted && service.pendingRequests.first?.activity.id == "cold-start")
        service.stopListening(); #expect(stopped)
    }
    @Test func failedRegistrationDoesNotConsumeAnIntent() throws {
        let context = GameCenterServiceContext(mode: .preview(player: socialPlayer))
        var fails = true
        let service = GameCenterActivities(context: context, driver: socialDriver(listen: { receiver in
            _ = receiver("alice", SocialHandle(id: "cold-start"))
            if fails { throw GameCenterServiceError.unavailable }
            return {}
        }))
        try service.configureRoutes([socialDefinition.id])
        #expect(throws: GameCenterServiceError.unavailable) { try service.startListening() }
        #expect(!service.isListening && service.pendingRequests.isEmpty)
        fails = false; try service.startListening()
        #expect(service.pendingRequests.count == 1)
    }
    @Test func listenerRejectsAnotherAccountAndEndedInstances() throws {
        let context = GameCenterServiceContext(mode: .preview(player: socialPlayer))
        let service = GameCenterActivities(context: context, driver: socialDriver(listen: { receiver in
            #expect(!receiver("bob", SocialHandle()))
            let ended = SocialHandle(); ended.end(); #expect(!receiver("alice", ended))
            return {}
        }))
        try service.configureRoutes([socialDefinition.id]); try service.startListening()
        #expect(service.pendingRequests.isEmpty)
    }
    @Test func retiredListenerCallbackCannotEnterANewSession() throws {
        let context = GameCenterServiceContext(mode: .preview(player: socialPlayer))
        var callbacks: [@MainActor (String, any GameCenterActivityHandle) -> Bool] = []
        let service = GameCenterActivities(context: context, driver: socialDriver(listen: { callbacks.append($0); return {} }))
        try service.configureRoutes([socialDefinition.id]); try service.startListening()
        service.stopListening(); try service.startListening()
        #expect(!callbacks[0]("alice", SocialHandle(id: "retired")))
        #expect(callbacks[1]("alice", SocialHandle(id: "current")))
        #expect(service.pendingRequests.map { $0.activity.id } == ["current"])
    }
    @Test func cancellationAndResetRetireLateCatalogLoads() async throws {
        let pause = SocialPause(), context = GameCenterServiceContext(mode: .preview(player: socialPlayer))
        let service = GameCenterActivities(context: context, driver: socialDriver(load: { await pause.wait(); return [socialDefinition] }))
        let task = Task { @MainActor in try await service.load() }
        while pause.continuation == nil { await Task.yield() }
        service.reset()
        await #expect(throws: GameCenterServiceError.cancelled) { try await task.value }
        pause.resume(); await Task.yield()
        #expect(service.definitions.isEmpty && !service.isLoading)
    }
    @Test func externallyEndedActivityDoesNotBlockTheNextRound() async throws {
        let context = GameCenterServiceContext(mode: .preview(player: socialPlayer)), handle = SocialHandle()
        var driver = socialDriver(); driver.make = { _, _, _ in handle }
        let service = GameCenterActivities(context: context, driver: driver)
        _ = try await service.load(); _ = try await service.start(definitionID: socialDefinition.id)
        handle.end()
        #expect(service.activity?.state == .ended)
        #expect(service.completedAttempts.isEmpty)
        _ = try await service.start(definitionID: socialDefinition.id)
        #expect(service.activity?.state == .active)
    }
    @Test func listenerDoesNotRetainTheOwningService() throws {
        let context = GameCenterServiceContext(mode: .preview(player: socialPlayer)); var stopped = false
        var callback: (@MainActor (String, any GameCenterActivityHandle) -> Bool)?
        var service: GameCenterActivities? = .init(context: context, driver: socialDriver(listen: { callback = $0; return { stopped = true } }))
        weak var weakService = service
        try service?.configureRoutes([socialDefinition.id]); try service?.startListening()
        service = nil
        #expect(weakService == nil && stopped)
        #expect(callback?("alice", SocialHandle()) == false)
    }
    @Test func facadeAccountChangeRetiresActivityAndPresentation() async throws {
        let services = try socialPreview(); services.updateAuthenticatedIdentity(.init(rawValue: "alice"))
        _ = try await services.activities.load(); _ = try await services.activities.start(definitionID: socialDefinition.id)
        services.present(.challengeDefinition("sprint"))
        services.updateAuthenticatedIdentity(.init(rawValue: "bob"))
        #expect(services.destination == nil && services.activities.activity == nil && services.activities.completedAttempts.isEmpty)
    }
    @Test func newDestinationsStayExplicitAndValidateIdentifiers() {
        let services = GameCenterServices.preview()
        for destination in [GameCenterDestination.activities, .challenges, .challengeOverview, .activityDefinition("activity"), .challengeDefinition("challenge")] {
            services.present(destination); #expect(services.destination == destination); services.dismiss()
        }
        services.present(.challengeDefinition(""))
        #expect(services.destination == nil && services.lastError == .invalidIdentifier)
        #expect(services.multiplayer.authenticationState == .unauthenticated)
    }
}

@MainActor @Suite(.serialized) struct GameCenterChallengeTests {
    @Test func lowerAttemptsAreRetainedWhilePreviewPersonalBestStaysHigh() async throws {
        let services = try socialPreview(); _ = try await services.challenges.load()
        let first = try await services.challenges.submitAttempt(score: 100, for: "sprint", attemptID: UUID())
        let second = try await services.challenges.submitAttempt(score: 20, for: "sprint", attemptID: UUID())
        #expect(first.status == .requested && second.status == .requested)
        #expect(services.challenges.attempts.map(\.score) == [100, 20])
        #expect(try await services.leaderboards.entries(for: "scores").localPlayerEntry?.score == 100)
        #expect(try await services.challenges.hasActiveChallenges(for: "sprint"))
    }
    @Test func requestedAttemptIDIsANoopAndCannotChangePayload() async throws {
        let services = try socialPreview(); _ = try await services.challenges.load()
        let id = UUID()
        let first = try await services.challenges.submitAttempt(score: 10, for: "sprint", attemptID: id)
        #expect(try await services.challenges.submitAttempt(score: 10, for: "sprint", attemptID: id) == first)
        await #expect(throws: GameCenterServiceError.invalidData) { try await services.challenges.submitAttempt(score: 99, for: "sprint", attemptID: id) }
        #expect(services.challenges.attempts.count == 1)
    }
    @Test func failedReportIsUncertainAndNeverRetriedAutomatically() async throws {
        let context = GameCenterServiceContext(mode: .preview(player: socialPlayer))
        var calls = 0
        let boards = GameCenterLeaderboards(context: context, backend: .init(submit: { _, _, _, _ in calls += 1; throw GameCenterServiceError.gameCenter("connection lost") }, entries: { _, _, _ in throw GameCenterServiceError.unavailable }))
        let service = GameCenterChallenges(context: context, leaderboards: boards, backend: .init(load: { [socialChallenge] }, hasActive: { _ in false }))
        _ = try await service.load(); let id = UUID()
        await #expect(throws: GameCenterServiceError.gameCenter("connection lost")) { try await service.submitAttempt(score: 5, for: "sprint", attemptID: id) }
        #expect(service.attempts.first?.status == .uncertain)
        await #expect(throws: GameCenterServiceError.attemptUncertain) { try await service.submitAttempt(score: 5, for: "sprint", attemptID: id) }
        #expect(calls == 1)
    }
    @Test func everyLowerNativeAttemptReachesTheReportingBackend() async throws {
        let context = GameCenterServiceContext(mode: .preview(player: socialPlayer)); var values: [Int] = []
        let boards = GameCenterLeaderboards(context: context, backend: .init(submit: { score, _, _, _ in values.append(score) }, entries: { _, _, _ in throw GameCenterServiceError.unavailable }))
        let service = GameCenterChallenges(context: context, leaderboards: boards, backend: .init(load: { [socialChallenge] }, hasActive: { _ in false }))
        _ = try await service.load()
        _ = try await service.submitAttempt(score: 100, for: "sprint", attemptID: UUID())
        _ = try await service.submitAttempt(score: 20, for: "sprint", attemptID: UUID())
        #expect(values == [100, 20])
    }
    @Test func cancellationAfterSubmissionStartsLeavesAnUncertainAttempt() async throws {
        let pause = SocialPause(), context = GameCenterServiceContext(mode: .preview(player: socialPlayer))
        var calls = 0
        let boards = GameCenterLeaderboards(context: context, backend: .init(submit: { _, _, _, _ in calls += 1; await pause.wait() }, entries: { _, _, _ in throw GameCenterServiceError.unavailable }))
        let service = GameCenterChallenges(context: context, leaderboards: boards, backend: .init(load: { [socialChallenge] }, hasActive: { _ in false }))
        _ = try await service.load(); let id = UUID()
        let task = Task { @MainActor in try await service.submitAttempt(score: 20, for: "sprint", attemptID: id) }
        while pause.continuation == nil { await Task.yield() }
        task.cancel()
        await #expect(throws: GameCenterServiceError.cancelled) { try await task.value }
        #expect(service.attempts.first?.status == .uncertain)
        await #expect(throws: GameCenterServiceError.attemptUncertain) { try await service.submitAttempt(score: 20, for: "sprint", attemptID: id) }
        pause.resume(); await Task.yield(); #expect(calls == 1)
    }
    @Test func attemptCapacityNeverForgetsPriorIDs() async throws {
        let services = try socialPreview(); _ = try await services.challenges.load()
        var first: GameCenterChallengeAttempt?
        for i in 0..<256 {
            let value = try await services.challenges.submitAttempt(score: i, for: "sprint", attemptID: UUID())
            if first == nil { first = value }
        }
        await #expect(throws: GameCenterServiceError.capacityExceeded) { try await services.challenges.submitAttempt(score: 1, for: "sprint", attemptID: UUID()) }
        let original = try #require(first)
        #expect(try await services.challenges.submitAttempt(score: original.score, for: original.challengeID, attemptID: original.id) == original)
        #expect(services.challenges.attempts.count == 256)
    }
    @Test func invalidCatalogAndUnloadedDefinitionsCannotSubmit() async throws {
        let services = try socialPreview()
        await #expect(throws: GameCenterServiceError.notFound) { try await services.challenges.submitAttempt(score: 1, for: "sprint", attemptID: UUID()) }
        #expect(throws: GameCenterServiceError.invalidData) { try services.challenges.configurePreview([socialChallenge, socialChallenge]) }
        #expect(services.challenges.attempts.isEmpty)
    }
    @Test func shutdownClearsAttemptLedgerWithoutGrantingRewards() async throws {
        let services = try socialPreview(); _ = try await services.challenges.load()
        _ = try await services.challenges.submitAttempt(score: 1, for: "sprint", attemptID: UUID())
        services.shutdown()
        #expect(services.challenges.attempts.isEmpty && services.challenges.definitions.isEmpty)
        #expect(services.achievements.achievements.isEmpty)
    }
}
