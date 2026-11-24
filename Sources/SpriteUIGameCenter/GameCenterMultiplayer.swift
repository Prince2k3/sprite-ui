import ECSCore
import Foundation
@preconcurrency import GameKit
import Observation
#if os(iOS)
import UIKit
typealias GameCenterAuthenticationController = UIViewController
#elseif os(macOS)
import AppKit
typealias GameCenterAuthenticationController = NSViewController
#endif

/// Small authentication boundary lets cancellation races be exercised without
/// installing a system sign-in handler or contacting Game Center.
@MainActor
struct GameCenterAuthenticationDriver {
    typealias Handler = @MainActor @Sendable (GameCenterCallback<GameCenterAuthenticationController>?, String?) -> Void
    var start: (@escaping Handler) -> Void
    var cancel: () -> Void

    static var live: Self {
        Self(start: { callback in
            GKLocalPlayer.local.authenticateHandler = { controller, error in
                let retained = controller.map(GameCenterCallback.init)
                let message = error?.localizedDescription
                DispatchQueue.main.async { callback(retained, message) }
            }
        }, cancel: { GKLocalPlayer.local.authenticateHandler = nil })
    }
}

/// Player counts include the local player. Use playerGroup to separate protocol
/// versions or game modes; all peers in a match must use the same wire schema.
public struct GameCenterMatchRequest: Equatable, Sendable {
    public var minPlayers: Int
    public var maxPlayers: Int
    public var playerGroup: Int

    public init(minPlayers: Int = 2, maxPlayers: Int = 2, playerGroup: Int = 0) {
        self.minPlayers = minPlayers
        self.maxPlayers = maxPlayers
        self.playerGroup = playerGroup
    }

    public func validate() throws {
        try validate(maximumPlayers: GKMatchRequest.maxPlayersAllowedForMatch(of: .peerToPeer))
    }

    func validate(maximumPlayers: Int) throws {
        guard minPlayers >= 2, maxPlayers >= minPlayers, maxPlayers <= maximumPlayers else {
            throw GameCenterError.invalidRequest("Player counts must satisfy 2 ≤ minPlayers ≤ maxPlayers ≤ \(maximumPlayers).")
        }
        guard playerGroup >= 0 else {
            throw GameCenterError.invalidRequest("The matchmaking player group cannot be negative.")
        }
    }

    func nativeRequest() throws -> GKMatchRequest {
        try validate()
        let request = GKMatchRequest()
        request.minPlayers = minPlayers
        request.maxPlayers = maxPlayers
        request.defaultNumberOfPlayers = maxPlayers
        request.playerGroup = playerGroup
        return request
    }
}

public enum GameCenterAuthenticationState: Equatable, Sendable {
    case unauthenticated
    case authenticating
    case authenticated
    case failed(String)
}

public enum GameCenterMatchmakingState: Equatable, Sendable {
    case idle
    case matchmaking
    case waitingForPlayers
    /// The complete initial roster, transport, and fixed host ID are available.
    case ready
    case failed(String)
}

/// User-driven Game Center authentication and real-time matchmaking.
///
/// Keep one coordinator per application. Construction does not access GameKit,
/// sign in, or start matchmaking. Present `GameCenterAuthenticationView` and
/// `GameCenterMatchmakingView` in SwiftUI sheets; their buttons initiate work.
/// Alternatively call the corresponding actions from your own buttons and use
/// the views to display the native GameKit UI. No native controllers are public.
///
/// When `matchmakingState == .ready`, use `transport` and `hostPeerID` to create
/// a NetworkSession with `.host` if transport.localPeer.id == hostPeerID, or
/// `.client(host: hostPeerID)` otherwise. Install the session before gameplay.
/// Call `shutdown()` when retiring the coordinator to release global GameKit
/// authentication/listener ownership. Dismissing a sheet cancels only its work;
/// it does not disconnect a ready match.
///
/// App setup (in the consuming app, not this package): enable the Game Center
/// capability and signed com.apple.developer.game-center entitlement; configure
/// the matching bundle ID, Game Center app version, and multiplayer compatibility
/// in App Store Connect. Configure network permissions for a sandboxed Mac app.
/// No friends-list access or friends-list usage description is needed here.
/// Game Center fixes the match roster: replication baseline refreshes/rejoins
/// can involve existing connected participants, but cannot add new GKPlayers.
@MainActor @Observable
public final class GameCenterMultiplayer {
    public private(set) var authenticationState: GameCenterAuthenticationState = .unauthenticated
    public private(set) var matchmakingState: GameCenterMatchmakingState = .idle
    public private(set) var localPeer: NetworkPeer?
    public private(set) var transport: GameCenterTransport?
    public private(set) var hostPeerID: NetworkPeerID?
    public private(set) var hasPendingInvite = false
    public private(set) var pendingInviterName: String?

