import ECSCore
import Foundation
@testable import GameUI
import Testing

@MainActor @Suite struct GameCenterTurnBasedTests {
    private let alice = NetworkPeer(id: .init(rawValue: "alice"), displayName: "Alice")
    private let bob = NetworkPeer(id: .init(rawValue: "bob"), displayName: "Bob")
    private struct State: Codable, Equatable { var moves: Int }

    @Test func sharedPreviewSavesPassesReloadsAndFinishes() async throws {
        let store = InMemoryTurnBasedStore()
        let id = try store.createMatch(participants: [alice, bob])
        let a = GameCenterTurnBasedMatches(mode: .preview(player: alice), previewStore: store)
        let b = GameCenterTurnBasedMatches(mode: .preview(player: bob), previewStore: store)
        let initialA = try await a.load(id: id), initialB = try await b.load(id: id)
        #expect(initialA.localCanAct)
        #expect(!initialB.localCanAct)
        #expect(initialA.currentPlayer == alice)
        #expect(initialA.revision == initialB.revision)
        #expect(throws: GameCenterServiceError.invalidData) { try a.state(of: initialA, as: State.self) }
        await #expect(throws: GameCenterServiceError.notYourTurn) { try await b.save(State(moves: 10), in: initialB) }
        let saved = try await a.save(State(moves: 1), in: initialA)
        #expect(saved.localCanAct)
        #expect(saved.revision != initialA.revision)
        #expect(try a.state(of: saved, as: State.self) == State(moves: 1))
        await #expect(throws: GameCenterServiceError.staleMatch) { try await a.save(State(moves: 2), in: initialA) }
        let passed = try await a.endTurn(State(moves: 2), in: saved, nextParticipantSlots: [1])
        #expect(passed.currentTurnSlot == 1)
        #expect(!passed.localCanAct)
        // Preview has no implicit subscriptions; the other service must reload.
        #expect(b.selectedMatch?.revision == initialB.revision)
        let theirTurn = try await b.load(id: id)
        #expect(theirTurn.localCanAct)
        #expect(try b.state(of: theirTurn, as: State.self).moves == 2)
        let finished = try await b.finish(State(moves: 3), in: theirTurn, outcomes: [0: .lost, 1: .won])
        #expect(finished.status == .ended)
        #expect(!finished.localCanAct)
        #expect(finished.currentTurnSlot == nil)
        #expect(finished.participants.map(\.outcome) == [.lost, .won])
        await #expect(throws: GameCenterServiceError.matchEnded) { try await b.save(State(moves: 4), in: finished) }
        let inbox = try await a.list()
        #expect(inbox.count == 1)
        #expect(inbox[0].revision == finished.revision)
        #expect(inbox[0].status == .ended)
    }

