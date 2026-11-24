import Foundation
import ECSCore
import Testing

private typealias ActionHost = NetworkInteractionAuthority<Int, Int, Int>
private typealias ActionClient = NetworkInteractionClient<Int, Int, Int>
private let actionOwner = NetworkPeerID(rawValue: "owner")
private func actionStream() -> NetworkPredictionStream { .init(entity: .init(), owner: actionOwner) }
private func accepted(_ result: NetworkInteractionResult<Int>) -> Int? { if case .accepted(let value) = result.resolution { value } else { nil } }
private func rejected(_ result: NetworkInteractionResult<Int>) -> NetworkInteractionRejection? { if case .rejected(let reason) = result.resolution { reason } else { nil } }

@Suite struct NetworkInteractionTests {
    @Test func queryUsesTheIssuedSnapshotInsteadOfCurrentOrClientState() throws {
        var host = ActionHost(stream: actionStream()); try host.record(10, at: 0)
        let view = try host.issueView(); var client = ActionClient(view: view)
        let command = try client.predict(2); try host.record(80, at: 0.1)
        let decision = try host.resolve(command, from: actionOwner, at: 0.2) { $0 + $1 }
        #expect(decision.isNew && accepted(decision.result) == 12)
        #expect(try client.receive(decision.result)); #expect(client.pendingActionCount == 0)
    }
    @Test func forgedFutureUnissuedAndExpiredViewsCannotEvaluate() throws {
        var host = ActionHost(stream: actionStream()); try host.record(10, at: 0)
        let view = try host.issueView(); var calls = 0
        let forged = NetworkInteractionViewReference(stream: host.stream, tick: view.reference.tick + 1)
        let first = try host.resolve(.init(view: forged, sequence: 1, intent: 1), from: actionOwner, at: 0.1) { _, _ in calls += 1; return 9 }
        let old = try host.resolve(.init(view: view.reference, sequence: 2, intent: 1), from: actionOwner, at: 0.6) { _, _ in calls += 1; return 9 }
        #expect(rejected(first.result) == .unissuedView && rejected(old.result) == .expiredView && calls == 0)
    }
    @Test func cooldownUsesReceiptTimeAndMissesAlsoConsumeIt() throws {
        var host = ActionHost(stream: actionStream(), configuration: .init(cooldown: 0.2)); try host.record(0, at: 0)
        let view = try host.issueView()
        let a = try host.resolve(.init(view: view.reference, sequence: 1, intent: 0), from: actionOwner, at: 0) { _, _ in 0 }
        let b = try host.resolve(.init(view: view.reference, sequence: 2, intent: 0), from: actionOwner, at: 0.01) { _, _ in 1 }
        let c = try host.resolve(.init(view: view.reference, sequence: 3, intent: 0), from: actionOwner, at: 0.2) { _, _ in 2 }
        #expect(accepted(a.result) == 0 && rejected(b.result) == .cooldown && accepted(c.result) == 2)
    }
    @Test func duplicatesReturnTheOriginalReceiptAndNeverRunEffectsAgain() throws {
        var host = ActionHost(stream: actionStream()); try host.record(3, at: 0); let view = try host.issueView()
        var calls = 0
        let first = try host.resolve(.init(view: view.reference, sequence: 1, intent: 1), from: actionOwner, at: 0) { state, intent in calls += 1; return state + intent }
        let duplicate = try host.resolve(.init(view: view.reference, sequence: 1, intent: 99), from: actionOwner, at: 0.4) { _, _ in calls += 1; return 0 }
        #expect(first.isNew && !duplicate.isNew && accepted(duplicate.result) == 4 && calls == 1)
    }
    @Test func evictedResultsNeverAuthorizeAnOldIndexAgain() throws {
        var host = ActionHost(stream: actionStream(), configuration: .init(cooldown: 0, capacity: 2)); try host.record(0, at: 0)
        let view = try host.issueView()
        for sequence in UInt64(1)...3 { _ = try host.resolve(.init(view: view.reference, sequence: sequence, intent: 1), from: actionOwner, at: 0.1) { $0 + $1 } }
        let old = try host.resolve(.init(view: view.reference, sequence: 1, intent: 10), from: actionOwner, at: 0.1) { _, _ in Issue.record("Old action evaluated"); return 99 }
        #expect(host.resultCount == 2 && !old.isNew && rejected(old.result) == .staleSequence)
    }
    @Test func wrongOwnerEpochSequenceAndBackwardsTimeDoNotConsumeAnAction() throws {
        var host = ActionHost(stream: actionStream()); try host.record(0, at: 1); let view = try host.issueView()
        let command = NetworkInteractionCommand(view: view.reference, sequence: 1, intent: 1)
        #expect(throws: NetworkInteractionError.wrongOwner) { try host.resolve(command, from: .init(rawValue: "other"), at: 1) { $0 + $1 } }
        #expect(throws: NetworkInteractionError.wrongStream) { try host.resolve(.init(view: .init(stream: actionStream(), tick: 1), sequence: 1, intent: 1), from: actionOwner, at: 1) { $0 + $1 } }
        for sequence in [UInt64(0), 999] { #expect(throws: NetworkInteractionError.invalidSequence) { try host.resolve(.init(view: view.reference, sequence: sequence, intent: 0), from: actionOwner, at: 1) { $0 + $1 } } }
        #expect(throws: NetworkInteractionError.invalidTime) { try host.resolve(command, from: actionOwner, at: 0.9) { $0 + $1 } }
        #expect(host.resultCount == 0)
        #expect(try host.resolve(command, from: actionOwner, at: 1) { $0 + $1 }.isNew)
    }
    @Test func historyAndIssuedViewsStayBoundedAndRejectInvalidRecordingAtomically() throws {
        var host = ActionHost(stream: actionStream(), configuration: .init(maximumRewind: 0.5, capacity: 4))
        for index in 0..<30 { try host.record(index, at: Double(index) / 60); _ = try host.issueView() }
        #expect(host.historyCount == 4 && host.issuedViewCount <= 4)
        #expect(throws: NetworkInteractionError.invalidTime) { try host.record(100, at: .nan) }
        #expect(throws: NetworkInteractionRejection.invalidIntent) { try host.record(100, at: 1) { _ in throw NetworkInteractionRejection.invalidIntent } }
        #expect(try host.issueView().state == 29)
    }
    @Test func applicationRejectionsAreFinalAndDoNotGrantAnOutcome() throws {
        var host = ActionHost(stream: actionStream()); try host.record(0, at: 0); let view = try host.issueView()
        let command = NetworkInteractionCommand(view: view.reference, sequence: 1, intent: 0)
        let result = try host.resolve(command, from: actionOwner, at: 0) { _, _ in throw NetworkInteractionRejection.targetUnavailable }
        #expect(result.isNew && rejected(result.result) == .targetUnavailable)
        #expect(try host.resolve(command, from: actionOwner, at: 0.3) { _, _ in 5 }.isNew == false)
    }
    @Test func clientFeedbackCompletesOnceEvenWhenResultsAreReordered() throws {
        let stream = actionStream(), view = NetworkInteractionView(reference: .init(stream: actionStream(), tick: 1), state: 0)
        var client = ActionClient(view: view)
        _ = try client.predict(0); _ = try client.predict(0)
        let second = NetworkInteractionResult<Int>(stream: view.reference.stream, sequence: 2, resolution: .accepted(1))
        #expect(try client.receive(second)); #expect(try !client.receive(second)); #expect(client.pendingActionCount == 1)
        #expect(throws: NetworkInteractionError.wrongStream) { try client.receive(.init(stream: stream, sequence: 1, resolution: .accepted(9))) }
        #expect(throws: NetworkInteractionError.invalidResult) { try client.receive(.init(stream: view.reference.stream, sequence: 3, resolution: .accepted(9))) }
        #expect(try client.receive(.init(stream: view.reference.stream, sequence: 1, resolution: .rejected(.cooldown))))
    }
    @Test func pendingFeedbackHasAHardLimitAndViewsCannotChangeEpochOrGoBackwards() throws {
        let stream = actionStream(); var client = ActionClient(view: .init(reference: .init(stream: stream, tick: 2), state: 0), configuration: .init(maximumPendingActions: 1))
        _ = try client.predict(0)
        #expect(throws: NetworkInteractionError.capacityExceeded) { try client.predict(0) }
        #expect(try !client.receive(.init(reference: .init(stream: stream, tick: 1), state: 9)))
        #expect(throws: NetworkInteractionError.wrongStream) { try client.receive(.init(reference: .init(stream: actionStream(), tick: 3), state: 9)) }
        #expect(client.view.state == 0 && client.pendingActionCount == 1)
    }
    @Test func commandViewAndResultRoundTripAsPortableValues() throws {
        var host = ActionHost(stream: actionStream()); try host.record(5, at: 0); let view = try host.issueView()
        let command = NetworkInteractionCommand(view: view.reference, sequence: 1, intent: 2)
        let decoded = try JSONDecoder().decode(NetworkInteractionCommand<Int>.self, from: JSONEncoder().encode(command))
        let decision = try host.resolve(decoded, from: actionOwner, at: 0) { $0 + $1 }
        let result = try JSONDecoder().decode(NetworkInteractionResult<Int>.self, from: JSONEncoder().encode(decision.result))
        #expect(accepted(result) == 7)
        let copy = try JSONDecoder().decode(NetworkInteractionView<Int>.self, from: JSONEncoder().encode(view))
        #expect(copy.state == 5 && copy.reference == view.reference)
    }
}
