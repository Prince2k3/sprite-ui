import ECSCore
import Foundation
import GameKit
@testable import SpriteUIGameCenter
import Testing

@Suite struct GameCenterRequestTests {
    @Test func defaultRequestIsTwoPlayers() throws {
        let request = GameCenterMatchRequest()
        #expect(request.minPlayers == 2)
        #expect(request.maxPlayers == 2)
        #expect(request.playerGroup == 0)
        try request.validate(maximumPlayers: 16)
    }

    @Test func requestsRejectInvalidBoundsBeforeCallingGameKit() throws {
        for request in [
            GameCenterMatchRequest(minPlayers: 1),
            GameCenterMatchRequest(minPlayers: -1),
            GameCenterMatchRequest(minPlayers: 3, maxPlayers: 2),
            GameCenterMatchRequest(maxPlayers: 17),
            GameCenterMatchRequest(maxPlayers: Int.max),
            GameCenterMatchRequest(playerGroup: -1),
        ] {
            #expect(throws: GameCenterError.self) { try request.validate(maximumPlayers: 16) }
        }
        try GameCenterMatchRequest(minPlayers: 2, maxPlayers: 16, playerGroup: Int.max).validate(maximumPlayers: 16)
    }

    @Test func cancelledOrReplacedAttemptsRejectLateCallbacks() {
        var attempt = GameCenterAttempt()
        #expect(!attempt.isActive)
        let first = attempt.begin()
        #expect(attempt.accepts(first))
        attempt.cancel()
        #expect(!attempt.accepts(first))
        let second = attempt.begin()
        #expect(!attempt.accepts(first))
        #expect(attempt.accepts(second))
        let third = attempt.begin()
        #expect(!attempt.accepts(second))
        #expect(attempt.accepts(third))
        attempt.cancel()
        attempt.cancel()
        #expect(!attempt.isActive)
    }

    @Test func allPeersElectTheSameHostRegardlessOfRosterOrder() throws {
        let ids = ["c", "a", "b"].map { NetworkPeerID(rawValue: $0) }
        for local in ids {
            for remotes in [ids.filter { $0 != local }, ids.filter { $0 != local }.reversed().map { $0 }] {
                let host = try GameCenterRoster.host(localID: local, remoteIDs: remotes, expectedPlayerCount: 0)
                #expect(host.rawValue == "a")
            }
        }
    }

    @Test func noHostCanBePublishedForAnIncompleteOrInvalidRoster() {
        let local = NetworkPeerID(rawValue: "local"), remote = NetworkPeerID(rawValue: "remote")
        #expect(throws: GameCenterError.incompleteRoster) {
            try GameCenterRoster.host(localID: local, remoteIDs: [remote], expectedPlayerCount: 1)
        }
        for remotes in [[], [local], [remote, remote], [NetworkPeerID(rawValue: "")]] {
            #expect(throws: GameCenterError.invalidRoster) {
                try GameCenterRoster.host(localID: local, remoteIDs: remotes, expectedPlayerCount: 0)
            }
        }
        #expect(throws: GameCenterError.invalidRoster) {
            try GameCenterRoster.host(localID: NetworkPeerID(rawValue: ""), remoteIDs: [remote], expectedPlayerCount: 0)
        }
    }
}

@MainActor @Suite struct GameCenterTests {
    @Test func queuedTerminalCallbacksFollowTheMatchAfterItsPendingGenerationIsRetired() {
        let match = NSObject(), otherMatch = NSObject()
        let matchID = ObjectIdentifier(match)
        let peer = NetworkPeerID(rawValue: "host")
        let terminalSignals: [GameCenterMatchSignal] = [
            .failed(matchID, "Queued failure"),
            .changed(matchID, peer, GKPlayerConnectionState.disconnected.rawValue),
        ]
        for terminal in terminalSignals {
            var attempt = GameCenterAttempt()
            let token = attempt.begin()
            var pendingDeliveries = 0
            var transportConnected = true
            var transportDeliveries = 0
            let router = GameCenterMatchSignalRouter(matchID: matchID) { _ in
                if attempt.accepts(token) { pendingDeliveries += 1 }
            }
            // This is the callback captured by the old delegate's queued work.
            // It must choose the new receiver at delivery, not at enqueue time.
            let queuedPendingCallback: (GameCenterMatchSignal) -> Void = { router.deliver($0) }
            queuedPendingCallback(.changed(matchID, peer, GKPlayerConnectionState.connected.rawValue))
            #expect(pendingDeliveries == 1)
            router.handOff { signal in
                transportDeliveries += 1
                switch signal {
                case .failed: transportConnected = false
                case .changed(_, _, let state) where state == GKPlayerConnectionState.disconnected.rawValue:
                    transportConnected = false
                default: break
                }
            }
            attempt.cancel() // Models retireMatchmaking during publication.
            queuedPendingCallback(.failed(ObjectIdentifier(otherMatch), "Unrelated match"))
            #expect(transportConnected)
            #expect(transportDeliveries == 0)
            queuedPendingCallback(terminal)
            #expect(!transportConnected)
            #expect(transportDeliveries == 1)
            #expect(pendingDeliveries == 1)
        }
    }

