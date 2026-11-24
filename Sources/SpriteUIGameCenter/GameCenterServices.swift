import ECSCore
import Foundation
import Observation

/// Destinations hosted by `View.gameCenter(_:)`. Presenting sign-in and
/// matchmaking is always the result of an explicit application action.
public enum GameCenterDestination: Equatable, Sendable {
    case signIn
    case matchmaking
    case turnBased
    case achievements
    case leaderboards
    case leaderboard(String)
    case setup
    case activities, activityDefinition(String), challenges, challengeOverview, challengeDefinition(String)
}

/// One application-scoped entry point for Game Center's basic services.
///
/// Retain it in SwiftUI state and install `.gameCenter(services)` on one parent
/// view. Call `present(_:)` from buttons, or `connect(in:schema:request:)` to
/// authenticate, match, and attach a retained replication session to a world.
/// Construction never signs in, presents UI, or contacts Game Center.
@MainActor @Observable
public final class GameCenterServices {
    public let mode: GameCenterServicesMode
    public let multiplayer: GameCenterMultiplayer
    public let achievements: GameCenterAchievements
    public let leaderboards: GameCenterLeaderboards
    public let turnBased: GameCenterTurnBasedMatches
    /// Explicit reporting of player-owned quests and local league scores.
    public let progression: GameCenterProgression
    /// Explicit activity lifecycle and pending system intents.
    public let activities: GameCenterActivities
    /// Native challenge metadata and explicit attempt reporting.
    public let challenges: GameCenterChallenges
    public private(set) var destination: GameCenterDestination? {
        didSet { if oldValue != destination { presentationRevision &+= 1 } }
    }
    /// Activity-based party matchmaking and explicit prepared-world handoff.
    public let party: GameCenterParty
    /// The active ordinary or activity-party replication session.
    public var networkSession: NetworkSession? { party.networkSession ?? attachedSession }
    private var attachedSession: NetworkSession?
    public private(set) var lastError: GameCenterServiceError?
    public private(set) var matchRequest = GameCenterMatchRequest()
    public var isPreview: Bool { context.isPreview }
    public var isAuthenticated: Bool { isPreview || multiplayer.authenticationState == .authenticated }
    public var localPlayer: NetworkPeer? {
        if case .preview(let player) = mode { return player }
        return multiplayer.localPeer
    }
    @ObservationIgnored private let context: GameCenterServiceContext
    @ObservationIgnored private var pendingDestination: GameCenterDestination?
    @ObservationIgnored private weak var pendingWorld: World?
    @ObservationIgnored private var pendingSchema: NetworkReplicationSchema?
    @ObservationIgnored private var pendingConfiguration: NetworkSessionConfiguration?
    @ObservationIgnored private var lastAuthenticatedPlayer: NetworkPeerID?
    private(set) var presentationRevision: UInt64 = 0

    public init(mode: GameCenterServicesMode = .live) {
        self.mode = mode
        let context = GameCenterServiceContext(mode: mode)
        self.context = context
        multiplayer = context.isPreview
            ? GameCenterMultiplayer(authenticationDriver: .live, permitsAuthentication: false)
            : GameCenterMultiplayer()
        achievements = GameCenterAchievements(context: context)
        leaderboards = GameCenterLeaderboards(context: context)
        turnBased = GameCenterTurnBasedMatches(context: context)
        progression = GameCenterProgression(context: context, achievements: achievements, leaderboards: leaderboards)
        activities = GameCenterActivities(context: context)
        challenges = GameCenterChallenges(context: context, leaderboards: leaderboards)
        party = GameCenterParty(context: context, activities: activities, multiplayer: multiplayer)
        party.canBegin = { [weak self] in
            guard let self else { return false }
            guard self.pendingSchema == nil, self.attachedSession == nil, self.multiplayer.transport == nil,
                  self.destination != .matchmaking else { return false }
            switch self.multiplayer.matchmakingState { case .idle, .failed: return true; default: return false }
        }
    }

    isolated deinit { shutdown() }

    /// An account-free local environment for previews and examples. These
    /// services never connect to Apple or emulate a production multiplayer host.
    public static func preview(player: NetworkPeer = .init(id: .init(rawValue: "preview-player"), displayName: "Preview player")) -> GameCenterServices {
        GameCenterServices(mode: .preview(player: player))
    }

    /// Requests a service screen. A live screen requiring an account first
    /// presents sign-in, then continues to the originally requested destination.
    public func present(_ destination: GameCenterDestination) {
        lastError = nil
        if destination == .matchmaking, party.isActive { lastError = .operationInProgress; return }
        switch destination {
        case .activities, .activityDefinition, .challenges, .challengeOverview, .challengeDefinition:
            guard isPreview || GameCenterActivities.isSupported else { lastError = .unavailable; return }
        default: break
        }
        switch destination {
        case .activityDefinition(let id), .challengeDefinition(let id):
            do { try validateGameCenterIdentifier(id) } catch { recordFailure(error); return }
        default: break
        }
        if destination != .matchmaking && destination != .signIn {
            pendingWorld = nil; pendingSchema = nil; pendingConfiguration = nil
        }
        if destination == .setup || destination == .signIn || isAuthenticated {
            pendingDestination = nil; self.destination = destination
        } else {
            pendingDestination = destination; self.destination = .signIn
        }
    }

