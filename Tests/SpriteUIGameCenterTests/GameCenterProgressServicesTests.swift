import ECSCore
import Foundation
@testable import SpriteUIGameCenter
import Testing

@MainActor @Suite struct GameCenterProgressServicesTests {
    private let player = NetworkPeer(id: .init(rawValue: "fixture-player"), displayName: "Fixture player")

    @Test func explicitPreviewAchievementsAreLocalMonotonicAndInstanceIsolated() async throws {
        let service = GameCenterAchievements(mode: .preview(player: player))
        let other = GameCenterAchievements(mode: .preview(player: player))
        #expect(try await service.load().isEmpty)
        try await service.report(progress: 50, for: "z")
        try await service.report(progress: 20, for: "z")
        try await service.unlock("a")
        try await service.unlock("a")
        #expect(service.achievements.map(\.identifier) == ["a", "z"])
        #expect(service.achievements.map(\.percentComplete) == [100, 50])
        #expect(service.achievements.allSatisfy { $0.lastReportedDate == nil })
        #expect(try await other.load().isEmpty)
        service.reset()
        #expect(try await service.load().isEmpty)
        #expect(!service.isLoading)
    }

    @Test func previewNeverCallsInjectedNativeBackends() async throws {
        var calls = 0
        let context = GameCenterServiceContext(mode: .preview(player: player))
        let achievements = GameCenterAchievements(context: context, backend: .init(load: { _ in
            calls += 1; throw GameCenterServiceError.unavailable
        }, report: { _, _, _, _ in calls += 1 }), usesPreviewStore: true)
        let boards = GameCenterLeaderboards(context: context, backend: .init(submit: { _, _, _, _ in
            calls += 1
        }, entries: { _, _, _ in calls += 1; throw GameCenterServiceError.unavailable }), usesPreviewStore: true)
        try await achievements.unlock("first")
        _ = try await achievements.load()
        try await boards.submit(score: 12, to: "scores")
        _ = try await boards.entries(for: "scores")
        #expect(calls == 0)
    }

    @Test func progressAndIdentifiersValidateBeforeBackendCalls() async throws {
        var reports = 0
        let service = achievements(report: { _, _, _, _ in reports += 1 })
        for value in [Double.nan, .infinity, -.infinity, -1, 100.01] {
            await #expect(throws: GameCenterServiceError.invalidValue) { try await service.report(progress: value, for: "valid") }
        }
        for id in ["", "  ", "a\nb", String(repeating: "x", count: 257)] {
            await #expect(throws: GameCenterServiceError.invalidIdentifier) { try await service.unlock(id) }
        }
        try await service.report(progress: 0, for: "zero")
        try await service.report(progress: 100, for: "full")
        #expect(reports == 2)
    }

    @Test func loadedCompletionAndEqualOrLowerReportsNeverRepeatBanners() async throws {
        var reports: [(String, Double, Bool)] = []
        let service = achievements(load: { _ in [.init(identifier: "old", percentComplete: 100)] },
            report: { id, value, banner, _ in reports.append((id, value, banner)) })
        _ = try await service.load()
        try await service.unlock("old")
        try await service.report(progress: 40, for: "new")
        try await service.report(progress: 10, for: "new")
        try await service.unlock("new")
        try await service.unlock("new")
        #expect(reports.count == 2)
        #expect(reports[0].1 == 40 && !reports[0].2)
        #expect(reports[1].1 == 100 && reports[1].2)
        #expect(service.achievements.allSatisfy { $0.percentComplete == 100 })
    }

    @Test func olderLoadedProgressCannotRegressSuccessfulReports() async throws {
        let service = achievements(load: { _ in [.init(identifier: "first", percentComplete: 10)] })
        try await service.report(progress: 75, for: "first")
        #expect(try await service.load().first?.percentComplete == 75)
    }

    @Test func malformedAchievementLoadsPublishNothing() async throws {
        let invalid: [[GameCenterAchievement]] = [
            [.init(identifier: "bad", percentComplete: .nan)],
            [.init(identifier: "bad", percentComplete: 101)],
            [.init(identifier: "duplicate", percentComplete: 1), .init(identifier: "duplicate", percentComplete: 2)],
            [.init(identifier: "bad", percentComplete: 1, lastReportedDate: Date(timeIntervalSinceReferenceDate: .infinity))],
            [.init(identifier: "", percentComplete: 1)],
        ]
        for values in invalid {
            let service = achievements(load: { _ in [.init(identifier: "valid", percentComplete: 20)] + values })
            await #expect(throws: GameCenterServiceError.invalidData) { try await service.load() }
            #expect(service.achievements.isEmpty)
            #expect(!service.isLoading)
        }
    }

