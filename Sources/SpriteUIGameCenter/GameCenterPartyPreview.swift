import ECSCore
import Foundation

/// A shared, account-free fixed party fixture. Retain it while its services use the connections.
/// This is an in-process byte network, not a Game Center server or invitation simulator.
@MainActor public final class GameCenterPartyPreview {
    /// The exact initial roster, including every local preview identity.
    public let players: [NetworkPeer]
    private let network = InMemoryNetwork(maximumPeers: 8)
    private struct Entry {
        let token: UUID
        let transport: InMemoryNetworkTransport
        var completion: CheckedContinuation<GameCenterPartyMatch, any Error>?
    }
    private var entries: [NetworkPeerID: Entry] = [:]
    private var route: String?

    /// Creates a fixture for two through eight unique, valid identities.
    public init(players: [NetworkPeer]) throws {
        guard (2...8).contains(players.count), Set(players.map(\.id)).count == players.count else { throw GameCenterServiceError.invalidData }
        for player in players { try validateGameCenterIdentifier(player.id.rawValue) }
        self.players = players.sorted { $0.id < $1.id }
    }
    /// Delivers pending lobby and replication packets. Even zero-latency messages need an advance.
    public func advance(by seconds: TimeInterval = 0) { network.advance(by: seconds) }

    func match(activity: GameCenterActivity, player: NetworkPeer) async throws -> GameCenterPartyMatch {
        try Task.checkCancellation()
        guard players.contains(where: { $0.id == player.id }), let code = activity.partyCode else { throw GameCenterServiceError.invalidValue }
        guard entries[player.id] == nil else { throw GameCenterServiceError.operationInProgress }
        let key = activity.definitionID + "\n" + code
        guard route == nil || route == key else { throw GameCenterServiceError.invalidData }
        let token = UUID(), transport = try network.connect(player)
        route = key; entries[player.id] = .init(token: token, transport: transport)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                entries[player.id]?.completion = continuation
                if entries.count == players.count {
                    for peer in players {
                        guard var entry = entries[peer.id] else { continue }
                        let completion = entry.completion; entry.completion = nil; entries[peer.id] = entry
                        let match = GameCenterPartyMatch(transport: entry.transport) { [weak self] in self?.remove(peer.id, token: entry.token) }
                        completion?.resume(returning: match)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.remove(player.id, token: token) }
        }
    }
    private func remove(_ id: NetworkPeerID, token: UUID) {
        guard let entry = entries[id], entry.token == token else { return }
        entries[id] = nil; entry.transport.disconnect(); entry.completion?.resume(throwing: CancellationError())
        // A cancelled partial roster cannot silently continue as a different party.
        let waiting = entries.filter { $0.value.completion != nil }
        for (id, entry) in waiting {
            entries[id] = nil; entry.transport.disconnect(); entry.completion?.resume(throwing: GameCenterServiceError.cancelled)
        }
        if entries.isEmpty { route = nil }
    }
}

@MainActor final class GameCenterPartyMatch: Sendable {
    let transport: any NetworkTransport
    private var closed = false
    private let onClose: () -> Void
    init(transport: any NetworkTransport, onClose: @escaping () -> Void = {}) { self.transport = transport; self.onClose = onClose }
    func close() { guard !closed else { return }; closed = true; transport.onEvent = nil; transport.disconnect(); onClose() }
    isolated deinit { close() }
}
