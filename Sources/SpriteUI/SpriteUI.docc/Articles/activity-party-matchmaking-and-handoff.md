# Bring an activity party into a game

Two friends have entered the same party code. One has loaded the arena; the other is still downloading it. Starting now would put them in different games. A party lets them meet first, prepare their own worlds, and begin together.

## Keep the lobby alive while screens change

Treat ``SpriteUI/GameCenterServices`` like shared SwiftUI app state. Retain it above both the lobby and the game, with one `.gameCenter(services)` modifier on that stable parent. Moving the modifier with a temporary screen can shut the services down when that screen disappears.

The party is available as `services.party`. ``SpriteUI/GameCenterPartyView`` can show its controls, while your app chooses which game view to present. Configure known activity routes before sign-in so an incoming invitation has somewhere to wait.

This factory registers the arena route. It leaves sign-in to a later player action.

```swift
import SpriteUIGameCenter

@MainActor
func makeArenaServices() throws -> GameCenterServices {
    let services = GameCenterServices()
    try services.activities.configureRoutes(["party-arena"])
    return services
}
```

## Find the friends who share this activity

Load the activity definitions, start the arena activity, then ask its party to find a match. A supplied code joins the matching activity party; omitting a code lets a supporting native definition provide one.

```swift
import SpriteUIGameCenter

@MainActor
func joinArenaParty(using services: GameCenterServices, code: String) async throws {
    _ = try await services.activities.load()
    _ = try await services.activities.start(definitionID: "party-arena", partyCode: code,
                                             properties: ["level": "arena"])
    try await services.party.findMatch()
}
```

For an invitation, check the queued request's level, progression requirements, and content before calling `activities.accept(request:)`. Then call only `party.findMatch()`: starting another activity would abandon the invitation's context.

Live matching uses the same `GKGameActivity` that holds the code and player counts. This keeps the party together through Apple's [activity matchmaking API](https://developer.apple.com/documentation/gamekit/gkgameactivity/findmatch(completionhandler:)). It is a different entry path from generic matchmaking.

The complete roster contains two through eight players. SpriteUI chooses the smallest authenticated peer ID in sorted order as host, after everyone has arrived. That host will own the shared game state.

## Load the arena before saying ready

Each player creates and retains a separate ``SpriteUI/World``. Preparing it tells the party which world and replication schema to use later; it neither starts simulation nor changes the screen. The party holds the world weakly, so your app must keep it alive.

Use a compatibility ID that identifies both the level/content version and the network protocol. A matching string does not check downloaded assets for you. Load and validate them before setting readiness.

These three helpers follow the player's choices: prepare the arena, say ready, and let the host start.

```swift
import ECSCore
import SpriteUIGameCenter

@MainActor
func prepareArena(_ world: World, services: GameCenterServices) throws {
    try services.party.prepare(in: world, compatibilityID: "arena-content-3.protocol-1",
                              schema: NetworkReplicationSchema())
}

@MainActor
func readyArena(using services: GameCenterServices) throws {
    try services.party.setReady(true)
}

@MainActor
func startReadyArena(using services: GameCenterServices) throws {
    guard services.party.canStart else { throw GameCenterServiceError.invalidValue }
    try services.party.startSession()
}
```

The schema must use the same names and formats on every player. Host entities opt into replication with `SynchronizationComponent`; cameras and other local presentation stay local. The default schema sends transforms, so prepare artwork and gameplay services separately. See <doc:game-center-sessions-and-replication> for choosing shared state.

A player can withdraw readiness or prepare a replacement while in the lobby. `canStart` remains false until everyone is ready with matching compatibility IDs and a retained prepared world. If loading uses an asynchronous task, cancel it on leave and recheck the party identity after each wait so an old load cannot prepare a newer lobby.

## Change screens after everyone attaches

The host calls `startSession()`. The party enters `.starting`, clients attach their prepared worlds, and each acknowledges the launch. Only after all acknowledgments does the host commit play.

Wait for `.playing` before presenting gameplay or running the host's game rules. An attached `networkSession` alone is too early. During handoff, keep networking advancing: a running world's installed system handles this, while a headless or paused world needs the app's chosen update path. Update each session only once per frame.

## Try the lobby with two local players

``SpriteUI/GameCenterPartyPreview`` lets two independent services exchange messages in one process. Both must share the retained fixture, activity definition, and code. Advancing its clock delivers messages, including those with zero delay.

This helper creates Alice and Bob and matches them. Keep both worlds in the app, then use the preparation and readiness steps above.

```swift
import ECSCore
import SpriteUIGameCenter

@MainActor
func makePracticeParty() async throws -> (GameCenterServices, GameCenterServices, GameCenterPartyPreview) {
    let alice = NetworkPeer(id: .init(rawValue: "alice"), displayName: "Alice")
    let bob = NetworkPeer(id: .init(rawValue: "bob"), displayName: "Bob")
    let fixture = try GameCenterPartyPreview(players: [alice, bob])
    let a = GameCenterServices.preview(player: alice), b = GameCenterServices.preview(player: bob)
    for services in [a, b] {
        try services.activities.configurePreview([.init(id: "party-arena", title: "Arena", supportsPartyCode: true)])
        try services.party.configurePreview(fixture)
        _ = try await services.activities.load()
        _ = try await services.activities.start(definitionID: "party-arena", partyCode: "1234-5678")
    }
    async let first: Void = a.party.findMatch()
    async let second: Void = b.party.findMatch()
    _ = try await (first, second)
    fixture.advance()
    return (a, b, fixture)
}
```

The showcase's Party matchmaking lab lets Bob choose a different level version so you can see why start is blocked. It also shows a host actor arriving in the separate client world after handoff.

## Limits and leaving

Native activity parties require iOS/macOS 26+, authentication, and a configured party-capable activity with a valid player range. The local fixture works on iOS 18/macOS 15. Signed two-account verification remains pending; fixture results do not establish native invitations or delivery.

The roster stays fixed. A required departure ends the party; there is no automatic retry, reconnection, or host migration. A reserved activity cannot be replaced, finished, or discarded until `leave()`, and ordinary matchmaking/session attachment cannot overlap the party. Handoff has a 15-second timeout. Lobby control packets allow 4,096 encoded bytes; early replication allows 64 packets and 196,608 bytes.

`leave()` stops party replication, disconnects, and releases preparation. It preserves staged scores for your finish/discard choice. Host entities remain; client replicas are removed. Your app stops simulation and chooses the next screen. For resuming a saved round with the original players, read <doc:multiplayer-recovery-and-rejoining>.
