import ECSCore
import Foundation
import Observation

/// The local phase of an activity party. Gameplay presentation remains application-owned.
public enum GameCenterPartyState: String, Sendable {
    case idle, matching, lobby, starting, playing, failed
}

/// One member of the fixed, authenticated transport roster, including the local player.
public struct GameCenterPartyMember: Hashable, Sendable, Identifiable {
    /// The transport-authenticated peer, never an identity supplied by a packet.
    public let peer: NetworkPeer
    /// Whether this player prepared a compatible world and explicitly readied it.
    public let isReady: Bool
    /// An application-owned level/protocol identifier, not an automatic schema fingerprint.
    public let compatibilityID: String?
    /// The player's stable identity.
    public var id: NetworkPeerID { peer.id }
}

/// Activity-scoped matchmaking, readiness, and a prepared-world replication handoff.
/// Retain through GameCenterServices.party. Nothing authenticates, matches, replaces a world, or reports a score automatically.
@MainActor @Observable public final class GameCenterParty {
    /// The current phase, also retiring stale identities or externally ended activities.
    public var state: GameCenterPartyState { synchronize(); return phase }
    /// The fixed lobby roster, including the local member.
    public var members: [GameCenterPartyMember] { synchronize(); return roster }
    /// The deterministic host elected from the complete initial roster.
    public private(set) var hostPeerID: NetworkPeerID?
    /// The activity being matched; instance IDs may differ between participants.
    public private(set) var activity: GameCenterActivity?
    /// The replication session once attached. Present gameplay only after state becomes playing.
    public var networkSession: NetworkSession? { synchronize(); return session }
    /// The most recent local failure. No automatic retry or host migration follows it.
    public private(set) var lastError: GameCenterServiceError?
    /// Whether the local host has a prepared world and every member readied the same compatibility ID.
    /// - Complexity: O(n) in the bounded party roster.
    public var canStart: Bool {
        synchronize()
        return phase == .lobby && hostPeerID == owner?.player.id && preparedWorld != nil &&
            !roster.isEmpty && roster.allSatisfy { $0.isReady && $0.compatibilityID == compatibility }
    }
    /// Whether matchmaking, a lobby, or a playing session currently owns this coordinator.
    public var isActive: Bool { state != .idle && state != .failed }

    @ObservationIgnored private let context: GameCenterServiceContext
    @ObservationIgnored private let activities: GameCenterActivities
    @ObservationIgnored private let multiplayer: GameCenterMultiplayer
    @ObservationIgnored private var preview: GameCenterPartyPreview?
    @ObservationIgnored var canBegin: () -> Bool = { true }
    @ObservationIgnored var findOverride: ((any GameCenterActivityHandle) async throws -> GameCenterPartyMatch)?
    @ObservationIgnored private var owner: GameCenterServiceContext.Operation?
    @ObservationIgnored private var token: UUID?
    @ObservationIgnored private var cancelRequest: (() -> Void)?
    @ObservationIgnored private var match: GameCenterPartyMatch?
    @ObservationIgnored private var channel: GameCenterPartyChannel?
    @ObservationIgnored private weak var preparedWorld: World?
    @ObservationIgnored private var schema = NetworkReplicationSchema()
    @ObservationIgnored private var configuration = NetworkSessionConfiguration()
    @ObservationIgnored private var compatibility: String?
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var remoteRevisions: [NetworkPeerID: UInt64] = [:]
    @ObservationIgnored private var launchID: UUID?
    @ObservationIgnored private var acknowledgments: Set<NetworkPeerID> = []
    @ObservationIgnored private var watcher: EventSubscription?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored var handoffTimeout: TimeInterval = 15
    private var phase = GameCenterPartyState.idle
    private var roster: [GameCenterPartyMember] = []
    private var session: NetworkSession?

    init(context: GameCenterServiceContext, activities: GameCenterActivities, multiplayer: GameCenterMultiplayer) {
        self.context = context; self.activities = activities; self.multiplayer = multiplayer
    }
    isolated deinit { retire(notify: true) }