    /// Configures a real-time match request before presenting its built-in UI.
    public func presentMatchmaking(_ request: GameCenterMatchRequest = .init()) throws {
        try request.validate()
        guard !party.isActive, networkSession == nil, multiplayer.transport == nil else { throw GameCenterServiceError.operationInProgress }
        matchRequest = request
        present(.matchmaking)
    }

    /// Starts the user-driven sign-in/matchmaking flow and automatically creates
    /// the appropriate host/client session when the complete match is ready.
    /// The world is held weakly until then. Install the SwiftUI modifier first.
    public func connect(in world: World, schema: NetworkReplicationSchema = .init(),
                        request: GameCenterMatchRequest = .init(),
                        configuration: NetworkSessionConfiguration = .init()) throws {
        guard !isPreview else { throw GameCenterServiceError.unavailable }
        guard !party.isActive, pendingSchema == nil, networkSession == nil, multiplayer.transport == nil else {
            throw GameCenterServiceError.operationInProgress
        }
        try request.validate()
        pendingWorld = world; pendingSchema = schema; pendingConfiguration = configuration
        matchRequest = request
        present(.matchmaking)
    }

    /// Attaches an already-ready Game Center match, choosing authority and
    /// retaining the resulting session. Existing low-level APIs remain usable.
    @discardableResult
    public func startSession(in world: World, schema: NetworkReplicationSchema = .init(),
                             configuration: NetworkSessionConfiguration = .init()) throws -> NetworkSession {
        guard multiplayer.matchmakingState == .ready, let transport = multiplayer.transport,
              let host = multiplayer.hostPeerID else { throw GameCenterServiceError.notFound }
        return try attachSession(in: world, transport: transport, host: host, schema: schema, configuration: configuration)
    }

    @discardableResult
    func attachSession(in world: World, transport: any NetworkTransport, host: NetworkPeerID,
                       schema: NetworkReplicationSchema = .init(),
                       configuration: NetworkSessionConfiguration = .init()) throws -> NetworkSession {
        guard !party.isActive, networkSession == nil else { throw GameCenterServiceError.operationInProgress }
        let role: NetworkSession.Role = transport.localPeer.id == host ? .host : .client(host: host)
        let session = NetworkSession(world: world, transport: transport, role: role, schema: schema, configuration: configuration)
        try session.start(); attachedSession = session
        return session
    }

    /// Dismisses only this service flow. A ready match is retained until
    /// disconnect; cancelling authentication/matchmaking discards its pending world.
    public func dismiss() {
        let previous = destination
        destination = nil; pendingDestination = nil
        if previous == .signIn { multiplayer.cancelAuthentication() }
        if previous == .matchmaking { multiplayer.cancelMatchmaking() }
        pendingWorld = nil; pendingSchema = nil; pendingConfiguration = nil
    }

    /// Stops replication before releasing the native match. Local host entities
    /// remain, following NetworkSession's normal teardown contract.
    public func disconnect() {
        party.leave()
        if destination == .matchmaking || pendingDestination == .matchmaking { dismiss() }
        attachedSession?.stop(); attachedSession = nil
        pendingWorld = nil; pendingSchema = nil; pendingConfiguration = nil
        multiplayer.disconnect()
    }

    /// Invalidates pending service results and releases this app's listeners and
    /// presentation. It never signs the person out of their system account.
    public func shutdown() {
        dismiss(); disconnect(); context.invalidate()
        achievements.reset(); leaderboards.reset(); turnBased.reset()
        activities.reset(); challenges.reset()
        multiplayer.shutdown(); lastAuthenticatedPlayer = nil
    }

    func authenticationDidChange() {
        guard !isPreview else { return }
        updateAuthenticatedIdentity(isAuthenticated ? multiplayer.localPeer?.id : nil)
        if isAuthenticated {
            // Sign-in explicitly enables the shared services. Register early
            // enough to receive pending turn notifications before inbox loading.
            do { try turnBased.start() } catch { recordFailure(error) }
            do { try activities.startListening() } catch { recordFailure(error) }
        }
        if isAuthenticated, let next = pendingDestination {
            pendingDestination = nil; destination = next
        }
    }

    // Identity is independent of the status enum: switching accounts can keep
    // `.authenticated` throughout the transition.
    func updateAuthenticatedIdentity(_ player: NetworkPeerID?) {
        if let previous = lastAuthenticatedPlayer, player != previous {
            dismiss(); disconnect(); context.invalidate()
            achievements.reset(); leaderboards.reset(); turnBased.reset()
            activities.reset(); challenges.reset()
        }
        lastAuthenticatedPlayer = player
    }

    func matchmakingDidChange() {
        switch multiplayer.matchmakingState {
        case .ready:
            if let schema = pendingSchema {
                guard let world = pendingWorld else {
                    lastError = .cancelled; disconnect(); destination = nil; return
                }
                do { try startSession(in: world, schema: schema, configuration: pendingConfiguration ?? .init()) }
                catch { lastError = gameCenterServiceFailure(error); disconnect() }
            }
            pendingWorld = nil; pendingSchema = nil; pendingConfiguration = nil
            if destination == .matchmaking { destination = nil }
        case .idle, .failed:
            if multiplayer.transport == nil { attachedSession?.stop(); attachedSession = nil }
        case .matchmaking, .waitingForPlayers: break
        }
    }

    func recordFailure(_ error: any Error) { lastError = gameCenterServiceFailure(error) }

    func finishPresentation(revision: UInt64, error: (any Error)? = nil) {
        guard destination != nil, presentationRevision == revision else { return }
        if let error { recordFailure(error) }
        dismiss()
    }
}