    #if os(iOS)
    var authenticationController: UIViewController?
    #elseif os(macOS)
    var authenticationController: NSViewController?
    #endif
    var matchmakingController: GKMatchmakerViewController?

    @ObservationIgnored private static weak var owner: GameCenterMultiplayer?
    // Weak references may already be nil during deinit. This lease identifies
    // our handler even then, and prevents old cleanup clearing a newer owner.
    @ObservationIgnored private static var ownerLease: UUID?
    @ObservationIgnored private let ownershipLease = UUID()
    @ObservationIgnored private var authenticationAttempt = GameCenterAttempt()
    @ObservationIgnored private var matchmakingAttempt = GameCenterAttempt()
    @ObservationIgnored private var matchmakerDelegate: GameCenterMatchmakerDelegate?
    @ObservationIgnored private var listener: GameCenterInviteListener?
    @ObservationIgnored private var pendingInvite: GKInvite?
    @ObservationIgnored private var pendingRecipients: [GKPlayer]?
    @ObservationIgnored private var pendingMatch: GKMatch?
    @ObservationIgnored private var pendingMatchDelegate: GameCenterMatchDelegate?
    @ObservationIgnored private var pendingMatchRouter: GameCenterMatchSignalRouter?
    @ObservationIgnored private var activityMatchCompletion: ((Result<GameCenterTransport, any Error>) -> Void)?
    @ObservationIgnored private var requestedRange: ClosedRange<Int> = 2...2
    @ObservationIgnored private let authenticationDriver: GameCenterAuthenticationDriver
    @ObservationIgnored private let permitsAuthentication: Bool

    public init() { authenticationDriver = .live; permitsAuthentication = true }

    init(authenticationDriver: GameCenterAuthenticationDriver, permitsAuthentication: Bool = true) {
        self.authenticationDriver = authenticationDriver
        self.permitsAuthentication = permitsAuthentication
    }

    isolated deinit { shutdown() }

    /// Explicit user action only. Repeated taps while signing in are ignored.
    public func authenticate() {
        guard permitsAuthentication else {
            authenticationState = .failed("Game Center sign-in is unavailable in local preview mode.")
            return
        }
        guard authenticationState != .authenticating, authenticationState != .authenticated else { return }
        guard Self.owner == nil || Self.owner === self else {
            authenticationState = .failed(GameCenterError.operationInProgress.localizedDescription)
            return
        }
        Self.owner = self
        Self.ownerLease = ownershipLease
        if let listener { GKLocalPlayer.local.unregisterListener(listener) }
        listener = nil
        let token = authenticationAttempt.begin()
        authenticationState = .authenticating
        authenticationDriver.start { [weak self] controller, error in
            self?.authenticationCompleted(token: token, controller: controller, error: error)
        }
    }

    public func cancelAuthentication() {
        guard authenticationState == .authenticating else { return }
        authenticationAttempt.cancel()
        authenticationController = nil
        authenticationState = .unauthenticated
        if Self.ownerLease == ownershipLease {
            authenticationDriver.cancel()
            Self.owner = nil
            Self.ownerLease = nil
        }
    }

    /// Explicitly opens Apple's peer-to-peer matchmaker; never signs in itself.
    public func findMatch(_ request: GameCenterMatchRequest = .init()) throws {
        let native = try request.nativeRequest()
        try checkCanMatch()
        guard let controller = GKMatchmakerViewController(matchRequest: native) else {
            throw GameCenterError.unavailable
        }
        beginMatchmaking(controller)
    }

    /// Invitations are queued by the listener, not automatically presented.
    /// Call from an Accept button, then show GameCenterMatchmakingView.
    public func acceptPendingInvite() throws {
        try checkCanMatch()
        let controller: GKMatchmakerViewController?
        if let pendingInvite { controller = GKMatchmakerViewController(invite: pendingInvite) }
        else if let pendingRecipients {
            let count = pendingRecipients.count + 1
            let request = try GameCenterMatchRequest(minPlayers: count, maxPlayers: count).nativeRequest()
            request.recipients = pendingRecipients
            controller = GKMatchmakerViewController(matchRequest: request)
        } else { throw GameCenterError.noPendingInvite }
        guard let controller else { throw GameCenterError.unavailable }
        declinePendingInvite()
        beginMatchmaking(controller)
    }

