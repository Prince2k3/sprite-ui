import Foundation
@testable import ECSCore
import Testing

private struct PredictionNumber: Codable, Sendable, Equatable { var value: Double }
private let predictionOwner = NetworkPeerID(rawValue: "client")
private func predictionStream() -> NetworkPredictionStream { .init(entity: .init(), owner: predictionOwner) }
private func numberAuthority(_ stream: NetworkPredictionStream, capacity: Int = 8) throws -> NetworkInputAuthority<PredictionNumber, Double> {
    try .init(stream: stream, state: .init(value: 0), idleInput: 0, configuration: .init(stepDuration: 0.1, maximumPendingInputs: capacity),
        validateInput: { guard $0.isFinite, abs($0) <= 1 else { throw NetworkPredictionError.invalidSequence } },
        validateState: { guard $0.value.isFinite, abs($0.value) <= 100 else { throw NetworkPredictionError.invalidAcknowledgment } },
        step: { .init(value: $0.value + $1 * $2) })
}
private func numberPrediction(_ state: NetworkAuthoritativeState<PredictionNumber>, capacity: Int = 8) throws -> NetworkPrediction<PredictionNumber, Double> {
    try .init(authoritative: state, configuration: .init(stepDuration: 0.1, maximumPendingInputs: capacity),
        validateInput: { guard $0.isFinite, abs($0) <= 1 else { throw NetworkPredictionError.invalidSequence } },
        validateState: { guard $0.value.isFinite, abs($0.value) <= 100 else { throw NetworkPredictionError.invalidAcknowledgment } },
        step: { .init(value: $0.value + $1 * $2) })
}
@Suite struct NetworkPredictionTests {
    @Test func localPredictionIsImmediateAndReconciliationReplaysOnlyUnacknowledgedInputs() throws {
        var host = try numberAuthority(predictionStream()), client = try numberPrediction(host.snapshot)
        let first = try client.predict(1); _ = try client.predict(1); _ = try client.predict(-1)
        #expect(abs(client.state.value - 0.1) < 1e-9 && client.pendingInputs.count == 3)
        try host.receive(first, from: predictionOwner); let response = try host.advance()
        try host.correct(to: .init(value: -1))
        let result = try client.reconcile(host.snapshot)
        #expect(result.wasApplied && result.acknowledgedInputs == 1 && result.replayedInputs == 2)
        #expect(client.state.value == -1 && client.pendingInputs.map(\.sequence) == [2, 3])
        #expect(response.acknowledgedInput == 1)
    }
    @Test func burstAdmissionCannotAdvanceTheHostAndOnlyOneInputRunsPerTick() throws {
        var host = try numberAuthority(predictionStream()), client = try numberPrediction(host.snapshot)
        for _ in 0..<8 { try host.receive(client.predict(1), from: predictionOwner) }
        #expect(host.state.value == 0 && host.acknowledgedInput == 0 && host.queuedInputCount == 8)
        _ = try host.advance()
        #expect(host.state.value == 0.1 && host.acknowledgedInput == 1 && host.queuedInputCount == 7)
    }
    @Test func missingCommandsUseNeutralInputWithoutSkippingTheGap() throws {
        var host = try numberAuthority(predictionStream()), client = try numberPrediction(host.snapshot)
        let first = try client.predict(1), second = try client.predict(1)
        try host.receive(second, from: predictionOwner); _ = try host.advance()
        #expect(host.acknowledgedInput == 0 && host.state.value == 0)
        try host.receive(first, from: predictionOwner); _ = try host.advance(); _ = try host.advance()
        #expect(host.acknowledgedInput == 2 && host.state.value == 0.2)
    }
    @Test func duplicateInputsCannotReplaceQueuedDataOrRunTwice() throws {
        var host = try numberAuthority(predictionStream())
        let original = NetworkInputCommand(stream: host.stream, sequence: 1, input: 1.0)
        #expect(try host.receive(original, from: predictionOwner))
        #expect(try !host.receive(.init(stream: host.stream, sequence: 1, input: -1), from: predictionOwner))
        _ = try host.advance()
        #expect(try !host.receive(original, from: predictionOwner))
        _ = try host.advance(); #expect(host.state.value == 0.1 && host.acknowledgedInput == 1)
    }
    @Test func foreignOwnersEpochsAndInvalidSequencesLeaveAuthorityUntouched() throws {
        var host = try numberAuthority(predictionStream())
        #expect(throws: NetworkPredictionError.wrongOwner) { try host.receive(.init(stream: host.stream, sequence: 1, input: 1), from: .init(rawValue: "impostor")) }
        #expect(throws: NetworkPredictionError.wrongStream) { try host.receive(.init(stream: predictionStream(), sequence: 1, input: 1), from: predictionOwner) }
        #expect(throws: NetworkPredictionError.invalidSequence) { try host.receive(.init(stream: host.stream, sequence: 0, input: 1), from: predictionOwner) }
        #expect(throws: NetworkPredictionError.capacityExceeded) { try host.receive(.init(stream: host.stream, sequence: 99, input: 1), from: predictionOwner) }
        #expect(host.queuedInputCount == 0 && host.revision == 0)
    }
    @Test func staleAndDuplicateSnapshotsCannotRewindPrediction() throws {
        var host = try numberAuthority(predictionStream()), client = try numberPrediction(host.snapshot)
        let old = host.snapshot; _ = try client.predict(1); try host.correct(to: .init(value: 5))
        _ = try client.reconcile(host.snapshot)
        #expect(try !client.reconcile(old).wasApplied)
        #expect(try !client.reconcile(host.snapshot).wasApplied)
        #expect(client.state.value == 5.1 && client.pendingInputs.count == 1)
    }
    @Test func impossibleAcknowledgmentsFailAtomically() throws {
        let host = try numberAuthority(predictionStream()); var client = try numberPrediction(host.snapshot)
        _ = try client.predict(1)
        #expect(throws: NetworkPredictionError.invalidAcknowledgment) { try client.reconcile(.init(stream: host.stream, revision: 1, acknowledgedInput: 2, state: .init(value: 0))) }
        #expect(client.pendingInputs.count == 1 && client.revision == 0 && client.state.value == 0.1)
    }
    @Test func boundedHistoryRefusesFurtherPredictionWithoutDroppingInputs() throws {
        let host = try numberAuthority(predictionStream()); var client = try numberPrediction(host.snapshot, capacity: 2)
        _ = try client.predict(1); _ = try client.predict(1)
        #expect(throws: NetworkPredictionError.capacityExceeded) { try client.predict(1) }
        #expect(client.issuedInput == 2 && client.pendingInputs.count == 2 && client.state.value == 0.2)
    }
    @Test func invalidInputAndFailedReplayDoNotPartiallyCommit() throws {
        let host = try numberAuthority(predictionStream()); var client = try numberPrediction(host.snapshot)
        #expect(throws: NetworkPredictionError.invalidSequence) { try client.predict(.nan) }
        _ = try client.predict(1)
        #expect(throws: NetworkPredictionError.invalidAcknowledgment) {
            try client.reconcile(.init(stream: host.stream, revision: 1, acknowledgedInput: 0, state: .init(value: 100)))
        }
        #expect(client.revision == 0 && client.state.value == 0.1 && client.pendingInputs.count == 1)
    }
    @Test func lowerAcknowledgmentInANewerRevisionIsRejected() throws {
        var host = try numberAuthority(predictionStream()), client = try numberPrediction(host.snapshot)
        try host.receive(client.predict(1), from: predictionOwner); _ = try host.advance(); _ = try client.reconcile(host.snapshot)
        #expect(throws: NetworkPredictionError.invalidAcknowledgment) {
            try client.reconcile(.init(stream: host.stream, revision: host.revision + 1, acknowledgedInput: 0, state: host.state))
        }
    }
    @Test func commandAndStatePacketsRoundTripAndConfigurationDecodeIsBounded() throws {
        let host = try numberAuthority(predictionStream())
        let command = NetworkInputCommand(stream: host.stream, sequence: 1, input: 0.5)
        #expect(try JSONDecoder().decode(NetworkInputCommand<Double>.self, from: JSONEncoder().encode(command)).stream == host.stream)
        #expect(try JSONDecoder().decode(NetworkAuthoritativeState<PredictionNumber>.self, from: JSONEncoder().encode(host.snapshot)).state.value == 0)
        let config = try JSONDecoder().decode(NetworkPredictionConfiguration.self, from: Data("{\"stepDuration\":5,\"maximumPendingInputs\":9999}".utf8))
        #expect(config.stepDuration == 0.1 && config.maximumPendingInputs == 512)
    }
}
