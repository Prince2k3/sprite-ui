import ECSCore
import Foundation
@preconcurrency import GameKit

/// Failures reported before handing invalid requests or packets to GameKit.
public enum GameCenterError: Error, LocalizedError, Equatable, Sendable {
    case invalidRequest(String)
    case notAuthenticated
    case multiplayerRestricted
    case operationInProgress
    case noPendingInvite
    case unavailable
    case incompleteRoster
    case invalidRoster
    case disconnected
    case unknownPeer
    case payloadTooLarge(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let reason): reason
        case .notAuthenticated: "Sign in to Game Center first."
        case .multiplayerRestricted: "Multiplayer games are restricted for this Game Center account."
        case .operationInProgress: "Another Game Center operation or match is active."
        case .noPendingInvite: "There is no pending Game Center invitation."
        case .unavailable: "Game Center could not present matchmaking."
        case .incompleteRoster: "The match is still waiting for players."
        case .invalidRoster: "Game Center returned an invalid or changed player roster."
        case .disconnected: "The Game Center match has disconnected."
        case .unknownPeer: "The recipient is not connected to this match."
        case .payloadTooLarge(let limit): "The Game Center packet exceeds the \(limit)-byte limit."
        }
    }
}

/// GameKit's authenticated peer-to-peer match, adapted to ECSCore's transport.
///
/// Obtain this from `GameCenterMultiplayer.transport` after matchmaking becomes
/// `.ready`. The roster and host are fixed for the life of a match. A departed
/// peer is removed; a host departure ends the match without electing a new host.
/// Initial peers are available synchronously in `connectedPeers`; subsequent
/// changes and packets are delivered to `onEvent` on the main actor.
@MainActor
public final class GameCenterTransport: NetworkTransport {
    nonisolated public static let maximumReliablePayloadBytes = 48_000
    nonisolated public static let maximumUnreliablePayloadBytes = 1_000

    public let localPeer: NetworkPeer
    public let hostPeerID: NetworkPeerID
    public private(set) var connectedPeers: [NetworkPeer]
    public var onEvent: (@MainActor (NetworkTransportEvent) -> Void)?
    public private(set) var isConnected = true

    private let retainedMatch: GameCenterCallback<GKMatch>
    private var match: GKMatch { retainedMatch.value }
    private let matchID: ObjectIdentifier
    private var players: [NetworkPeerID: GKPlayer]
    private var matchDelegate: GameCenterMatchDelegate?
    private let signalRouter: GameCenterMatchSignalRouter
    // Separate from onEvent, which belongs to the NetworkSession consumer.
    var onDisconnect: (@MainActor (String?) -> Void)?

    init(match: GKMatch, localPeer: NetworkPeer, signalRouter: GameCenterMatchSignalRouter) throws {
        let ids = match.players.map { NetworkPeerID(rawValue: $0.gamePlayerID) }
        hostPeerID = try GameCenterRoster.host(
            localID: localPeer.id, remoteIDs: ids, expectedPlayerCount: match.expectedPlayerCount)
        self.localPeer = localPeer
        retainedMatch = GameCenterCallback(match)
        matchID = ObjectIdentifier(match)
        self.signalRouter = signalRouter
        players = Dictionary(uniqueKeysWithValues: zip(ids, match.players))
        connectedPeers = match.players.map(Self.peer).sorted { $0.id.rawValue < $1.id.rawValue }
        // Both the old pending delegate and this new delegate deliver through
        // one match-scoped router. Already-enqueued callbacks follow this
        // handoff instead of being rejected by the retired matchmaking token.
        signalRouter.handOff { [weak self] signal in self?.receive(signal) }
        let delegate = GameCenterMatchDelegate { signal in signalRouter.deliver(signal) }
        matchDelegate = delegate
        match.delegate = delegate
    }