    public func declinePendingInvite() {
        pendingInvite = nil
        pendingRecipients = nil
        hasPendingInvite = false
        pendingInviterName = nil
    }

    public func cancelMatchmaking() {
        guard matchmakingAttempt.isActive else { return }
        retireMatchmaking(disconnectPending: true)
        matchmakingState = .idle
        completeActivityMatch(.failure(CancellationError()))
    }

    /// Ends the current match gracefully. There is no automatic host migration,
    /// reconnection, new matchmaking, or sign-in after a disconnection.
    public func disconnect() {
        cancelMatchmaking()
        let previous = transport
        transport = nil
        hostPeerID = nil
        matchmakingState = .idle
        previous?.onDisconnect = nil
        previous?.disconnect()
    }

    /// Releases only this coordinator's GameKit registrations and active match.
    /// Does not sign the person out of their system Game Center account.
    public func shutdown() {
        disconnect()
        declinePendingInvite()
        authenticationAttempt.cancel()
        authenticationController = nil
        localPeer = nil
        authenticationState = .unauthenticated
        if let listener { GKLocalPlayer.local.unregisterListener(listener) }
        listener = nil
        if Self.ownerLease == ownershipLease {
            authenticationDriver.cancel()
            Self.owner = nil
            Self.ownerLease = nil
        }
    }

    // Uses the same ownership, partial-roster delegate, and retirement path as the native UI matchmaker.
    func findActivityMatch(request: GKMatchRequest,
        start: @MainActor (@escaping @Sendable (GKMatch?, (any Error)?) -> Void) -> Void) async throws -> GameCenterTransport {
        try Task.checkCancellation(); try checkCanMatch()
        try GameCenterMatchRequest(minPlayers: request.minPlayers, maxPlayers: request.maxPlayers).validate()
        let token = matchmakingAttempt.begin()
        requestedRange = request.minPlayers...request.maxPlayers
        matchmakingState = .matchmaking
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                activityMatchCompletion = { continuation.resume(with: $0) }
                start { [weak self] match, error in
                    let retained = match.map(GameCenterCallback.init), message = error?.localizedDescription
                    DispatchQueue.main.async {
                        guard let self, self.matchmakingAttempt.accepts(token) else {
                            if let match = retained?.value, self?.transport?.owns(match) != true { match.disconnect() }
                            return
                        }
                        if let message { retained?.value.disconnect(); self.failMatchmaking(message) }
                        else if let match = retained?.value { self.foundMatch(match, token: token) }
                        else { self.failMatchmaking(GameCenterError.unavailable.localizedDescription) }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.matchmakingAttempt.accepts(token) else { return }
                self.cancelMatchmaking()
            }
        }
    }
    private func completeActivityMatch(_ result: Result<GameCenterTransport, any Error>) {
        let callback = activityMatchCompletion; activityMatchCompletion = nil; callback?(result)
    }

    private func checkCanMatch() throws {
        guard authenticationState == .authenticated, let localPeer,
              GKLocalPlayer.local.isAuthenticated,
              GKLocalPlayer.local.gamePlayerID == localPeer.id.rawValue else {
            throw GameCenterError.notAuthenticated
        }
        guard !GKLocalPlayer.local.isMultiplayerGamingRestricted else { throw GameCenterError.multiplayerRestricted }
        guard !matchmakingAttempt.isActive, transport == nil, authenticationController == nil else {
            throw GameCenterError.operationInProgress
        }
    }

