# Add scores, achievements, and turns to a game

A player finishes an arena with 120 points. You want to record progress toward an achievement, show a score table, and perhaps let a friend take the next turn. Start with local versions of these actions so the game flow is clear before adding sign-in and native screens.

## Share services across your SwiftUI screens

``SpriteUI/GameCenterServices`` groups the Game Center features behind one retained object. Store it on a stable parent and install `.gameCenter(services)` once there. Descendants can read it from the environment and ask that shared host to present a screen.

This menu uses `.preview()`, so it needs no Apple account. The button demonstrates how a child view opens achievements without owning another services object.

```swift
import SpriteUI
import SwiftUI

@MainActor
struct BasicServicesMenu: View {
    @State private var services = GameCenterServices.preview()

    var body: some View {
        VStack(spacing: 16) {
            GameCenterServicesView(services: services)
            ServiceShortcuts()
        }
        .padding()
        .gameCenter(services)
    }
}

@MainActor
private struct ServiceShortcuts: View {
    @Environment(\.gameCenterServices) private var services

    var body: some View {
        Button("Show achievements") { services?.present(.achievements) }
    }
}
```

For live use, construct `GameCenterServices(mode: .live)`. Showing a view or installing the modifier does not sign in or find a match. A player action opens `.signIn`, `.achievements`, `.leaderboards`, `.leaderboard(identifier)`, `.turnBased`, or `.matchmaking`; an account-dependent live destination first routes through sign-in when needed.

The modifier shuts down services when its parent disappears. Keep that parent above menu-to-game transitions. `dismiss()` closes presentation while retaining a ready real-time match; `disconnect()` ends that match and its replication session. `shutdown()` also retires pending work and listeners, without signing the person out of their system account.

## Record progress and show the score

Achievements measure progress from 0 through 100 percent. Load existing progress before reporting when you need to avoid repeating a completion. Known progress only increases; the native dashboard supplies descriptions for achievements the player has not started.

Leaderboard scores are separate reports. Submit the round result, then load entries to refresh the display. Here, the preview keeps 120 as the best score after a later 80-point result.

```swift
import SpriteUI

@MainActor
func recordPracticeResult(using services: GameCenterServices) async throws -> GameCenterLeaderboardResults {
    _ = try await services.achievements.load()
    try await services.achievements.report(progress: 25, for: "first-steps")
    try await services.leaderboards.submit(score: 120, to: "practice-score")
    try await services.leaderboards.submit(score: 80, to: "practice-score")
    return try await services.leaderboards.entries(for: "practice-score", range: 1...10)
}
```

Replace `first-steps` and `practice-score` with configured identifiers for live use. Call the helper from an app task and show any error. Preview data lasts only as long as the service instance; its rank 1 is a local result, not a comparison with other players. Live ordering and score formatting come from the leaderboard configuration. Entry ranges are one-based and allow at most 100 results per request.

## Pass a small game state to the next player

A turn-based game needs enough saved data for the next player to continue. Define a narrow `Codable` value and give its format a positive version number. A newly created match has empty data, so save its initial state before trying to decode it.

`save` keeps the current turn. `endTurn` saves and names the next participant slots in fallback order. `finish` records a terminal outcome for every slot. Participant slots are positions in the match, including legal pending slots; they are not player IDs.

This example gives two local identities the same ``SpriteUI/InMemoryTurnBasedStore``. The first saves and passes, the second reloads and reads the total, then finishes the cooperative round as a tie.

```swift
import SpriteUI

struct PracticeTurn: Codable {
    var total: Int
}

@MainActor
func exerciseLocalTurns() async throws -> PracticeTurn {
    let a = NetworkPeer(id: .init(rawValue: "preview-a"), displayName: "Player A")
    let b = NetworkPeer(id: .init(rawValue: "preview-b"), displayName: "Player B")
    let store = InMemoryTurnBasedStore()
    let first = GameCenterTurnBasedMatches(mode: .preview(player: a), previewStore: store)
    let second = GameCenterTurnBasedMatches(mode: .preview(player: b), previewStore: store)
    let id = try store.createMatch(participants: [a, b])
    let fresh = try await first.load(id: id)
    let saved = try await first.save(PracticeTurn(total: 1), in: fresh, version: 1)
    _ = try await first.endTurn(PracticeTurn(total: 1), in: saved,
        nextParticipantSlots: [1], version: 1)
    let received = try await second.load(id: id)
    let value = try second.state(of: received, as: PracticeTurn.self, version: 1)
    guard value.total >= 0 else { throw GameCenterServiceError.invalidData }
    _ = try await second.finish(value, in: received, outcomes: [0: .tied, 1: .tied], version: 1)
    return value
}
```

