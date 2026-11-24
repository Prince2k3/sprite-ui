# Basic Game Center services

Start with local achievement progress, scores, and saved turns, then opt into native Game Center screens when your app is configured.

## Retain one services object

``SpriteUI/GameCenterServices`` groups `.multiplayer`, `.achievements`, `.leaderboards`, and `.turnBased`. Keep one instance in SwiftUI state and install `.gameCenter(services)` once on a stable parent. The modifier supplies `EnvironmentValues.gameCenterServices`, one sheet host, and authentication/matchmaking state handling. ``SpriteUI/GameCenterServicesView`` supplies entry buttons and setup help; descendants can instead call `present(_:)` with a ``SpriteUI/GameCenterDestination``.

This complete menu uses an account-free preview. Replace `.preview()` with `GameCenterServices(mode: .live)` when you deliberately want native services. You can also construct `GameCenterServices(mode: .preview(player: player))` with an explicit ``SpriteUI/NetworkPeer``. Construction, installing the modifier, and displaying the menu never start authentication or matchmaking.

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

Available destinations are `.signIn`, `.matchmaking`, `.turnBased`, `.achievements`, `.leaderboards`, `.leaderboard(identifier)`, and `.setup`. A live account-dependent destination first routes through explicit sign-in when needed, then continues to the requested screen. The sign-in and match-finding controls still require a user action. Preview destinations explain local behavior or expose the local turn inbox; they never authenticate with Apple.

`dismiss()` cancels pending presentation work while retaining a ready real-time match. `disconnect()` stops the retained replication session and releases the real-time match. `shutdown()` also invalidates pending service results, clears local caches, and releases listeners; it never signs the person out of their system account. The modifier calls `shutdown()` when its parent disappears, so choose a parent whose lifetime matches the services. Do not put a separate modifier on every button or sheet.

## Report achievement progress and scores

``SpriteUI/GameCenterAchievements`` loads started/completed progress with `load()`, reports a finite percentage in `0...100` with `report(progress:for:)`, and completes one achievement with `unlock(_:)`. Its `achievements` values are inert snapshots. Known progress cannot decrease; an equal or lower report succeeds without another write. Load first when you need existing server progress to suppress repeated completion reports. The native dashboard supplies descriptions of achievements that have no progress yet.

``SpriteUI/GameCenterLeaderboards`` submits scores with `submit(score:to:context:)` and loads global, all-time results with `entries(for:range:)`. Ranks are one-based; request at most 100 entries at a time. Submission invalidates `lastResults`, so load again to display a fresh result. Live score ordering and formatting come from the configured leaderboard.

This complete helper takes the caller's retained facade and returns values suitable for a view. The identifiers are local tutorial labels; substitute configured identifiers before calling it with live services. Call from a user-initiated task and display any thrown error.

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

In preview mode this records 25% progress and retains the highest local score, 120, at rank 1. Before any submission, a preview leaderboard is empty. Preview achievement and score data belong to that service instance's memory and disappear when it is discarded or reset. Rank 1 is a local fixture, not a league placement or a comparison with other players.

## Save typed, versioned turn state

``SpriteUI/GameCenterTurnBasedMatches`` provides `list()`, `load(id:)`, `findMatch(_:)`, `state(of:as:version:)`, `save(_:in:version:)`, `endTurn(_:in:nextParticipantSlots:version:)`, `finish(_:in:outcomes:version:)`, and `forfeit(_:nextParticipantSlots:)`. Operations and `start()` can register native event listeners but never initiate authentication. The built-in turn-based screen offers explicit refresh, saved-game selection, matchmaking, and Done controls; opening it does not perform work automatically.

Each ``SpriteUI/GameCenterTurnBasedMatch`` is an inert snapshot with participants, current turn, data, revision, and maximum data size. Use `localCanAct` for controls, and reload before submitting. `save` preserves the current turn; `endTurn` supplies ordered fallback participant **slots**, including legal pending slots; `finish` supplies a terminal outcome for every slot. Keep existing terminal outcomes. `forfeit` needs next slots when leaving in turn; leaving out of turn preserves the payload.

Encode a narrow `Codable` application value and choose a positive schema version. Empty newly created match data needs an initial save before decoding. Wrong versions, foreign/corrupt data, and oversized payloads are rejected. The encoded envelope also counts toward `maximumDataSize`. Validate decoded values against your game rules. A revision check detects a change observed by the native preflight reload; GameKit has no atomic compare-and-swap guarantee against a second device writing afterward.