    private func authenticationCompleted(token: UUID, controller: GameCenterCallback<GameCenterAuthenticationController>?, error: String?) {
        guard Self.owner === self, authenticationAttempt.accepts(token) else { return }
        if let controller, authenticationState == .authenticating {
            authenticationController = controller.value
            return
        }
        authenticationController = nil
        let player = GKLocalPlayer.local
        guard controller == nil, error == nil, player.isAuthenticated, !player.gamePlayerID.isEmpty else {
            disconnect()
            declinePendingInvite()
            localPeer = nil
            authenticationState = error.map(GameCenterAuthenticationState.failed) ?? .unauthenticated
            if let listener { player.unregisterListener(listener) }
            listener = nil
            return
        }
        // Account switches invalidate both the match and any old invitation.
        if let previous = localPeer, previous.id.rawValue != player.gamePlayerID {
            disconnect()
            declinePendingInvite()
        }
        localPeer = GameCenterTransport.peer(player)
        authenticationState = .authenticated
        if listener == nil {
            let listener = GameCenterInviteListener { [weak self] invite, recipients, name in
                guard let self, self.authenticationState == .authenticated,
                      Self.owner === self, self.transport == nil,
                      self.authenticationAttempt.accepts(token),
                      GKLocalPlayer.local.isAuthenticated,
                      GKLocalPlayer.local.gamePlayerID == self.localPeer?.id.rawValue,
                      !self.matchmakingAttempt.isActive else { return }
                self.pendingInvite = invite?.value
                self.pendingRecipients = recipients?.value
                self.pendingInviterName = name
                self.hasPendingInvite = true
            }
            self.listener = listener
            player.register(listener)
        }
    }

    private func beginMatchmaking(_ controller: GKMatchmakerViewController) {
        let token = matchmakingAttempt.begin()
        requestedRange = controller.matchRequest.minPlayers...controller.matchRequest.maxPlayers
        // Partial starts would allow each player to elect a different host.
        controller.canStartWithMinimumPlayers = false
        let delegate = GameCenterMatchmakerDelegate(
            cancelled: { [weak self] id in
                guard let self, self.acceptsMatchmaker(token, id: id) else { return }
                self.cancelMatchmaking()
            },
            failed: { [weak self] id, message in
                guard let self, self.acceptsMatchmaker(token, id: id) else { return }
                self.failMatchmaking(message)
            },
            found: { [weak self] id, match in
                guard let self, self.acceptsMatchmaker(token, id: id) else {
                    // A duplicate completion may carry the already-published
                    // live match. Never disconnect it as a stale result.
                    if self?.transport?.owns(match.value) != true { match.value.disconnect() }
                    return
                }
                self.foundMatch(match.value, token: token)
            })
        matchmakerDelegate = delegate
        controller.matchmakerDelegate = delegate
        matchmakingController = controller
        matchmakingState = .matchmaking
    }

    private func acceptsMatchmaker(_ token: UUID, id: ObjectIdentifier) -> Bool {
        matchmakingAttempt.accepts(token) && matchmakingController.map(ObjectIdentifier.init) == id
    }

    func matchmakingPresentationFailed(_ controller: GKMatchmakerViewController) {
        guard matchmakingController === controller, matchmakingAttempt.isActive else { return }
        failMatchmaking(GameCenterError.unavailable.localizedDescription)
    }

    private func foundMatch(_ match: GKMatch, token: UUID) {
        if let pendingMatch {
            if pendingMatch !== match { match.disconnect() }
            return
        }
        pendingMatch = match
        let router = GameCenterMatchSignalRouter(matchID: ObjectIdentifier(match)) { [weak self] signal in
            guard let self, self.matchmakingAttempt.accepts(token),
                  self.pendingMatch.map(ObjectIdentifier.init) == signal.matchID else { return }
            switch signal {
            case .failed(_, let message): self.failMatchmaking(message)
            case .changed(_, _, let state) where state == GKPlayerConnectionState.disconnected.rawValue:
                self.failMatchmaking("A player disconnected before the match was ready.")
            default: self.finishMatchIfReady(token: token)
            }
        }
        let delegate = GameCenterMatchDelegate { signal in router.deliver(signal) }
        pendingMatchRouter = router
        pendingMatchDelegate = delegate
        match.delegate = delegate
        matchmakingState = .waitingForPlayers
        finishMatchIfReady(token: token)
    }

    private func finishMatchIfReady(token: UUID) {
        guard matchmakingAttempt.accepts(token), let match = pendingMatch,
              match.expectedPlayerCount == 0 else { return }
        do {
            guard requestedRange.contains(match.players.count + 1) else { throw GameCenterError.invalidRoster }
            guard let localPeer, GKLocalPlayer.local.isAuthenticated,
                  GKLocalPlayer.local.gamePlayerID == localPeer.id.rawValue else {
                throw GameCenterError.notAuthenticated
            }
            guard let pendingMatchRouter else { throw GameCenterError.invalidRoster }
            let transport = try GameCenterTransport(match: match, localPeer: localPeer, signalRouter: pendingMatchRouter)
            // The new transport now owns the match delegate and connection.
            retireMatchmaking(disconnectPending: false)
            self.transport = transport
            hostPeerID = transport.hostPeerID
            transport.onDisconnect = { [weak self, weak transport] reason in
                guard let self, let transport, self.transport === transport else { return }
                self.transport = nil
                self.hostPeerID = nil
                self.matchmakingState = reason.map(GameCenterMatchmakingState.failed) ?? .idle
            }
            matchmakingState = .ready
            completeActivityMatch(.success(transport))
        } catch { failMatchmaking(error.localizedDescription) }
    }

