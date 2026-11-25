# Share a small game world between players

Two players see the same arena. When one moves a crate or scores a point, both games need to agree on what happened. Give one player the job of deciding shared state, then send selected values to the others.

In SpriteUI, that player is the host. A ``SpriteUI/NetworkSession`` copies the host's selected entity state into client worlds. This copying is called replication.

## Decide who can change the arena

The host creates, removes, reparents, and changes shared entities. Clients send requests such as “move left” or “fire,” and the host decides whether those actions are allowed. Run shared game rules and native physics on the host.

An entity's `SynchronizationComponent.owner` identifies the player whose commands belong to it. Ownership does not let that player's client write replicated components. For movement that responds before the host replies, use a separate local visual as described in <doc:multiplayer-prediction-and-reconciliation>.

Game Center waits for the complete initial roster, including `expectedPlayerCount == 0`, before choosing the smallest sorted `gamePlayerID` as host. Every participant uses that same roster and host ID. Display names and local entity IDs cannot make this choice reliably.

## Choose the values the other game needs

A client may need a player's position, score, and target. It does not need the host's camera, input controller, or loaded texture object.

``SpriteUI/NetworkReplicationSchema`` lists the component formats allowed on the connection. It is separate from saved-world registration. The default includes `Transform` as `transform` and rejects nonfinite values. Add matching names, encodings, and validators on every player.

The example allows scores from 0 through 999, then marks an actor to send its transform and match stats. Add this actor at the world root or under another synchronized entity: every ancestor in a replicated hierarchy must also be synchronized.

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

Use ``SpriteUI/NetworkEntityID`` when one shared entity refers to another. Each client creates its own local `Entity.ID`, so a host's local ID would mean nothing there. Resolve network IDs through `session.entity(withNetworkID:)`, and check whether a target still exists and is valid for the action.

Register only portable value components. `Codable` alone does not make native bodies, resources, local entity references, or runtime services suitable for transmission. The schema rejects `EntityReferencingComponent` types and the synchronization marker itself; your game must keep other runtime objects out. Components not selected by the marker stay local; selected components absent on the host are removed from the replica.

## Attach the session after matchmaking

Retain a ``SpriteUI/GameCenterMultiplayer`` coordinator. Its authentication and matchmaking views offer player actions for sign-in, finding a match, and accepting an invitation. An invitation waits until accepted or declined.

When `matchmakingState` becomes `.ready`, the coordinator has a transport and a host ID. This helper compares the local ID with that host ID, starts the appropriate session, and returns it for the app to retain alongside the world.

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

The coordinator owns the transport; the app owns this session and its subscriptions. Do not replace the transport's `onEvent` while the session uses it. Dismissing a ready matchmaking sheet keeps the match connected. The higher-level `GameCenterServices.connect` flow in <doc:game-center-services> can manage attachment for you.

## Turn a button press into a host decision

Clients call `sendCommand(_:)` with a small application message. On the host, retain a subscription to ``SpriteUI/NetworkEvents/CommandReceived``. Use its transport-authenticated sender, rather than trusting a player ID written inside the message.

Decode a narrow action and check its size, numeric ranges, target, sender ownership, frequency, and current game rules before changing state. For example, reject a move outside the arena or a shot during cooldown. Accepting arbitrary component patches would let the client choose the outcome instead of requesting an action.

## Receive a complete starting world

Before a client can play, it needs the host's initial selected state, called a baseline. The receiver checks the complete frame before changing replicas: identities must be unique, values must pass schema validators, and the parent graph must be complete and acyclic. Application observers can still run during attachment, so this is not a transaction over arbitrary observer side effects.

Default updates send complete selected state. Structural changes and non-transform values use reliable delivery. Coordinates can use unreliable delivery when the structure is unchanged and the complete packet fits 1,000 bytes. Losing a position update is repaired by a later full state.

Remote smoothing changes the displayed pose without changing model transforms, queries, or saved snapshots. Native physics, cameras, or competing animation owners can prevent smoothing. Keep client game rules from moving replicas independently.

## Advance networking once per frame

`start()` installs `NetworkReplicationSystem` in the presentation phase, after simulation and native physics. A running `GameView` or headless `World.update(deltaTime:)` advances it automatically.

If commands must arrive before host rules, disable that system with `world.systems.setEnabled(false, for: NetworkReplicationSystem.self)` and call `session.update(deltaTime:)` once at your chosen point. Mixing automatic and manual updates would advance the session twice. An `InMemoryNetwork` has its own clock and also needs advancing, even for zero-delay messages.

Pausing a world pauses automatic networking. Choose a separate networking pump only if the game needs one, keeping gameplay paused. On exit, stop the session before disconnecting the coordinator. Client replicas are removed; host entities and independent local entities remain. Keep local-only entities outside replicated subtrees so removing a replica cannot remove them too.

## Limits and native validation

This path supports iOS 18/macOS 15 and small matches. Defaults are 10 publications per second, 0.1-second interpolation, 128 entities, 128 queued messages, and 4,096 command bytes. Reliable packets allow 48,000 encoded bytes; unreliable packets allow 1,000. Encoding overhead counts, and large frames are not automatically split or compressed. Surface session errors when state will not fit. Use <doc:replication-interest-and-bandwidth> when different players need different parts of the world.

Game Center's roster is fixed: a host departure ends the match, with no automatic host migration or midmatch additions. Starting replication late on an already-connected participant is supported; it is not matchmaking a new player into a running match. Sessions reject stale packets but do not reconnect themselves. Native physics is not deterministic across clients.

Signed two-account/two-device testing remains **pending**. Configure Game Center signing, app-version enablement, and compatibility as described in <doc:game-center-services>, then test roster agreement, commands, delayed session start, departure, restart, and pause/resume. Continue with <doc:multiplayer-prediction-and-reconciliation> when waiting for host positions makes local movement feel slow.
