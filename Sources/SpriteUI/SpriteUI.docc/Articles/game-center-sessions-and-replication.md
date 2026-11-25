# Game Center sessions and replication

Build small host-authoritative matches with explicit wire schemas, validated commands, and an account-free offline transport.

## Choose authority before starting a session

``SpriteUI/NetworkSession`` synchronizes selected entity state from one host. Only that host creates, removes, reparents, or changes authoritative replicated entities. A client's ``SpriteUI/SynchronizationComponent/owner`` associates commands with a player; ownership does not grant remote write access. Run authoritative gameplay and native physics on the host. Clients submit intent and present the latest validated host state. For immediate local kinematic response, opt into <doc:multiplayer-prediction-and-reconciliation>: it moves a separate local visual, acknowledges host-simulated inputs, and replays only pending input. Native SpriteKit physics remains host-authoritative.

Game Center is the native transport path on iOS 18 and macOS 15. ``SpriteUI/GameCenterMultiplayer`` waits for the complete initial match roster, including `expectedPlayerCount == 0`. It selects the smallest sorted full-roster Game Center `gamePlayerID` as a fixed `hostPeerID`. Compare the transport's local ID with that value to choose `.host` or `.client(host:)`. Do not elect from a partial roster, display names, or local entity IDs. A host departure ends the match; there is no automatic host migration.

The native match has a fixed initial roster. Midmatch player additions and native reinvites are unsupported. A “late join baseline” means starting a replication session late on an **already connected** Game Center participant. It does not mean seamless Game Center matchmaking into an active match. The offline hub additionally supports connecting a physically new peer.

## Allow only portable value data

``SpriteUI/NetworkReplicationSchema`` is an explicit allowlist, separate from ``SpriteUI/ComponentRegistry`` and saved-world registration. `Transform` is included under the stable name `transform`, with finite-value validation. Register identical names, encodings, and validators on every peer before starting. Mark each host entity with ``SpriteUI/SynchronizationComponent`` and select the registered names that it may send. An unselected component stays local; a selected but absent component is removed from its replica.

Register only inert `Component & Codable` values. Do not register components holding local `Entity.ID`s, `EntityReferencingComponent` implementations, native physics bodies or joints, resources, cameras, input controllers, runtime services, or behavior systems. Codable conformance alone does not make a component safe. The schema rejects referencing-component types and the synchronization marker itself; applications must enforce the rest of this boundary.

This complete example defines a validated value and creates one detached synchronized actor. Attach it directly to `world.root` with `world.addEntity`, or under another synchronized entity. Every replicated ancestor must be synchronized; an unsynchronized grouping parent is invalid.

```swift
import Foundation
import SpriteUI

struct MatchStats: Component, Codable {
    var score: Int
    var target: NetworkEntityID?
}

@MainActor
func makeMatchSchema() throws -> NetworkReplicationSchema {
    var schema = NetworkReplicationSchema()
    try schema.register(MatchStats.self, named: "match-stats-v1") { stats in
        guard (0...999).contains(stats.score) else { throw NetworkSessionError.invalidState }
    }
    return schema
}

@MainActor
func makeMatchActor(owner: NetworkPeerID) -> Entity {
    Entity(name: "Player", components:
        MatchStats(score: 0, target: nil),
        SynchronizationComponent(owner: owner, components: ["transform", "match-stats-v1"]))
}
```

``SpriteUI/NetworkEntityID`` wraps a globally unique network UUID. Each replica has its own unrelated local entity ID. Send `NetworkEntityID` in commands and cross-entity data such as `MatchStats.target`; resolve it through `session.entity(withNetworkID:)`. The session validates its structural parent references, but custom reference semantics and target existence remain application rules. Cloning a synchronization marker produces a fresh network identity. Persisted identities require deliberate application policy when starting a new match.

## Authenticate and present matchmaking explicitly

Retain one main-actor coordinator per app. Present ``SpriteUI/GameCenterAuthenticationView`` in a SwiftUI sheet. Its Sign In button starts authentication. Once authenticated, present ``SpriteUI/GameCenterMatchmakingView``; Find Match and Accept Invitation are explicit actions. Construction and appearance do not authenticate or start matchmaking. Invites are pending until accepted or declined. Cancellation and late native callbacks belong to the coordinator.

Observe `matchmakingState`. When it becomes `.ready`, dismiss the matchmaking sheet and create the replication session from `transport` and `hostPeerID`. The coordinator owns the match transport; your app owns and retains its session, world, and event subscriptions. Dismissing a ready sheet leaves the transport connected. Do not replace the transport's `onEvent` while a session owns it.

This complete helper starts a session only when the coordinator has published its fixed roster and role. The caller retains the returned session and supplies the same schema on every participant.

```swift
import SpriteUI

@MainActor
func startReadySession(world: World, multiplayer: GameCenterMultiplayer,
                       schema: NetworkReplicationSchema) throws -> NetworkSession {
    guard multiplayer.matchmakingState == .ready,
          let transport = multiplayer.transport,
          let hostID = multiplayer.hostPeerID else { throw NetworkSessionError.notConnected }
    let role: NetworkSession.Role = transport.localPeer.id == hostID ? .host : .client(host: hostID)
    let session = NetworkSession(world: world, transport: transport, role: role, schema: schema)
    try session.start()
    return session
}
```