    @Test func cancelledOrReplacedMatchRoutersCannotDeliverOrBeRevived() {
        let match = NSObject(), matchID = ObjectIdentifier(match)
        var oldDeliveries = 0
        var replacementDeliveries = 0
        let old = GameCenterMatchSignalRouter(matchID: matchID) { _ in oldDeliveries += 1 }
        let queuedOldCallback: (GameCenterMatchSignal) -> Void = { old.deliver($0) }
        old.retire()
        old.retire()
        old.handOff { _ in replacementDeliveries += 1 }
        // Even reusing the same SDK identity cannot route old queued work into
        // a new generation: replacement matches own distinct router instances.
        let replacement = GameCenterMatchSignalRouter(matchID: matchID) { _ in replacementDeliveries += 1 }
        queuedOldCallback(.failed(matchID, "Retired failure"))
        queuedOldCallback(.changed(matchID, NetworkPeerID(rawValue: "host"), GKPlayerConnectionState.disconnected.rawValue))
        #expect(oldDeliveries == 0)
        #expect(replacementDeliveries == 0)
        replacement.deliver(.failed(matchID, "Current failure"))
        #expect(replacementDeliveries == 1)
        replacement.retire()
        replacement.deliver(.failed(matchID, "Already disconnected"))
        #expect(replacementDeliveries == 1)
    }

    @Test func nativeRequestConstructionDoesNotInstallAuthentication() throws {
        let request = try GameCenterMatchRequest(minPlayers: 2, maxPlayers: 4, playerGroup: 42).nativeRequest()
        #expect(request.minPlayers == 2)
        #expect(request.maxPlayers == 4)
        #expect(request.defaultNumberOfPlayers == 4)
        #expect(request.playerGroup == 42)
    }

    @Test func authenticationCancellationRejectsLatePresentationAndErrorsAcrossRetry() throws {
        let driver = AuthenticationFixture()
        let multiplayer = GameCenterMultiplayer(authenticationDriver: driver.driver)
        multiplayer.authenticate()
        let oldCallback = try #require(driver.callback)
        #expect(multiplayer.authenticationState == .authenticating)
        multiplayer.cancelAuthentication()
        #expect(driver.cancellations == 1)
        oldCallback(GameCenterCallback(GameCenterAuthenticationController()), nil)
        oldCallback(nil, "Late failure")
        #expect(multiplayer.authenticationState == .unauthenticated)
        #expect(multiplayer.authenticationController == nil)

        multiplayer.authenticate()
        let currentCallback = try #require(driver.callback)
        oldCallback(nil, "Failure from previous attempt")
        #expect(multiplayer.authenticationState == .authenticating)
        currentCallback(GameCenterCallback(GameCenterAuthenticationController()), nil)
        #expect(multiplayer.authenticationController != nil)
        multiplayer.cancelAuthentication()
        currentCallback(nil, "Failure after dismissal")
        #expect(multiplayer.authenticationState == .unauthenticated)
        #expect(multiplayer.authenticationController == nil)
        multiplayer.shutdown()
    }

    @Test func droppingCoordinatorReleasesOnlyItsAuthenticationOwnership() {
        let old = AuthenticationFixture(), replacement = AuthenticationFixture()
        var multiplayer: GameCenterMultiplayer? = GameCenterMultiplayer(authenticationDriver: old.driver)
        multiplayer?.authenticate()
        weak var weakMultiplayer = multiplayer
        multiplayer = nil
        #expect(weakMultiplayer == nil)
        #expect(old.cancellations == 1)
        let next = GameCenterMultiplayer(authenticationDriver: replacement.driver)
        next.authenticate()
        #expect(next.authenticationState == .authenticating)
        next.shutdown()
        #expect(replacement.cancellations == 1)
    }

    @Test func oldCoordinatorCleanupCannotClearANewerAuthenticationHandler() {
        let old = AuthenticationFixture(), replacement = AuthenticationFixture()
        var previous: GameCenterMultiplayer? = GameCenterMultiplayer(authenticationDriver: old.driver)
        previous?.authenticate()
        previous?.cancelAuthentication()
        let current = GameCenterMultiplayer(authenticationDriver: replacement.driver)
        current.authenticate()
        previous = nil
        #expect(old.cancellations == 1)
        #expect(replacement.cancellations == 0)
        #expect(current.authenticationState == .authenticating)
        current.shutdown()
        #expect(replacement.cancellations == 1)
    }

    @Test func coordinatorConstructionAndCancellationDoNotStartAuthenticationOrMatchmaking() {
        let multiplayer = GameCenterMultiplayer()
        #expect(multiplayer.authenticationState == .unauthenticated)
        #expect(multiplayer.matchmakingState == .idle)
        #expect(multiplayer.transport == nil)
        #expect(multiplayer.hostPeerID == nil)
        #expect(multiplayer.localPeer == nil)
        #expect(!multiplayer.hasPendingInvite)
        multiplayer.cancelAuthentication()
        multiplayer.cancelMatchmaking()
        multiplayer.disconnect()
        multiplayer.declinePendingInvite()
        #expect(multiplayer.authenticationController == nil)
        #expect(multiplayer.matchmakingController == nil)
        #expect(multiplayer.matchmakingState == .idle)
    }

    @Test func reliableAndUnreliableLimitsAreInclusive() throws {
        try GameCenterTransport.validatePayloadSize(48_000, reliably: true)
        try GameCenterTransport.validatePayloadSize(1_000, reliably: false)
        try GameCenterTransport.validatePayloadSize(0, reliably: true)
        #expect(throws: GameCenterError.payloadTooLarge(limit: 48_000)) {
            try GameCenterTransport.validatePayloadSize(48_001, reliably: true)
        }
        #expect(throws: GameCenterError.payloadTooLarge(limit: 1_000)) {
            try GameCenterTransport.validatePayloadSize(1_001, reliably: false)
        }
    }
}

@MainActor
private final class AuthenticationFixture {
    var callback: GameCenterAuthenticationDriver.Handler?
    var cancellations = 0
    var driver: GameCenterAuthenticationDriver {
        GameCenterAuthenticationDriver(start: { [weak self] in self?.callback = $0 },
                                       cancel: { [weak self] in self?.cancellations += 1 })
    }
}