    public func send(_ data: Data, to peer: NetworkPeerID, reliably: Bool) throws {
        guard isConnected else { throw GameCenterError.disconnected }
        guard GKLocalPlayer.local.isAuthenticated,
              GKLocalPlayer.local.gamePlayerID == localPeer.id.rawValue else {
            end(reason: GameCenterError.notAuthenticated.localizedDescription)
            throw GameCenterError.notAuthenticated
        }
        try Self.validatePayloadSize(data.count, reliably: reliably)
        guard let recipient = players[peer] else { throw GameCenterError.unknownPeer }
        try match.send(data, to: [recipient], dataMode: reliably ? .reliable : .unreliable)
    }

    public func disconnect() { end(reason: nil) }

    func owns(_ match: GKMatch) -> Bool { isConnected && ObjectIdentifier(match) == matchID }

    static func validatePayloadSize(_ count: Int, reliably: Bool) throws {
        let limit = reliably ? maximumReliablePayloadBytes : maximumUnreliablePayloadBytes
        guard count >= 0, count <= limit else { throw GameCenterError.payloadTooLarge(limit: limit) }
    }

    static func peer(_ player: GKPlayer) -> NetworkPeer {
        NetworkPeer(id: NetworkPeerID(rawValue: player.gamePlayerID), displayName: player.displayName)
    }

    private func receive(_ signal: GameCenterMatchSignal) {
        guard isConnected, signal.matchID == matchID else { return }
        guard GKLocalPlayer.local.isAuthenticated,
              GKLocalPlayer.local.gamePlayerID == localPeer.id.rawValue else {
            end(reason: GameCenterError.notAuthenticated.localizedDescription)
            return
        }
        switch signal {
        case .received(_, let data, let sender, let recipient):
            // Identity comes ONLY from GameKit's delegate, never from packet contents.
            guard players[sender] != nil, recipient == nil || recipient == localPeer.id else { return }
            // GameKit does not expose the delivery mode on receipt. Apply the
            // largest permitted cap before any consumer attempts decoding.
            guard data.count <= Self.maximumReliablePayloadBytes else {
                onEvent?(.failed(GameCenterError.payloadTooLarge(limit: Self.maximumReliablePayloadBytes).localizedDescription))
                return
            }
            onEvent?(.received(data, from: sender))
        case .changed(_, let peerID, let state):
            if state == GKPlayerConnectionState.disconnected.rawValue {
                guard players.removeValue(forKey: peerID) != nil else { return }
                connectedPeers.removeAll { $0.id == peerID }
                // End and clear state BEFORE calling consumers, which may reenter.
                if peerID == hostPeerID || connectedPeers.isEmpty {
                    end(reason: "A required player left the Game Center match.", departed: peerID)
                } else { onEvent?(.disconnected(peerID)) }
            } else if state == GKPlayerConnectionState.connected.rawValue, players[peerID] == nil {
                // No late additions: they could disagree with the fixed host election.
                end(reason: GameCenterError.invalidRoster.localizedDescription)
            }
        case .failed(_, let message): end(reason: message)
        }
    }

    private func end(reason: String?, departed: NetworkPeerID? = nil) {
        guard isConnected else { return }
        isConnected = false
        signalRouter.retire()
        match.delegate = nil
        matchDelegate = nil
        let peers = connectedPeers.map(\.id)
        players.removeAll()
        connectedPeers.removeAll()
        match.disconnect()
        let event = onEvent
        let finished = onDisconnect
        onDisconnect = nil
        finished?(reason)
        if let departed { event?(.disconnected(departed)) }
        for peer in peers where peer != departed { event?(.disconnected(peer)) }
        if let reason { event?(.failed(reason)) }
    }

    deinit {
        // GKMatch requires an explicit disconnect before its final release.
        // Only this retained reference is transferred to the main queue.
        let retained = retainedMatch
        DispatchQueue.main.async { retained.value.disconnect() }
    }
}

/// Shared validation keeps the completion gate and deterministic election testable
/// without signing in or constructing GameKit objects.
enum GameCenterRoster {
    static func host(localID: NetworkPeerID, remoteIDs: [NetworkPeerID],
                     expectedPlayerCount: Int) throws -> NetworkPeerID {
        guard expectedPlayerCount == 0 else { throw GameCenterError.incompleteRoster }
        let all = [localID] + remoteIDs
        guard !remoteIDs.isEmpty, all.allSatisfy({ !$0.rawValue.isEmpty }),
              Set(all).count == all.count else { throw GameCenterError.invalidRoster }
        return all.min { $0.rawValue < $1.rawValue }!
    }
}