    @Test func achievementBackendFailuresAreThrownWithoutRetryOrProgressPublication() async throws {
        var calls = 0
        let service = achievements(report: { _, _, _, _ in calls += 1; throw GameCenterServiceError.gameCenter("fixture failure") })
        await #expect(throws: GameCenterServiceError.gameCenter("fixture failure")) { try await service.unlock("first") }
        #expect(calls == 1)
        #expect(service.achievements.isEmpty)
        #expect(!service.isLoading)
    }

    @Test func achievementCancellationCleansUpBeforeDelayedBackendReturns() async throws {
        let gate = ProgressGate<Void>()
        var calls = 0
        let service = achievements(report: { _, _, _, _ in
            calls += 1
            if calls == 1 { try await gate.value() }
        })
        let task = Task { try await service.unlock("late") }
        await gate.waitUntilStarted()
        #expect(service.isLoading)
        await #expect(throws: GameCenterServiceError.operationInProgress) { try await service.unlock("busy") }
        task.cancel()
        await #expect(throws: GameCenterServiceError.cancelled) { try await task.value }
        #expect(!service.isLoading)
        try await service.unlock("current")
        gate.resolve(())
        await Task.yield()
        #expect(service.achievements.map(\.identifier) == ["current"])
    }

    @Test func cancelledBackendDoesNotRetainTheServiceUntilItsCallback() async throws {
        let gate = ProgressGate<[GameCenterAchievement]>()
        var service: GameCenterAchievements? = achievements(load: { _ in try await gate.value() })
        weak var weakService = service
        let operation = Task { [value = service!] in try await value.load() }
        await gate.waitUntilStarted()
        operation.cancel()
        await #expect(throws: GameCenterServiceError.cancelled) { try await operation.value }
        service = nil
        #expect(weakService == nil)
        gate.resolve([])
    }

    @Test func achievementResetRejectsLateResultWithoutClearingReplacementOperation() async throws {
        let first = ProgressGate<[GameCenterAchievement]>(), second = ProgressGate<[GameCenterAchievement]>()
        var calls = 0
        let service = achievements(load: { _ in
            calls += 1
            return try await (calls == 1 ? first : second).value()
        })
        let old = Task { try await service.load() }
        await first.waitUntilStarted()
        service.reset()
        let current = Task { try await service.load() }
        await second.waitUntilStarted()
        first.resolve([.init(identifier: "old", percentComplete: 100)])
        await #expect(throws: GameCenterServiceError.cancelled) { try await old.value }
        #expect(service.isLoading)
        second.resolve([.init(identifier: "new", percentComplete: 25)])
        #expect(try await current.value.map(\.identifier) == ["new"])
        #expect(!service.isLoading)
    }

    @Test func sharedContextInvalidationClearsAchievementStateAndRejectsOldResults() async throws {
        let context = GameCenterServiceContext(mode: .preview(player: player))
        let gate = ProgressGate<[GameCenterAchievement]>()
        let service = GameCenterAchievements(context: context, backend: .init(load: { _ in try await gate.value() }, report: { _, _, _, _ in }))
        try await service.unlock("cached")
        let old = Task { try await service.load() }
        await gate.waitUntilStarted()
        context.invalidate()
        #expect(service.achievements.isEmpty)
        gate.resolve([.init(identifier: "old", percentComplete: 100)])
        await #expect(throws: GameCenterServiceError.cancelled) { try await old.value }
        #expect(service.achievements.isEmpty)
    }

    @Test func previewLeaderboardsKeepOnlyBestScoreAndRoundTripContext() async throws {
        let service = GameCenterLeaderboards(mode: .preview(player: player))
        #expect(try await service.entries(for: "missing").totalPlayerCount == 0)
        try await service.submit(score: -10, to: "scores", context: .max)
        try await service.submit(score: -20, to: "scores")
        try await service.submit(score: -10, to: "scores", context: 1)
        let page = try await service.entries(for: "scores")
        #expect(page.entries.count == 1)
        #expect(page.entries.first?.score == -10)
        #expect(page.entries.first?.context == .max)
        #expect(page.entries.first?.rank == 1)
        #expect(page.entries.first?.player == player)
        #expect(page.entries.first?.formattedScore == "-10")
        #expect(page.entries.first?.date == nil)
        #expect(page.localPlayerEntry == page.entries.first)
        #expect(page.totalPlayerCount == 1)
        let later = try await service.entries(for: "scores", range: 2...25)
        #expect(later.entries.isEmpty && later.localPlayerEntry?.score == -10)
        try await service.submit(score: 20, to: "scores", context: 42)
        #expect(service.lastResults == nil)
        #expect(try await service.entries(for: "scores").entries.first?.score == 20)
        service.reset()
        #expect(service.lastResults == nil)
        #expect(try await service.entries(for: "scores").entries.isEmpty)
    }