    /// Installs a shared account-free fixture before matchmaking. Live services reject fixtures.
    public func configurePreview(_ fixture: GameCenterPartyPreview) throws {
        guard context.isPreview else { throw GameCenterServiceError.unavailable }
        guard !isActive else { throw GameCenterServiceError.operationInProgress }
        preview = fixture
    }
    /// Matches the current started/accepted activity, preserving its party code and native request properties.
    /// All participants explicitly call this after validating their activity route. It never signs in itself.
    public func findMatch() async throws {
        synchronize()
        guard phase == .idle || phase == .failed, canBegin() else { throw GameCenterServiceError.operationInProgress }
        let operation = try context.begin(), attempt = UUID()
        let handle = try activities.reserveParty(attempt)
        owner = operation; token = attempt; activity = handle.snapshot; lastError = nil; phase = .matching
        let request = GameCenterProgressRequest<GameCenterPartyMatch>()
        cancelRequest = { request.cancel() }
        do {
            let result = try await request.run { [self] in
                if let findOverride { return try await findOverride(handle) }
                if context.isPreview {
                    guard let preview else { throw GameCenterServiceError.unavailable }
                    return try await preview.match(activity: handle.snapshot, player: operation.player)
                }
                return GameCenterPartyMatch(transport: try await handle.findPartyMatch(using: multiplayer))
            }
            try context.validate(operation)
            guard token == attempt else { result.close(); throw GameCenterServiceError.cancelled }
            guard activities.activity?.id == activity?.id, activities.activity?.state != .ended else { result.close(); throw GameCenterServiceError.activityEnded }
            let peers = [result.transport.localPeer] + result.transport.connectedPeers
            guard result.transport.localPeer.id == operation.player.id, (2...8).contains(peers.count),
                  Set(peers.map(\.id)).count == peers.count else { result.close(); throw GameCenterError.invalidRoster }
            for peer in peers { try validateGameCenterIdentifier(peer.id.rawValue) }
            let channel = try GameCenterPartyChannel(result.transport)
            match = result; self.channel = channel; cancelRequest = nil
            hostPeerID = peers.map(\.id).min()
            roster = peers.sorted { $0.id < $1.id }.map { .init(peer: $0, isReady: false, compatibilityID: nil) }
            channel.control = { [weak self] data, sender in self?.receive(data, from: sender) }
            channel.ended = { [weak self] reason in self?.fail(GameCenterServiceError.gameCenter(reason)) }
            phase = .lobby
            try broadcast(.hello)
        } catch {
            if token == attempt { fail(error) }
            throw gameCenterServiceFailure(error)
        }
    }
    /// Retains a schema and a weak prepared world without attaching replication or changing the displayed game.
    /// Use a stable ID covering your content and wire protocol; all members must supply the same value.
    public func prepare(in world: World, compatibilityID: String, schema: NetworkReplicationSchema = .init(),
                        configuration: NetworkSessionConfiguration = .init()) throws {
        try requireLobby(); try validateGameCenterIdentifier(compatibilityID)
        preparedWorld = world; compatibility = compatibilityID; self.schema = schema; self.configuration = configuration
        watcher = world.subscribe(to: WorldEvents.Update.self) { [weak self] _ in self?.synchronize() }
        try updateLocal(ready: false)
    }
    /// Advertises explicit readiness after preparation; does not start gameplay.
    public func setReady(_ ready: Bool) throws {
        try requireLobby()
        guard !ready || (preparedWorld != nil && compatibility != nil) else { throw GameCenterServiceError.invalidValue }
        try updateLocal(ready: ready)
    }
    /// The host requests the handoff after all compatible worlds are ready.
    /// Peers attach their prepared sessions, acknowledge, then receive the host's play commit.
    public func startSession() throws {
        try requireLobby()
        guard canStart else { throw GameCenterServiceError.invalidValue }
        launchID = UUID(); phase = .starting
        do { try attach(); startWatchdog(); try broadcast(.launch); try commitIfReady() }
        catch { fail(error); throw error }
    }
    /// Cancels only this party and its replication. The activity and current gameplay remain application-owned.
    /// Leave before finishing/discarding the activity. Cancellation never reports staged activity scores.
    public func leave() { retire(notify: true); phase = .idle; lastError = nil }

