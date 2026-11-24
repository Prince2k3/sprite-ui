# Activity parties and session handoff

Match an activity's party, prepare independent worlds, and commit an explicit transition into entity replication.

## Retain the party with your services

``SpriteUI/GameCenterServices`` owns ``SpriteUI/GameCenterParty`` as `.party`. Use the optional SpriteUIGameCenter product, or the complete SpriteUI product. Native activity matching requires iOS/macOS 26+, authentication, and a configured activity that supports party codes and a valid peer-to-peer player range. Account-free fixtures work on the package's iOS 18/macOS 15 baseline.

Construction, view appearance, and installing `.gameCenter(services)` never authenticate, match, ready a player, or attach a world automatically. Keep one facade and one modifier on a stable application parent that survives the switch from lobby to gameplay. ``SpriteUI/GameCenterPartyView`` provides optional explicit controls; it does not prepare content or choose which game view to show.

Configure activity routes before sign-in. Create or accept a known activity only after checking definition ID, routing properties, progression, and content readiness. An incoming activity stays queued until the game accepts it. The following complete factory configures routing without native work. Present `.signIn` from an application action before using live services.

```swift
import SpriteUIGameCenter

@MainActor
func makeArenaServices() throws -> GameCenterServices {
    let services = GameCenterServices()
    try services.activities.configureRoutes(["party-arena"])
    return services
}
```

## Match the activity, not a separate generic request

For a new party, explicitly load definitions and start an activity using its definition ID. `activities.start(definitionID:partyCode:properties:)` can create or join an application-entered valid code; omitting a custom code allows a supporting native definition to supply one. For an invitation, validate the queued request and call `activities.accept(request:)`. Then explicitly await `party.findMatch()` on each participant.

The live adapter uses the **same GKGameActivity instance** to make its request and find its match. This preserves the native party code, definition player counts, and other matchmaking information. It shares the existing multiplayer coordinator's full-roster waiting, cancellation generations, delegate handoff, transport, and deterministic host election. It does not hash a code into an unrelated `playerGroup`. See Apple's [activity matchmaking API](https://developer.apple.com/documentation/gamekit/gkgameactivity/findmatch(completionhandler:)).

This complete helper starts a configured activity and matches it. It never replaces the caller's world. For an accepted incoming activity, call only `party.findMatch()`; do not create a second activity.

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

A complete party contains two through eight players, including the local player. The fixed roster elects the lexically smallest authenticated peer ID as host, matching SpriteUI's ordinary real-time policy. Pending players cannot form a partial host election. A required departure ends the party; there is no late roster growth, automatic retry, reconnection, or host migration.

The party reserves its activity until `leave()`. Ordinary facade matchmaking/session attachment cannot overlap it. While reserved, activity finish/discard and replacement are rejected. Result staging remains available; leaving itself neither reports nor discards staged scores. Native matching does not start sign-in. Sign-in cancellation and multiplayer restrictions remain explicit failures.

## Prepare first, then advertise readiness

Retain each prepared ``SpriteUI/World`` in the application. `party.prepare(in:compatibilityID:schema:configuration:)` stores a **weak** world reference and the selected replication schema without starting a session or changing the presented game. It resets the local ready flag. The compatibility ID must cover the game's level/content version and network protocol; SpriteUI does not derive a schema fingerprint or verify downloaded assets. Register matching wire names and formats on all peers.

Call `setReady(true)` only after local preparation and validation succeed. Ready state and compatibility IDs are shared with the fixed roster. The host's `canStart` stays false if anyone is unready, has another compatibility ID, or its prepared world was released. A player can withdraw readiness or prepare a replacement while still in the lobby. Readiness is cooperation between authenticated peers, not an anti-cheat authority.

These complete helpers keep preparation, readiness, and the host action separate. The application retains the world and controls its own loading error and retry UI.

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

The prepared world must be free for its new NetworkSession. An occupied world fails without stopping its existing session. If content loading is asynchronous, cancel that application-owned task when leaving and recheck the activity/party identity after each await before calling prepare; a completed old loader must not prepare a newer lobby. Host entities opt into replication through SynchronizationComponent; client-local cameras and artwork remain local. A schema default includes inert transforms, not SpriteComponent visuals, physics, or runtime services. See <doc:game-center-sessions-and-replication> for validation, host command authority, and content setup.

## Commit the handoff

Only the local host can request `startSession()` after all matching ready flags arrive. Its phase becomes `.starting`. Clients attach their prepared worlds and acknowledge the launch; the host sends a play commit only after every member acknowledges. Each phase is observable through ``SpriteUI/GameCenterPartyState``. `services.party.networkSession` and `services.networkSession` expose the attached session; **wait for `.playing` before switching game presentation or running authoritative gameplay rules**.

A party-owned channel keeps lobby control separate from NetworkSession's callback and bounds early replication traffic during handoff. Control packets are limited to 4,096 encoded bytes; early replication is limited to 64 packets and 196,608 bytes. Sender identity comes from the transport, not packet fields. Definition, code, and complete roster must match; only the elected host may launch/commit. Late cancelled matches are disconnected, while duplicate completions cannot disconnect an already-owned native match. A 15-second handoff timeout prevents indefinite partial attachment.

NetworkSession installs its usual world system. Presenting/advancing the prepared world then advances replication. A headless world needs explicit `world.update` or the existing session-update policy. Do not double-update a session already driven by its world. Keep application simulation paused or offscreen until playing; attaching replication is not itself a presentation swap. Lobby changes and matching never mutate the old world.

## Practice with two explicit identities

``SpriteUI/GameCenterPartyPreview`` is a shared, in-process fixed-roster byte fixture. Both facades must receive the same retained fixture and start/accept activities with the same definition and code. It does not access Apple, invent an opponent, or connect across processes. Advance its clock to deliver messages; even zero-latency packets wait for an advance. Use this complete helper with caller-retained worlds, then prepare, ready, and start through the APIs above.

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

The showcase's Party matchmaking lab and <doc:joining-an-activity-party> retain both worlds, pump the fixture, and show a host actor replicated into the client world. They also let Bob advertise a different level version to block start and preserve an independent campaign counter through folding and handoff.

## Leave, fail, and verify deliberately

`party.leave()` cancels pending matchmaking, stops its replication, clears the lobby and weak world, releases the activity reservation, and disconnects the party transport. It retains the activity's staged results for the game's explicit finish/discard policy. `services.disconnect()` also leaves a party; `shutdown()` retires all services. Account changes, an externally ended activity, a stopped/failed session, invalid lobby control, and a required peer departure retire the party. Cancellation is not score rollback or remote delivery confirmation.

Local host entities remain after NetworkSession teardown; client replicas are removed. The app owns restoring gameplay presentation, disabling simulation, releasing prepared content, and choosing whether to restart. A preview clock or native callback can complete later, but retired generations cannot replace a newer party. Do not automatically retry native matchmaking or attempts.

Native verification remains separate: configure signed resources and two accounts; test sharing/entering one party code, cold/warm invitation routing, full-roster waiting, matching compatibility, cancelling and retrying, readiness withdrawal, the host commit, remote replication, disconnect, account change, and lower-OS availability. Account-free fixture success does not establish native invites, network quality, entitlement configuration, or cross-device delivery.

For explicit checkpoint recovery, background interruption, fresh same-roster matches, and client-baseline acknowledgment, continue with <doc:multiplayer-recovery-and-rejoining>. Recovery remains application-approved and does not enable host migration.