    @Test func previewLeaderboardInstancesAreIsolated() async throws {
        let first = GameCenterLeaderboards(mode: .preview(player: player))
        let second = GameCenterLeaderboards(mode: .preview(player: player))
        try await first.submit(score: 123, to: "scores")
        #expect(try await second.entries(for: "scores").entries.isEmpty)
    }

    @Test func leaderboardRangesAreBoundedAndConvertedWithoutOffByOne() async throws {
        var ranges: [NSRange] = []
        let service = leaderboards(entries: { id, range, _ in
            ranges.append(range)
            return .init(identifier: id, entries: [], totalPlayerCount: 0)
        })
        _ = try await service.entries(for: "scores")
        _ = try await service.entries(for: "scores", range: 1...100)
        _ = try await service.entries(for: "scores", range: 25..<30)
        _ = try await service.entries(for: "scores", range: (Int.max - 1)..<Int.max)
        #expect(ranges == [NSRange(location: 1, length: 25), NSRange(location: 1, length: 100),
                           NSRange(location: 25, length: 5), NSRange(location: Int.max - 1, length: 1)])
        for range in [0...1, -1...10, 1...101, 1...Int.max, Int.max...Int.max] {
            await #expect(throws: GameCenterServiceError.invalidValue) { try await service.entries(for: "scores", range: range) }
        }
        await #expect(throws: GameCenterServiceError.invalidValue) { try await service.entries(for: "scores", range: 1..<1) }
        #expect(ranges.count == 4)
    }

    @Test func nativeSeamPreservesTitleFormattedScorePlayerAndFullContext() async throws {
        let entry = entry(rank: 2, score: 50, context: .max)
        let service = leaderboards(entries: { id, _, _ in
            .init(identifier: id, title: "High Scores", entries: [entry], localPlayerEntry: entry, totalPlayerCount: 8)
        })
        let page = try await service.entries(for: "scores")
        #expect(page.title == "High Scores")
        #expect(page.entries == [entry])
        #expect(page.totalPlayerCount == 8)
        #expect(service.lastResults == page)
    }

    @Test func malformedLeaderboardResponsesNeverPublish() async throws {
        let good = entry(rank: 1)
        let badPages: [GameCenterLeaderboardResults] = [
            .init(identifier: "wrong", entries: [], totalPlayerCount: 0),
            .init(identifier: "scores", entries: [], totalPlayerCount: -1),
            .init(identifier: "scores", entries: [good, good], totalPlayerCount: 2),
            .init(identifier: "scores", entries: [entry(rank: 26)], totalPlayerCount: 26),
            .init(identifier: "scores", entries: [entry(rank: 0)], totalPlayerCount: 1),
            .init(identifier: "scores", entries: [entry(rank: 2)], totalPlayerCount: 1),
            .init(identifier: "scores", entries: [entry(rank: 1, playerID: "")], totalPlayerCount: 1),
            .init(identifier: "scores", entries: [entry(rank: 1, date: Date(timeIntervalSinceReferenceDate: .nan))], totalPlayerCount: 1),
            .init(identifier: "scores", entries: [], localPlayerEntry: entry(rank: 1, playerID: "someone-else"), totalPlayerCount: 1),
        ]
        for page in badPages {
            let service = leaderboards(entries: { _, _, _ in page })
            await #expect(throws: GameCenterServiceError.invalidData) { try await service.entries(for: "scores") }
            #expect(service.lastResults == nil)
            #expect(!service.isLoading)
        }
    }

    @Test func leaderboardFailuresAndInvalidIdentifiersDoNotRetry() async throws {
        var calls = 0
        let service = leaderboards(submit: { _, _, _, _ in calls += 1; throw GameCenterServiceError.gameCenter("offline") },
            entries: { _, _, _ in calls += 1; throw GameCenterServiceError.notFound })
        await #expect(throws: GameCenterServiceError.invalidIdentifier) { try await service.submit(score: 1, to: "") }
        await #expect(throws: GameCenterServiceError.invalidIdentifier) { try await service.entries(for: "\n") }
        #expect(calls == 0)
        await #expect(throws: GameCenterServiceError.gameCenter("offline")) { try await service.submit(score: 1, to: "scores") }
        await #expect(throws: GameCenterServiceError.notFound) { try await service.entries(for: "missing") }
        #expect(calls == 2)
        #expect(!service.isLoading)
        #expect(service.lastResults == nil)
    }

    @Test func leaderboardSubmissionPassesFullWidthContext() async throws {
        var submitted: UInt64?
        let service = leaderboards(submit: { score, id, context, peer in
            #expect(score == Int.min && id == "scores" && peer == player)
            submitted = context
        })
        try await service.submit(score: .min, to: "scores", context: .max)
        #expect(submitted == .max)
    }

    @Test func leaderboardCancellationReleasesBusyStateBeforeCallback() async throws {
        let gate = ProgressGate<GameCenterLeaderboardResults>()
        var calls = 0
        let service = leaderboards(entries: { id, _, _ in
            calls += 1
            if calls == 1 { return try await gate.value() }
            return .init(identifier: id, entries: [], totalPlayerCount: 0)
        })
        let old = Task { try await service.entries(for: "old") }
        await gate.waitUntilStarted()
        await #expect(throws: GameCenterServiceError.operationInProgress) { try await service.submit(score: 1, to: "busy") }
        old.cancel()
        await #expect(throws: GameCenterServiceError.cancelled) { try await old.value }
        #expect(!service.isLoading)
        let current = try await service.entries(for: "current")
        gate.resolve(.init(identifier: "old", entries: [], totalPlayerCount: 0))
        await Task.yield()
        #expect(service.lastResults == current)
    }

    @Test func leaderboardResetAndContextInvalidationDiscardOldResults() async throws {
        for invalidate in [false, true] {
            let context = GameCenterServiceContext(mode: .preview(player: player))
            let gate = ProgressGate<GameCenterLeaderboardResults>()
            let service = GameCenterLeaderboards(context: context, backend: .init(submit: { _, _, _, _ in },
                entries: { _, _, _ in try await gate.value() }))
            let old = Task { try await service.entries(for: "old") }
            await gate.waitUntilStarted()
            if invalidate { context.invalidate() } else { service.reset() }
            #expect(service.lastResults == nil)
            gate.resolve(.init(identifier: "old", entries: [], totalPlayerCount: 0))
            await #expect(throws: GameCenterServiceError.cancelled) { try await old.value }
            #expect(!service.isLoading)
            #expect(service.lastResults == nil)
        }
    }

    private func achievements(
        load: @escaping @MainActor (NetworkPeer) async throws -> [GameCenterAchievement] = { _ in [] },
        report: @escaping @MainActor (String, Double, Bool, NetworkPeer) async throws -> Void = { _, _, _, _ in }
    ) -> GameCenterAchievements {
        .init(context: .init(mode: .preview(player: player)), backend: .init(load: load, report: report))
    }

    private func leaderboards(
        submit: @escaping @MainActor (Int, String, UInt64, NetworkPeer) async throws -> Void = { _, _, _, _ in },
        entries: @escaping @MainActor (String, NSRange, NetworkPeer) async throws -> GameCenterLeaderboardResults = { id, _, _ in
            .init(identifier: id, entries: [], totalPlayerCount: 0)
        }
    ) -> GameCenterLeaderboards {
        .init(context: .init(mode: .preview(player: player)), backend: .init(submit: submit, entries: entries))
    }

    private func entry(rank: Int, score: Int = 50, context: UInt64 = 0,
                       playerID: String = "fixture-player", date: Date? = nil) -> GameCenterLeaderboardEntry {
        .init(rank: rank, score: score, formattedScore: "50 points",
              player: .init(id: .init(rawValue: playerID), displayName: "Fixture player"), context: context, date: date)
    }
}

/// Deliberately ignores cancellation to model a late GameKit callback. Tests
/// explicitly resolve every gate; no network or system account is involved.
@MainActor
private final class ProgressGate<Value: Sendable> {
    private var pending: CheckedContinuation<Value, any Error>?
    private var started: CheckedContinuation<Void, Never>?

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func resolve(_ value: Value) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: value)
    }
}
