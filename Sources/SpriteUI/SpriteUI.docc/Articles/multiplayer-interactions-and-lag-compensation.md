# Confirm shots against the scene a player used

A player aims at a moving bot and fires. By the time the action reaches the host, the bot has moved. Testing only its current position can turn a reasonable shot into a miss.

Instead, the host gives the player a recent scene sample to aim from and keeps a copy. The action refers to that exact sample. The host can check the shot against it without moving live entities or rewinding SpriteKit physics.

## Give the player a scene reference

``SpriteUI/NetworkInteractionAuthority`` records value snapshots and issues references. ``SpriteUI/NetworkInteractionClient`` includes a received reference when requesting an action. The reference identifies the actor, ownership epoch, and exact host sample.

The client supplies intent, such as a direction or nearby target. It cannot invent a muzzle position, range, damage, or hit result. The host also limits how old an issued sample may be. This approach is called lag compensation here: it uses a particular host-issued view, rather than a client timestamp or synchronized clock.

In this value-only example, the client received state 10. Although the host later records 90, the action is evaluated against 10 and returns 12.

```swift
import SpriteUI

func queryAnIssuedSample() throws -> Int {
    let owner = NetworkPeerID(rawValue: "player")
    let stream = NetworkPredictionStream(entity: NetworkEntityID(), owner: owner)
    var host = NetworkInteractionAuthority<Int, Int, Int>(stream: stream)
    try host.record(10, at: 0)
    let view = try host.issueView()
    var client = NetworkInteractionClient<Int, Int, Int>(view: view)
    let action = try client.predict(2)
    try host.record(90, at: 0.1)
    let decision = try host.resolve(action, from: owner, at: 0.2) { state, intent in state + intent }
    _ = try client.receive(decision.result)
    if case .accepted(let value) = decision.result.resolution { return value } // 12, not 92.
    return 0
}
```

Validation and query closures must be pure and use value-semantic data. Apply gameplay effects only after resolution commits a new accepted receipt, so a repeated request cannot repeat the effect.

## Describe what a shot can hit

Add ``SpriteUI/NetworkInteractionBodyComponent`` to synchronized actors, targets, and blockers. It is query geometry independent of native physics. The adapter records the shape, offset, and ancestor transforms in a ``SpriteUI/HistoricalCollisionScene2D``. The actor's recorded proxy origin supplies the shot source.

Only active marked identities in the player's last published replication membership enter that view. Configure <doc:replication-interest-and-bandwidth> to choose which actors are published. Do not put secret data into a visible entity: scope selects whole entities, not individual private components.

This helper gives the player an eight-unit source circle, an 800-unit ray range, and a 60-unit interaction range. It allows samples up to half a second old and charges a quarter-second cooldown.

```swift
import SpriteUI

@MainActor
func attachInteractionAuthority(world: World, session: NetworkSession,
                                actor: Entity) throws -> NetworkInteractionController2D {
    actor.components.set(NetworkInteractionBodyComponent(shape: .circle(radius: 8), isTarget: false))
    return try .host(in: world, session: session, entity: actor,
        rules: .init(rayRange: 800, interactionRange: 60),
        configuration: .init(maximumRewind: 0.5, cooldown: 0.25))
}
```

Attach the target and blocker markers before using the controller, and retain it for the match. Historical rays respect blockers; proximity queries check center distance and line of sight. Exact-distance ties use stable identity order.

A bot that respawns is a new target lifetime even if it keeps its network ID. Replace its body marker with a fresh instance so an old shot cannot hit the new bot. Before acceptance, the adapter checks that the current target is active, still synchronized, has the same body incarnation, and is eligible. Use the host's pure `validateAction` callback for health, teams, inventory, round state, and any requirement that range still hold now.

## Show a beam before promising a hit

After the client receives its replica baseline, attach its controller and retain it alongside the session.