    @Test func slotsValidationAndPendingPlayers() async throws {
        let store = InMemoryTurnBasedStore()
        let id = try store.createMatch(participants: [alice, nil, bob])
        let service = GameCenterTurnBasedMatches(mode: .preview(player: alice), previewStore: store)
        let match = try await service.load(id: id)
        #expect(match.participants.map(\.slot) == [0, 1, 2])
        #expect(match.participants[1].player == nil)
        #expect(match.participants[1].status == .matching)
        for slots in [[], [0], [1, 1], [-1], [3]] {
            await #expect(throws: GameCenterServiceError.invalidValue) {
                try await service.endTurn(State(moves: 1), in: match, nextParticipantSlots: slots)
            }
        }
        for outcomes: [Int: GameCenterTurnBasedOutcome] in [[0: .won], [0: .won, 1: .none, 2: .lost], [0: .won, 1: .lost, 2: .unknown]] {
            await #expect(throws: GameCenterServiceError.invalidValue) {
                try await service.finish(State(moves: 1), in: match, outcomes: outcomes)
            }
        }
        let pending = try await service.endTurn(State(moves: 1), in: match, nextParticipantSlots: [1, 2])
        #expect(pending.currentTurnSlot == 1)
        #expect(pending.currentPlayer == nil)
        #expect(!pending.localCanAct)
    }

    @Test func forfeitInAndOutOfTurnPreservesPayloadAndTerminalOutcome() async throws {
        let store = InMemoryTurnBasedStore()
        let id = try store.createMatch(participants: [alice, bob])
        let a = GameCenterTurnBasedMatches(mode: .preview(player: alice), previewStore: store)
        let b = GameCenterTurnBasedMatches(mode: .preview(player: bob), previewStore: store)
        let initial = try await a.load(id: id)
        let saved = try await a.save(State(moves: 7), in: initial)
        await #expect(throws: GameCenterServiceError.invalidValue) { try await a.forfeit(saved) }
        let quit = try await a.forfeit(saved, nextParticipantSlots: [1])
        #expect(quit.participants[0].outcome == .quit)
        #expect(quit.data == saved.data)
        #expect(quit.currentTurnSlot == 1)
        let bTurn = try await b.load(id: id)
        await #expect(throws: GameCenterServiceError.invalidValue) {
            try await b.endTurn(State(moves: 8), in: bTurn, nextParticipantSlots: [0])
        }
        await #expect(throws: GameCenterServiceError.invalidValue) {
            try await b.finish(State(moves: 8), in: bTurn, outcomes: [0: .lost, 1: .won])
        }
        let finished = try await b.finish(State(moves: 8), in: bTurn, outcomes: [0: .quit, 1: .won])
        #expect(finished.participants[0].outcome == .quit)
        let secondID = try store.createMatch(participants: [alice, bob])
        let secondB = try await b.load(id: secondID)
        let outOfTurnQuit = try await b.forfeit(secondB)
        #expect(outOfTurnQuit.currentTurnSlot == 0)
        #expect(outOfTurnQuit.participants[1].status == .done)
        await #expect(throws: GameCenterServiceError.notYourTurn) { try await b.forfeit(outOfTurnQuit) }
    }

    @Test func versionsForeignDataAndCapsAreCheckedOnEncodedEnvelope() async throws {
        let store = InMemoryTurnBasedStore(maximumDataSize: 1024)
        let service = GameCenterTurnBasedMatches(mode: .preview(player: alice), previewStore: store)
        let id = try store.createMatch(participants: [alice, bob], data: Data("foreign".utf8))
        let foreign = try await service.load(id: id)
        #expect(throws: GameCenterServiceError.invalidData) { try service.state(of: foreign, as: State.self) }
        let saved = try await service.save(State(moves: 4), in: foreign, version: 2)
        #expect(throws: GameCenterServiceError.invalidData) { try service.state(of: saved, as: State.self) }
        #expect(throws: GameCenterServiceError.invalidData) { try service.state(of: saved, as: String.self, version: 2) }
        #expect(try service.state(of: saved, as: State.self, version: 2).moves == 4)
        await #expect(throws: GameCenterServiceError.invalidValue) { try await service.save(State(moves: 1), in: saved, version: 0) }
        await #expect(throws: GameCenterServiceError.capacityExceeded) { try await service.save(String(repeating: "x", count: 1024), in: saved) }
        let unchanged = try await service.load(id: id)
        #expect(unchanged.revision == saved.revision)
        let tiny = InMemoryTurnBasedStore(maximumDataSize: 1)
        let tinyID = try tiny.createMatch(participants: [alice, bob])
        let tinyService = GameCenterTurnBasedMatches(mode: .preview(player: alice), previewStore: tiny)
        let tinyMatch = try await tinyService.load(id: tinyID)
        await #expect(throws: GameCenterServiceError.capacityExceeded) { try await tinyService.save(0, in: tinyMatch) }
    }

    @Test func previewStoresAreExplicitAndPlayerScoped() async throws {
        let store = InMemoryTurnBasedStore()
        let id = try store.createMatch(participants: [alice, bob])
        let independent = GameCenterTurnBasedMatches(mode: .preview(player: alice))
        #expect(try await independent.list().isEmpty)
        await #expect(throws: GameCenterServiceError.notFound) { try await independent.load(id: id) }
        let outsider = NetworkPeer(id: .init(rawValue: "outsider"), displayName: "Outsider")
        let stranger = GameCenterTurnBasedMatches(mode: .preview(player: outsider), previewStore: store)
        #expect(try await stranger.list().isEmpty)
        await #expect(throws: GameCenterServiceError.notFound) { try await stranger.load(id: id) }
        await #expect(throws: GameCenterServiceError.invalidIdentifier) { try await stranger.load(id: "\n") }
        #expect(throws: GameCenterServiceError.invalidValue) { try store.createMatch(participants: [alice, alice]) }
    }

    @Test func previewMatchmakingUsesTurnBasedPlayerLimitAndDoesNotAuthenticate() async throws {
        let service = GameCenterTurnBasedMatches(mode: .preview(player: alice))
        let match = try await service.findMatch(.init(minPlayers: 2, maxPlayers: 16))
        #expect(match.participants.count == 16)
        #expect(match.localCanAct)
        #expect(match.participants.dropFirst().allSatisfy { $0.player == nil })
        await #expect(throws: (any Error).self) { try await service.findMatch(.init(maxPlayers: 17)) }
    }

    @Test func nativeSeamRegistersOnlyOnUseAndCleansUpOnResetAndDeinit() async throws {
        let harness = try fixture()
        var service: GameCenterTurnBasedMatches? = .init(context: harness.context, driver: harness.driver)
        #expect(harness.starts == 0)
        try service?.start(); try service?.start()
        #expect(harness.starts == 1)
        _ = try await service?.load(id: harness.id)
        #expect(harness.starts == 1)
        let late = try #require(harness.receivers.values.first)
        service?.reset()
        #expect(harness.stops == 1)
        late(harness.id, false)
        #expect(service?.matches.isEmpty == true)
        try service?.start()
        #expect(harness.starts == 2)
        weak let weakService = service
        service = nil
        #expect(weakService == nil)
        #expect(harness.stops == 2)
    }

    @Test func nativeSeamReloadsBeforeWritesRejectsStaleAndUsesLoadedCap() async throws {
        let harness = try fixture()
        let service = GameCenterTurnBasedMatches(context: harness.context, driver: harness.driver)
        let match = try await service.load(id: harness.id)
        let saved = try await service.save(State(moves: 1), in: match)
        #expect(harness.loads == 3) // initial, preflight, post-write refresh
        #expect(harness.writes == 1)
        await #expect(throws: GameCenterServiceError.staleMatch) { try await service.save(State(moves: 2), in: match) }
        #expect(harness.writes == 1)
        await #expect(throws: GameCenterServiceError.capacityExceeded) {
            try await service.save(String(repeating: "x", count: 70_000), in: saved)
        }
        #expect(harness.writes == 1)
    }

    @Test func nativeSeamSerializesAndInvalidatesSuspendedPreflight() async throws {
        let harness = try fixture()
        let service = GameCenterTurnBasedMatches(context: harness.context, driver: harness.driver)
        let match = try await service.load(id: harness.id)
        harness.pauseNextLoad = true
        let task = Task { try await service.save(State(moves: 1), in: match) }
        await harness.waitUntilPaused()
        try #require(harness.paused != nil)
        await #expect(throws: GameCenterServiceError.operationInProgress) { try await service.save(State(moves: 2), in: match) }
        harness.context.invalidate()
        service.reset()
        harness.resume()
        await #expect(throws: GameCenterServiceError.cancelled) { try await task.value }
        #expect(harness.writes == 0)
        #expect(service.matches.isEmpty)
        #expect(!service.isLoading)
    }

    @Test func cancelledNativeCallCannotPublishLateCallbackOrSubmitWrite() async throws {
        let harness = try fixture()
        let service = GameCenterTurnBasedMatches(context: harness.context, driver: harness.driver)
        let match = try await service.load(id: harness.id)
        harness.pauseNextLoad = true
        let task = Task { try await service.save(State(moves: 1), in: match) }
        await harness.waitUntilPaused()
        try #require(harness.paused != nil)
        task.cancel()
        harness.resume()
        await #expect(throws: GameCenterServiceError.cancelled) { try await task.value }
        #expect(harness.writes == 0)
        #expect(service.selectedMatch == nil)
    }

    @Test func submittedWriteRemainsSerializedUntilCancelledCallbackReturns() async throws {
        let harness = try fixture()
        let service = GameCenterTurnBasedMatches(context: harness.context, driver: harness.driver)
        let match = try await service.load(id: harness.id)
        harness.pauseNextWrite = true
        let task = Task { try await service.save(State(moves: 1), in: match) }
        await harness.waitUntilPaused()
        try #require(harness.paused != nil)
        #expect(harness.writes == 1)
        task.cancel()
        service.reset()
        await #expect(throws: GameCenterServiceError.operationInProgress) { try await service.load(id: harness.id) }
        harness.resume()
        await #expect(throws: GameCenterServiceError.cancelled) { try await task.value }
        #expect(service.matches.isEmpty)
        #expect(!service.isLoading)
        // Submission already committed remotely; cancellation only discards the
        // callback. Explicit reload discovers what Apple may have persisted.
        let reloaded = try await service.load(id: harness.id)
        #expect(try service.state(of: reloaded, as: State.self).moves == 1)
    }

    @Test func eventReloadsNativeDataAndLateEventsAfterResetAreIgnored() async throws {
        let harness = try fixture()
        let service = GameCenterTurnBasedMatches(context: harness.context, driver: harness.driver)
        let match = try await service.load(id: harness.id)
        _ = try harness.store.update(match, player: alice.id, change: .endTurn(Data(), [1]))
        let receive = try #require(harness.receivers.values.first)
        receive(harness.id, false)
        for _ in 0..<100 where service.selectedMatch?.currentTurnSlot != 1 { await Task.yield() }
        #expect(service.selectedMatch?.currentTurnSlot == 1)
        #expect(service.selectedMatch?.localCanAct == false)
        service.reset()
        let loads = harness.loads
        receive(harness.id, false)
        for _ in 0..<5 { await Task.yield() }
        #expect(harness.loads == loads)
        #expect(service.matches.isEmpty)
    }

    @Test func callbackSeamCompletesOnlyOnce() async throws {
        let result: Int = try await withCheckedThrowingContinuation { continuation in
            let callback = GameCenterTurnBasedCallback(continuation)
            callback.resolve(.success(7))
            callback.resolve(.success(8))
            callback.resolve(.failure(.cancelled))
        }
        #expect(result == 7)
    }

    @Test func activationSelectsItsMatchButBackgroundRefreshDoesNotStealSelection() async throws {
        let harness = try fixture()
        let service = GameCenterTurnBasedMatches(context: harness.context, driver: harness.driver)
        _ = try await service.load(id: harness.id)
        let second = try harness.store.createMatch(participants: [alice, bob])
        let receive = try #require(harness.receivers.values.first)
        receive(second, false)
        for _ in 0..<100 where !service.matches.contains(where: { $0.id == second }) { await Task.yield() }
        #expect(service.matches.contains { $0.id == second })
        #expect(service.selectedMatch?.id == harness.id)
        receive(second, true)
        receive(second, false) // Coalescing must retain the activation intent.
        for _ in 0..<100 where service.selectedMatch?.id != second { await Task.yield() }
        #expect(service.selectedMatch?.id == second)
        let loads = harness.loads
        receive(harness.id, false)
        for _ in 0..<100 where harness.loads == loads || service.isLoading { await Task.yield() }
        #expect(harness.loads > loads)
        #expect(service.selectedMatch?.id == second)
    }

    @Test func coalescingKeepsTheMostRecentActivationLast() async throws {
        let harness = try fixture()
        let service = GameCenterTurnBasedMatches(context: harness.context, driver: harness.driver)
        _ = try await service.load(id: harness.id)
        let second = try harness.store.createMatch(participants: [alice, bob])
        let receive = try #require(harness.receivers.values.first)
        let loads = harness.loads
        receive(harness.id, false)
        receive(second, true)
        receive(harness.id, true)
        for _ in 0..<100 where harness.loads < loads + 2 || service.isLoading { await Task.yield() }
        #expect(harness.loads >= loads + 2)
        #expect(service.selectedMatch?.id == harness.id)
    }

    private func fixture() throws -> TurnBasedTestDriver {
        try TurnBasedTestDriver(player: alice, other: bob)
    }
}