/// Retains an SDK callback object until the main queue consumes it. The callback
/// thread never mutates the object; all application access occurs on MainActor.
final class GameCenterCallback<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

enum GameCenterMatchSignal: Sendable {
    case received(ObjectIdentifier, Data, NetworkPeerID, recipient: NetworkPeerID?)
    case changed(ObjectIdentifier, NetworkPeerID, Int)
    case failed(ObjectIdentifier, String)

    var matchID: ObjectIdentifier {
        switch self {
        case .received(let id, _, _, _), .changed(let id, _, _), .failed(let id, _): id
        }
    }
}

/// A delegate callback captures this router before enqueueing on the main queue,
/// but selects its receiver only when delivered. Each match gets a fresh router;
/// handoff preserves queued callbacks and retirement is permanent, even if a
/// subsequent match happens to reuse an SDK object's identity.
@MainActor
final class GameCenterMatchSignalRouter {
    private let matchID: ObjectIdentifier
    private var receive: (@MainActor (GameCenterMatchSignal) -> Void)?
    private var isRetired = false

    init(matchID: ObjectIdentifier, receive: @escaping @MainActor (GameCenterMatchSignal) -> Void) {
        self.matchID = matchID
        self.receive = receive
    }

    func deliver(_ signal: GameCenterMatchSignal) {
        guard !isRetired, signal.matchID == matchID else { return }
        receive?(signal)
    }

    func handOff(to receive: @escaping @MainActor (GameCenterMatchSignal) -> Void) {
        guard !isRetired else { return }
        self.receive = receive
    }

    func retire() {
        isRetired = true
        receive = nil
    }
}

/// GameKit callbacks may arrive off the main actor. Snapshot only GameKit's
/// sender identity and bytes, then enqueue on the serial main queue in order.
final class GameCenterMatchDelegate: NSObject, GKMatchDelegate, Sendable {
    let receive: @MainActor @Sendable (GameCenterMatchSignal) -> Void
    init(receive: @escaping @MainActor @Sendable (GameCenterMatchSignal) -> Void) { self.receive = receive }

    private func deliver(_ signal: GameCenterMatchSignal) {
        let receive = receive
        DispatchQueue.main.async { receive(signal) }
    }

    func match(_ match: GKMatch, didReceive data: Data, fromRemotePlayer player: GKPlayer) {
        guard data.count <= GameCenterTransport.maximumReliablePayloadBytes else {
            deliver(.failed(ObjectIdentifier(match), "Received an oversized Game Center packet."))
            return
        }
        deliver(.received(ObjectIdentifier(match), data, NetworkPeerID(rawValue: player.gamePlayerID), recipient: nil))
    }

    func match(_ match: GKMatch, didReceive data: Data, forRecipient recipient: GKPlayer, fromRemotePlayer player: GKPlayer) {
        guard data.count <= GameCenterTransport.maximumReliablePayloadBytes else {
            deliver(.failed(ObjectIdentifier(match), "Received an oversized Game Center packet."))
            return
        }
        deliver(.received(ObjectIdentifier(match), data, NetworkPeerID(rawValue: player.gamePlayerID),
                          recipient: NetworkPeerID(rawValue: recipient.gamePlayerID)))
    }

    func match(_ match: GKMatch, player: GKPlayer, didChange state: GKPlayerConnectionState) {
        deliver(.changed(ObjectIdentifier(match), NetworkPeerID(rawValue: player.gamePlayerID), state.rawValue))
    }

    func match(_ match: GKMatch, didFailWithError error: (any Error)?) {
        deliver(.failed(ObjectIdentifier(match), error?.localizedDescription ?? "The Game Center match failed."))
    }

    func match(_ match: GKMatch, shouldReinviteDisconnectedPlayer player: GKPlayer) -> Bool { false }
}
