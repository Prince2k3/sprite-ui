import ECSCore
import Foundation
@testable import SpriteUIGameCenter
import Testing

@MainActor @Suite struct GameCenterServicesTests {
    @Test func constructionDoesNotSignInOrOpenAFlow() {
        let services = GameCenterServices()
        #expect(!services.isPreview && !services.isAuthenticated)
        #expect(services.localPlayer == nil && services.destination == nil)
        #expect(services.multiplayer.authenticationState == .unauthenticated)
        #expect(services.multiplayer.matchmakingState == .idle)
        #expect(services.networkSession == nil && services.lastError == nil)
    }

    @Test func liveDestinationsRouteThroughSignInWithoutStartingIt() {
        let services = GameCenterServices()
        for destination in [GameCenterDestination.matchmaking, .turnBased, .achievements, .leaderboards, .leaderboard("scores")] {
            services.present(destination)
            #expect(services.destination == .signIn)
            #expect(services.multiplayer.authenticationState == .unauthenticated)
            services.dismiss()
            #expect(services.destination == nil)
        }
        services.present(.setup)
        #expect(services.destination == .setup)
    }

    @Test func previewDestinationsNeverNeedAnAppleAccount() {
        let player = NetworkPeer(id: .init(rawValue: "local-test"), displayName: "Local test")
        let services = GameCenterServices.preview(player: player)
        #expect(services.isPreview && services.isAuthenticated)
        #expect(services.localPlayer == player)
        services.present(.achievements)
        #expect(services.destination == .achievements)
        services.present(.turnBased)
        #expect(services.destination == .turnBased)
        #expect(services.multiplayer.authenticationState == .unauthenticated)
        #expect(throws: GameCenterServiceError.unavailable) { try services.connect(in: World()) }
        services.multiplayer.authenticate()
        #expect(services.multiplayer.authenticationState == .failed("Game Center sign-in is unavailable in local preview mode."))
        #expect(services.isAuthenticated && services.localPlayer == player)
    }

    @Test func pendingConnectionHoldsWorldWeaklyAndDismissReleasesTheFlow() throws {
        let services = GameCenterServices()
        var world: World? = World()
        weak var weakWorld = world
        try services.connect(in: try #require(world))
        #expect(services.destination == .signIn)
        #expect(throws: GameCenterServiceError.operationInProgress) { try services.connect(in: World()) }
        world = nil
        #expect(weakWorld == nil)
        services.dismiss()
        try services.connect(in: World())
        #expect(services.destination == .signIn)
        services.shutdown()
        #expect(services.destination == nil && services.networkSession == nil)
    }

    @Test func invalidRequestsDoNotReserveAPendingConnection() throws {
        let services = GameCenterServices()
        #expect(throws: GameCenterError.self) {
            try services.connect(in: World(), request: .init(minPlayers: 3, maxPlayers: 2))
        }
        #expect(services.destination == nil)
        try services.connect(in: World())
        services.dismiss()
        #expect(throws: GameCenterError.self) {
            try services.presentMatchmaking(.init(minPlayers: 1))
        }
        #expect(services.destination == nil)
    }

    @Test func disconnectRetiresAConnectionQueuedBehindSignIn() throws {
        let services = GameCenterServices()
        try services.connect(in: World())
        #expect(services.destination == .signIn)
        services.disconnect()
        #expect(services.destination == nil)
        services.authenticationDidChange()
        #expect(services.destination == nil)
        try services.connect(in: World())
        #expect(services.destination == .signIn)
    }

    @Test func accountIdentityChangeClearsProgressAndMatchesEvenWithAnAuthenticatedStatus() async throws {
        let services = GameCenterServices.preview()
        services.updateAuthenticatedIdentity(.init(rawValue: "account-a"))
        try await services.achievements.unlock("first-win")
        try await services.leaderboards.submit(score: 20, to: "scores")
        _ = try await services.leaderboards.entries(for: "scores")
        _ = try await services.turnBased.findMatch()
        #expect(!services.achievements.achievements.isEmpty)
        #expect(services.leaderboards.lastResults != nil)
        #expect(services.turnBased.selectedMatch != nil)
        services.updateAuthenticatedIdentity(.init(rawValue: "account-b"))
        #expect(services.achievements.achievements.isEmpty)
        #expect(services.leaderboards.lastResults == nil)
        #expect(services.turnBased.matches.isEmpty && services.turnBased.selectedMatch == nil)
    }

    @Test(arguments: [true, false])
    func attachedSessionDerivesAuthorityAndDisconnectReleasesIt(isHost: Bool) throws {
        let network = InMemoryNetwork()
        let local = NetworkPeer(id: .init(rawValue: "local"), displayName: "Local")
        let other = NetworkPeer(id: .init(rawValue: "other"), displayName: "Other")
        let transport = try network.connect(local)
        _ = try network.connect(other)
        let world = World()
        let actor = Entity(name: "local actor", components: SynchronizationComponent())
        world.addEntity(actor)
        let services = GameCenterServices.preview()
        let session = try services.attachSession(in: world, transport: transport, host: isHost ? local.id : other.id)
        #expect(session.isHost == isHost)
        #expect(services.networkSession === session)
        #expect(throws: GameCenterServiceError.operationInProgress) {
            try services.attachSession(in: world, transport: transport, host: local.id)
        }
        services.disconnect()
        #expect(session.state == .stopped && services.networkSession == nil)
        #expect(transport.onEvent == nil)
        #expect(actor.world === world)
    }

    @Test func noSessionIsConstructedWithoutAReadyMatch() {
        let services = GameCenterServices()
        #expect(throws: GameCenterServiceError.notFound) { try services.startSession(in: World()) }
        #expect(services.networkSession == nil)
    }

    @Test func retiredDashboardCallbackCannotDismissANewerFlow() {
        let services = GameCenterServices.preview()
        services.present(.achievements)
        let old = services.presentationRevision
        services.dismiss()
        services.present(.achievements)
        #expect(services.presentationRevision != old)
        services.finishPresentation(revision: old, error: GameCenterServiceError.unavailable)
        #expect(services.destination == .achievements && services.lastError == nil)
        services.finishPresentation(revision: services.presentationRevision, error: GameCenterServiceError.unavailable)
        #expect(services.destination == nil && services.lastError == .unavailable)
    }

    @Test func shutdownInvalidatesOutstandingContextOperations() throws {
        let context = GameCenterServiceContext(mode: .preview(player: .init(id: .init(rawValue: "player"), displayName: "Player")))
        let operation = try context.begin()
        context.invalidate()
        #expect(throws: GameCenterServiceError.cancelled) { try context.validate(operation) }
        try context.validate(context.begin())
    }

    @Test func serviceIdentifiersRejectEmptyOversizedAndControlValues() {
        for value in ["", "  ", "\n", "score\nboard", String(repeating: "x", count: 257)] {
            #expect(throws: GameCenterServiceError.invalidIdentifier) { try validateGameCenterIdentifier(value) }
        }
    }

    @Test func validApplicationIdentifiersAreAccepted() throws {
        for value in ["first-win", "com.example.scores", "Season 1", "完成"] { try validateGameCenterIdentifier(value) }
    }
}