Reload before submitting, use `localCanAct` to enable controls, and validate decoded values against the game rules. Preserve outcomes that are already terminal. When forfeiting in turn, supply the next slots; forfeiting out of turn preserves the payload.

The shared store makes this exercise possible without accounts. Separate preview facades otherwise have separate stores, and preview matchmaking leaves opponent slots pending. Live [turn-based matches](https://developer.apple.com/documentation/gamekit/starting-turn-based-matches-and-passing-turns-between-players) persist application data between players; they do not run an ECS simulation or restore a `WorldSnapshot`.

## Connect a world when players act together

For a real-time game, supply the world and replication schema as well as a match request. `connect` drives sign-in and matchmaking, waits for the complete roster, and attaches a session. Retain the world while this is pending because the services hold it weakly.

If you already have a ready match, `startSession` attaches it directly. These helpers show the two entry points.

```swift
import SpriteUI

@MainActor
func requestNativeMatch(services: GameCenterServices, world: World,
                        schema: NetworkReplicationSchema) throws {
    try services.connect(in: world, schema: schema, request: GameCenterMatchRequest())
}

@MainActor
func attachReadyNativeMatch(services: GameCenterServices, world: World,
                            schema: NetworkReplicationSchema) throws -> NetworkSession {
    try services.startSession(in: world, schema: schema)
}
```

The built-in Real-time match button only finds a match: it has no world or schema to attach. Preview services reject the native `connect` path; use `InMemoryNetwork` for local replication. Read <doc:game-center-sessions-and-replication> before choosing the shared state and host rules.

## Handle a failed report or stale turn

Direct service calls throw ``SpriteUI/GameCenterServiceError``. Catch those errors in the task that made the call. The facade's `lastError` covers its presentation and connection flow, rather than collecting every direct operation's failure.

Serialize operations on each service and reload after account changes or a stale turn. Turn revisions detect changes seen during the native preflight reload, but GameKit provides no atomic compare-and-swap guarantee against another device writing afterward.

Cancellation retires local work; a server write may already have completed. Reload before deciding to retry. Achievement, score, and turn updates are separate operations, with no shared transaction or automatic retry queue.

## Native setup and remaining checks

Enable Game Center in the consuming target, link GameKit, and use matching bundle ID, signing, and provisioning. Sandboxed macOS apps need incoming and outgoing networking. Configure achievements, leaderboards, app-version enablement, and [multiplayer compatibility](https://developer.apple.com/help/app-store-connect/configure-game-center/add-multiplayer-compatibility) in App Store Connect. Apple's [configuration guide](https://developer.apple.com/documentation/gamekit/initializing-and-configuring-game-center) also describes Xcode's local testing on supported physical devices. Activities and challenges require iOS/macOS 26+.

The repository's setup checker can inspect a built app:

```sh
python3 Tools/check-game-center-setup.py /path/to/MyGame.app --bundle-id com.example.MyGame --json
```

It checks local metadata and entitlements, not remote configuration or live behavior. Signing templates and App Store Connect setup commands are documented in `Tools/game-center-connect.md`; creating draft challenge metadata does not grant Apple's required approval.

Signed two-account/two-device verification remains **pending**. Check sign-in cancellation and account changes, report/reload scores and achievements, pass and reopen a turn on the other account, confirm persistence after relaunch, then connect and disconnect a real-time world. Previews and compilation cannot establish those results.

Continue with <doc:quests-and-leagues> to turn gameplay into lasting goals, or <doc:game-center-activities-and-challenges> to let an invitation lead into a round.