@MainActor
private final class TurnBasedTestDriver {
    let store = InMemoryTurnBasedStore()
    let player: NetworkPeer
    let context: GameCenterServiceContext
    let id: String
    var starts = 0, stops = 0, loads = 0, writes = 0
    var receivers: [UUID: @MainActor @Sendable (String, Bool) -> Void] = [:]
    var pauseNextLoad = false
    var pauseNextWrite = false
    var paused: CheckedContinuation<Void, Never>?

    init(player: NetworkPeer, other: NetworkPeer) throws {
        self.player = player
        context = .init(mode: .preview(player: player))
        id = try store.createMatch(participants: [player, other])
    }

    var driver: GameCenterTurnBasedDriver {
        .init(list: { [self] check in
            try check(); return store.list(player: player.id).map { .init(snapshot: $0) }
        }, load: { [self] id, check in
            try check(); loads += 1
            if pauseNextLoad {
                pauseNextLoad = false
                await withCheckedContinuation { paused = $0 }
            }
            try check()
            return .init(snapshot: try store.load(id: id, player: player.id))
        }, find: { [self] _, check in
            try check(); return .init(snapshot: try store.load(id: id, player: player.id))
        }, write: { [self] loaded, change, check in
            try check(); writes += 1
            _ = try store.update(loaded.snapshot, player: player.id, change: change)
            if pauseNextWrite {
                pauseNextWrite = false
                await withCheckedContinuation { paused = $0 }
            }
            try check()
        }, start: { [self] lease, receive in
            starts += 1; receivers[lease] = receive
        }, stop: { [self] lease in
            stops += 1; receivers[lease] = nil
        })
    }

    func waitUntilPaused() async {
        for _ in 0..<100 where paused == nil { await Task.yield() }
    }
    func resume() { let continuation = paused; paused = nil; continuation?.resume() }
}