The following complete helper shares one explicit ``SpriteUI/InMemoryTurnBasedStore`` between two known preview identities. It saves without passing, reloads as the next player, and finishes a cooperative practice game tied. A standalone preview `findMatch` instead creates pending opponent slots; it does not invent a second signed-in player.

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

The store has no singleton, disk persistence, server connection, or automatic synchronization; reload explicitly. Separate preview facades each have their own turn store. Use separate turn services with the same supplied store when you need this two-identity experiment. Apple-hosted turn-based matches persist encoded application state asynchronously between participants. They do not restore an ECS ``SpriteUI/WorldSnapshot`` or provide lockstep simulation. See Apple's [turn-based match and turn-passing guide](https://developer.apple.com/documentation/gamekit/starting-turn-based-matches-and-passing-turns-between-players).

## Attach an optional real-time match

Use `connect(in:schema:request:)` from an explicit app action after installing the modifier. It drives sign-in and matchmaking, waits for the ready roster, selects host/client authority, and retains the resulting ``SpriteUI/NetworkSession`` in `networkSession`. Keep the world alive while the flow is pending; the facade holds it weakly. Preview mode rejects this native connection path; use ``SpriteUI/InMemoryNetwork`` for offline replication.

`startSession(in:schema:configuration:)` is the lower-level helper for an **already-ready** match. It does not start the sign-in/matchfinding flow. The following complete helpers show the two entry points; the caller handles errors and retains the facade and world.

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

`present(.matchmaking)` and the built-in Real-time match button present matchmaking only; they have no world/schema to attach. Use `connect` for automatic session attachment or call `startSession` after readiness yourself. See <doc:game-center-sessions-and-replication> for schemas, host-authoritative commands, fixed-roster limitations, update ownership, and teardown.

## Handle failure without assuming rollback

Direct asynchronous operations throw ``SpriteUI/GameCenterServiceError``. Display failures, keep each service's operations serialized, and explicitly reload after stale match or account changes. The facade's `lastError` covers its presentation/connection flow; it is not an automatic collector for every direct service call. Turn-based services additionally expose `lastError`.

Reported errors are not automatically placed in an offline retry queue. Cancelling a task retires local results, but an Apple server write may already have committed before cancellation or a later error is reported. Reload authoritative state before deciding whether to retry; cancellation is not a server rollback. Achievement, leaderboard, and turn state remain separate operations rather than one transaction.

## Configure and verify the native path

Enable Game Center under the consuming target's Signing & Capabilities and use matching signing/provisioning and bundle ID. Link GameKit. For sandboxed macOS targets, enable incoming and outgoing network connections. The repository's `Tools/templates/game-center-ios.entitlements` and `Tools/templates/game-center-macos.entitlements` are starting points; they do not configure an Apple account. See Apple's [capability and entitlement guidance](https://developer.apple.com/help/account/reference/capability-entitlement-updates/).

Create matching achievements and leaderboards in App Store Connect, enable Game Center for the app version, and review [multiplayer compatibility](https://developer.apple.com/help/app-store-connect/configure-game-center/add-multiplayer-compatibility). Local testing can use a GameKit configuration in Xcode and Game Progress Manager; it requires a physical device on supported system versions. This Xcode testing path is separate from SpriteUI's in-memory previews. Follow Apple's [Game Center configuration and local testing guide](https://developer.apple.com/documentation/gamekit/initializing-and-configuring-game-center).

Inspect a built `.app` from the repository root:

```sh
python3 Tools/check-game-center-setup.py /path/to/MyGame.app --bundle-id com.example.MyGame --json
```

The checker reads local bundle metadata and entitlements extracted from the built app's signing data. It does not validate signature authenticity, remote provisioning state, App Store Connect configuration, or live service behavior. With `--entitlements FILE`, it checks a supplied plist instead, explicitly unverified against the signed bundle. A successful local report still leaves remote setup for manual review.

Signed two-account/two-device native verification remains **pending**. On configured builds, check explicit sign-in/cancellation and account changes; report/reload configured achievements and scores; find, save, pass, reload on the other account, finish, and revisit a turn-based match; then connect a real-time world and disconnect. Confirm persisted turn state after relaunch. Local previews and compilation do not establish these native results.

Follow <doc:starting-with-game-center-services> for three complete, asset-free stages. Build custom progression on top with <doc:quests-and-leagues>. Native social challenges are separate from these local quest and league rules.