    private func requireLobby() throws {
        synchronize(); guard phase == .lobby else { throw GameCenterServiceError.operationInProgress }
        guard let owner else { throw GameCenterServiceError.cancelled }; try context.validate(owner)
    }
    private func updateLocal(ready: Bool) throws {
        guard let id = owner?.player.id, let index = roster.firstIndex(where: { $0.id == id }) else { throw GameCenterServiceError.invalidData }
        revision &+= 1
        roster[index] = .init(peer: roster[index].peer, isReady: ready, compatibilityID: compatibility)
        do { try broadcast(.status) } catch { fail(error); throw error }
    }
    private func packet(_ kind: GameCenterPartyPacket.Kind) throws -> GameCenterPartyPacket {
        guard let activity, let code = activity.partyCode else { throw GameCenterServiceError.activityEnded }
        return .init(kind: kind, definition: activity.definitionID, code: code, roster: roster.map(\.id), revision: revision,
                     compatibility: compatibility, ready: roster.first(where: { $0.id == owner?.player.id })?.isReady ?? false, launch: launchID)
    }
    private func broadcast(_ kind: GameCenterPartyPacket.Kind) throws {
        guard let channel else { throw GameCenterServiceError.matchEnded }
        let value = try packet(kind)
        for peer in roster where peer.id != channel.localPeer.id { try channel.sendControl(value, to: peer.id) }
    }
    private func receive(_ data: Data, from sender: NetworkPeerID) {
        synchronize()
        guard phase == .lobby || phase == .starting || phase == .playing,
              let index = roster.firstIndex(where: { $0.id == sender }), sender != owner?.player.id else { return }
        do {
            let value = try JSONDecoder().decode(GameCenterPartyPacket.self, from: data)
            guard value.version == 1, value.definition == activity?.definitionID, value.code == activity?.partyCode,
                  value.roster == roster.map(\.id), value.compatibility == nil || (try? validateGameCenterIdentifier(value.compatibility!)) != nil else {
                throw GameCenterServiceError.invalidData
            }
            switch value.kind {
            case .hello, .status:
                guard phase == .lobby else { return }
                if let old = remoteRevisions[sender], value.revision < old { return }
                guard !value.ready || value.compatibility != nil else { throw GameCenterServiceError.invalidData }
                remoteRevisions[sender] = value.revision
                roster[index] = .init(peer: roster[index].peer, isReady: value.ready, compatibilityID: value.compatibility)
                if value.kind == .hello, let channel { try channel.sendControl(packet(.status), to: sender) }
            case .launch:
                guard sender == hostPeerID, owner?.player.id != hostPeerID else { throw GameCenterServiceError.invalidData }
                if phase == .starting || phase == .playing {
                    guard launchID == value.launch else { throw GameCenterServiceError.invalidData }
                } else {
                    guard let launch = value.launch, value.compatibility == compatibility,
                          roster.first(where: { $0.id == owner?.player.id })?.isReady == true else { throw GameCenterServiceError.invalidData }
                    launchID = launch; phase = .starting; try attach(); startWatchdog()
                }
                if let channel { try channel.sendControl(packet(.ack), to: sender) }
            case .ack:
                guard owner?.player.id == hostPeerID, value.launch != nil, value.launch == launchID,
                      phase == .starting || phase == .playing else { throw GameCenterServiceError.invalidData }
                acknowledgments.insert(sender); try commitIfReady()
            case .play:
                guard sender == hostPeerID, value.launch != nil, value.launch == launchID, phase == .starting || phase == .playing,
                      session != nil else { throw GameCenterServiceError.invalidData }
                phase = .playing; watchdog?.cancel(); watchdog = nil
            case .cancel: throw GameCenterServiceError.cancelled
            }
        } catch { fail(error) }
    }
    private func attach() throws {
        guard let world = preparedWorld, let channel, let host = hostPeerID else { throw NetworkSessionError.worldUnavailable }
        let session = NetworkSession(world: world, transport: channel,
            role: channel.localPeer.id == host ? .host : .client(host: host), schema: schema, configuration: configuration)
        try session.start(); self.session = session
    }
    private func commitIfReady() throws {
        guard phase == .starting, owner?.player.id == hostPeerID,
              acknowledgments.count == roster.count - 1 else { return }
        try broadcast(.play); phase = .playing; watchdog?.cancel(); watchdog = nil
    }
    private func startWatchdog() {
        let expected = token, delay = handoffTimeout
        watchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.token == expected, self.phase == .starting else { return }
            self.fail(GameCenterServiceError.gameCenter("The prepared-world handoff timed out."))
        }
    }
    private func synchronize() {
        guard let owner else { return }
        do {
            try context.validate(owner)
            guard activities.activity?.id == activity?.id, activities.activity?.state != .ended else { throw GameCenterServiceError.activityEnded }
            if let session, session.state == .failed || session.state == .stopped { throw GameCenterServiceError.matchEnded }
        } catch is CancellationError { } catch { fail(error) }
    }
    private func fail(_ error: any Error) {
        guard token != nil else { return }
        retire(notify: true); lastError = gameCenterServiceFailure(error); phase = .failed
    }
    private func retire(notify: Bool) {
        let previous = token; token = nil
        if notify, channel != nil { try? broadcast(.cancel) }
        cancelRequest?(); cancelRequest = nil; watchdog?.cancel(); watchdog = nil
        watcher?.cancel(); watcher = nil
        let session = session; self.session = nil; session?.stop()
        channel?.close(); channel = nil
        let match = match; self.match = nil; match?.close()
        if let previous { activities.releaseParty(previous) }
        owner = nil; activity = nil; roster = []; hostPeerID = nil; preparedWorld = nil; compatibility = nil
        revision = 0; remoteRevisions = [:]; launchID = nil; acknowledgments = []
    }
}