    private func failMatchmaking(_ message: String) {
        retireMatchmaking(disconnectPending: true)
        matchmakingState = .failed(message)
        completeActivityMatch(.failure(GameCenterServiceError.gameCenter(message)))
    }

    private func retireMatchmaking(disconnectPending: Bool) {
        matchmakingAttempt.cancel() // Invalidate callbacks before touching GameKit.
        matchmakingController?.matchmakerDelegate = nil
        matchmakingController = nil
        matchmakerDelegate = nil
        if disconnectPending {
            pendingMatchRouter?.retire()
            pendingMatch?.delegate = nil
            pendingMatch?.disconnect()
            GKMatchmaker.shared().cancel()
        }
        pendingMatch = nil
        pendingMatchDelegate = nil
        pendingMatchRouter = nil
    }
}

/// Generation gates are shared by authentication and matchmaking, including
/// callbacks already enqueued when a sheet is dismissed or a retry begins.
struct GameCenterAttempt {
    private var token: UUID?
    var isActive: Bool { token != nil }
    mutating func begin() -> UUID { let next = UUID(); token = next; return next }
    func accepts(_ token: UUID) -> Bool { self.token == token }
    mutating func cancel() { token = nil }
}

private final class GameCenterMatchmakerDelegate: NSObject, GKMatchmakerViewControllerDelegate, Sendable {
    let cancelled: @MainActor @Sendable (ObjectIdentifier) -> Void
    let failed: @MainActor @Sendable (ObjectIdentifier, String) -> Void
    let found: @MainActor @Sendable (ObjectIdentifier, GameCenterCallback<GKMatch>) -> Void

    init(cancelled: @escaping @MainActor @Sendable (ObjectIdentifier) -> Void,
         failed: @escaping @MainActor @Sendable (ObjectIdentifier, String) -> Void,
         found: @escaping @MainActor @Sendable (ObjectIdentifier, GameCenterCallback<GKMatch>) -> Void) {
        self.cancelled = cancelled
        self.failed = failed
        self.found = found
    }

    func matchmakerViewControllerWasCancelled(_ viewController: GKMatchmakerViewController) {
        let id = ObjectIdentifier(viewController), callback = cancelled
        DispatchQueue.main.async { callback(id) }
    }

    func matchmakerViewController(_ viewController: GKMatchmakerViewController, didFailWithError error: any Error) {
        let id = ObjectIdentifier(viewController), callback = failed, message = error.localizedDescription
        DispatchQueue.main.async { callback(id, message) }
    }

    func matchmakerViewController(_ viewController: GKMatchmakerViewController, didFind match: GKMatch) {
        let id = ObjectIdentifier(viewController), callback = found, retained = GameCenterCallback(match)
        DispatchQueue.main.async { callback(id, retained) }
    }
}

private final class GameCenterInviteListener: NSObject, GKLocalPlayerListener, Sendable {
    let receive: @MainActor @Sendable (GameCenterCallback<GKInvite>?, GameCenterCallback<[GKPlayer]>?, String?) -> Void
    init(receive: @escaping @MainActor @Sendable (GameCenterCallback<GKInvite>?, GameCenterCallback<[GKPlayer]>?, String?) -> Void) {
        self.receive = receive
    }

    func player(_ player: GKPlayer, didAccept invite: GKInvite) {
        let retained = GameCenterCallback(invite), callback = receive, name = invite.sender.displayName
        DispatchQueue.main.async { callback(retained, nil, name) }
    }

    func player(_ player: GKPlayer, didRequestMatchWithRecipients recipientPlayers: [GKPlayer]) {
        guard !recipientPlayers.isEmpty else { return }
        let retained = GameCenterCallback(recipientPlayers), callback = receive
        let name = recipientPlayers.first?.displayName
        DispatchQueue.main.async { callback(nil, retained, name) }
    }
}