Enable the consuming app's Game Center capability, link GameKit, and sign with the `com.apple.developer.game-center` entitlement and matching provisioning. Configure the same bundle ID, an enabled Game Center app version, and multiplayer compatibility in App Store Connect. A sandboxed macOS app also needs appropriate incoming and outgoing network permissions. See Apple's [Game Center setup overview](https://developer.apple.com/help/app-store-connect/configure-game-center/overview-of-game-center) and [multiplayer compatibility instructions](https://developer.apple.com/help/app-store-connect/configure-game-center/add-multiplayer-compatibility). These are app configuration steps; importing SpriteUI does not configure them. This integration does not request friends-list access.

## Validate client commands on the host

A connected client uses `sendCommand(_:)` to send bounded, ordered reliable application data. Subscribe to ``SpriteUI/NetworkEvents/CommandReceived`` on the host world and retain the subscription. The transport supplies the authenticated sender; a claimed player ID in the body is never authority.

Before changing state, decode a narrow command format and validate its byte size, allowed action and numeric range, network target, sender ownership, rate budget, and current game rules. Reject unknown targets and unauthorized, malformed, excessive, or impossible actions. Never accept arbitrary component patches. The tutorial admits one bounded move per host update and checks arena limits. A live game needs a per-peer budget based on its own clock and gameplay policy.

## Join with a complete validated baseline

Clients accept an initial baseline only from the configured match host. Join IDs bind replies to a particular start attempt; session IDs distinguish host incarnations; sequences reject stale frames. Callback generations prevent retired work from affecting a restarted session. These guards do not provide automatic reconnection: stop the old session and establish the desired new lifetime explicitly.

Before mutating replicas, the receiver validates the complete frame: size and count limits, unique network IDs, selected schema names, decoded values and validators, and a bounded, acyclic parent graph with all parents present. Protocol/schema validation completes before application begins; this is not a general transaction guarantee for arbitrary application event handlers. Local cameras and services created independently on the client remain intact. Keep local-only entities outside replicated subtrees so removing a replica cannot remove its local descendants.

Default updates contain the **full selected state**, not an incremental patch that depends on a previous unreliable frame. Baselines, spawning, despawning, names, parenting, ownership, selections, non-transform values, and transform presence changes use reliable delivery. Coordinates may use unreliable delivery only when structure is unchanged and the entire encoded packet fits 1,000 bytes. A later complete state repairs a lost pose; changing the loss slider does not affect reliable frames.

The session and both transports cap reliable packets at **48,000 bytes** and unreliable packets at **1,000 bytes**. Large pose frames use reliable delivery. Configuration defaults are 10 updates per second, 0.1-second interpolation, 128 replicated entities, 128 queued messages, and 4,096 command bytes; exposed limits are bounded. JSON envelopes and encoding overhead count toward the wire cap. There is no automatic chunking, compression, or large-world streaming. Opt into <doc:replication-interest-and-bandwidth> for per-player scope and budgeted pose updates; default sessions retain complete-state publication. Keep matches and selected values small; surface `lastError` and failure events instead of assuming delivery succeeded.

## Own exactly one update path

`start()` installs ``SpriteUI/NetworkReplicationSystem`` in `.presentation`, after simulation and native physics. With a normal running ``SpriteUI/GameView``, this automatically drains session input and captures outgoing state. A headless `World.update(deltaTime:)` also runs the installed system. It does not advance an ``SpriteUI/InMemoryNetwork``: the app must advance that hub separately.

For explicit stepping or commands that must arrive before host rules, disable the automatic system with `world.systems.setEnabled(false, for: NetworkReplicationSystem.self)` after starting, then call `session.update(deltaTime:)` exactly once at your chosen point. Do not combine explicit and automatic updates in the same frame. The tutorial uses only this manual path; its Pump button advances the hub and sessions in bounded rounds.

Pausing the world stops automatic session updates. If a paused game must keep exchanging data, the app owns an explicit pump and its lifecycle. Do not accidentally continue authoritative gameplay during that networking-only pump. On leaving a match, stop the session before disconnecting the coordinator; `shutdown()` also releases authentication/listener ownership. Stopping a client removes its replicas while preserving independent local entities. Host entities remain for the app to retain or clear.

## Keep remote presentation read-only

Remote transform smoothing supplies a read-only pose to eligible native presentation. Model transforms, queries, and saved snapshots remain at the latest validated host value; smoothing never rewrites canonical state. Native presentation and picking share that pose. Local camera ownership, native physics, active native transform animation, and conflicting presentation owners can prevent smoothing; it does not require enabling the fixed simulation clock. See <doc:fixed-step-simulation-and-interpolation> for local interpolation boundaries.

This feature provides state synchronization. It does not provide prediction, rollback, deterministic lockstep, automatic host migration, or deterministic native physics. Avoid running client rules that write replica transforms or install local native physics on those replicas. The tutorial's SwiftUI circles intentionally display canonical values for diagnostics, so they jump when a packet is applied rather than illustrating native smoothing.

## Verify offline and on signed devices separately

Follow <doc:synchronizing-a-small-network-match> for three standalone, asset-free stages. No Game Center account is required for the offline path. The hub's controlled latency, seeded unreliable loss, and explicit `advance(by:)` make delivery reproducible; even zero-latency messages require an advance. The hub must outlive its transports.

Before claiming native interoperability, run a signed build on two devices with two distinct Game Center accounts. Verify authentication cancellation/retry, matchmaking cancellation, complete-roster host agreement, commands, delayed replication-session start on an existing participant, host departure, restart, and pause/resume with the chosen pump policy. Midmatch Game Center additions are outside this test contract. Signed two-account/two-device Game Center testing remains **pending** because credentials and app configuration are not available here. Compilation, backend presentation tests, schematic previews, and offline delivery do not establish live Game Center success.

## See also

- <doc:synchronizing-a-small-network-match>
- <doc:player-input-sessions-and-feedback>
- <doc:saving-and-debugging>
- <doc:fixed-step-simulation-and-interpolation>

Opt-in relevance and budgeted pose updates are covered in <doc:replication-interest-and-bandwidth>. Budgeted poses reference a reliable membership frame, refresh stationary final values after loss, and never implicitly delete other members.