```swift
import SpriteUI

@MainActor
func attachInteractionFeedback(world: World, session: NetworkSession,
                               actorID: NetworkEntityID) throws -> NetworkInteractionController2D {
    try .client(in: world, session: session, entityID: actorID,
        rules: .init(rayRange: 800, interactionRange: 60),
        configuration: .init(maximumRewind: 0.5, cooldown: 0.25))
}
```

Wait until it is running, then aim from `latestView` and call `perform(_:)` with a finite unit ray direction or a proximity target ID. The host owns the ranges. A predicted or smoothed actor can depict a different time from `latestView`; using that pose with an unrelated view reference cannot guarantee the shot matches what the player saw.

A successful send publishes `Predicted` for temporary feedback, such as a beam line. It does not grant damage or points. `Resolved` completes the action with an accepted, missed, blocked, or refused result.

This listener keeps temporary effects on the client and increments a demonstration hit count only for new accepted host hits. Its key combines stream and sequence so different actors and new epochs do not share feedback IDs. Retain the listener and cancel its subscriptions when the match ends.

```swift
import SpriteUI

@MainActor
final class InteractionFeedback {
    struct Key: Hashable { let stream: NetworkPredictionStream; let sequence: UInt64 }
    var temporaryEffects: Set<Key> = []
    var hostHits = 0
    private var subscriptions: [EventSubscription] = []
    init(world: World) {
        subscriptions = [
            world.subscribe(to: NetworkInteractionEvents.Predicted.self) { [weak self] event in
                self?.temporaryEffects.insert(Key(stream: event.command.view.stream, sequence: event.command.sequence))
            },
            world.subscribe(to: NetworkInteractionEvents.Resolved.self) { [weak self] event in
                guard let self else { return }
                if event.isAuthority {
                    if case .accepted(let outcome) = event.result.resolution, outcome.kind == .hit { hostHits += 1 }
                } else {
                    temporaryEffects.remove(Key(stream: event.result.stream, sequence: event.result.sequence))
                }
            }
        ]
    }
    func stop() { for token in subscriptions { token.cancel() }; subscriptions = []; temporaryEffects = [] }
}
```

A real game applies its damage and reward policy after host acceptance. Final client receipts can play confirmed audio or particles once. Movement replay never runs those effects.

## Resolve duplicates and interruptions

A cached duplicate gets the original receipt without another query or host event. An older action whose receipt was evicted stays retired. The client accepts results only for pending actions in its current epoch, preventing repeated confirmation effects.

Host cooldown applies to accepted actions, including misses and blocks. It survives a new client handshake within the same controller. Rejected actions consume their sequence without effects, so bursts and older samples do not bypass it.

On interruption, stop controllers and clear temporary feedback. After the new baseline, create new controllers, history, and host epochs. Do not restore issued views, pending actions, or feedback from a checkpoint. See <doc:multiplayer-recovery-and-rejoining>.

In the showcase's Interactions & lag compensation lab, compare a moving target with its received historical view. Place a wall or respawn the target before a delayed shot arrives to see why the host may refuse it.

## Limits and native validation

The default history allows a 0.5-second rewind, a 0.2-second cooldown, 128 retained snapshots/views/results, and 16 pending actions. Host time advances from unscaled presentation deltas; pausing does not replay background time. The adapter queues at most 32 commands, resolves outside the session update callback, and supports 16 controllers per world, one per actor. Retain them and keep a single world/session update path.

Scenes support up to 64 proxies with circles, rectangles, convex polygons, or edges, and up to 16 vertices per shape. Geometry and transforms must pass size, finite-value, and nonsingular-basis checks. Views, actions, and receipts use reliable messages and must fit the session's application and packet limits. The default 4,096-byte application limit may fit fewer than 64 proxies; there is no automatic chunking or compression.

The client can choose among issued samples within the allowed window. That is a gameplay trust choice, not dedicated-server anti-cheat authority. This layer does not simulate projectiles or roll back the world. Receipt deduplication lasts for the session and cannot provide durable currency transactions. Signed two-account Game Center verification remains pending; the local lab's pose-loss control drops unreliable replica poses, not reliable views, actions, or receipts.
