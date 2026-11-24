# Multiplayer interactions and lag compensation

Resolve shots and nearby interactions against a recent host-issued view, then confirm or refuse each action once.

## Use an exact host-issued view

Movement prediction makes local motion immediate. Interactions add a different contract: an action identifies the exact scene sample the player used to aim. The host retains an inert copy, checks its age and ownership, and queries that copy without moving live entities or rewinding SpriteKit physics.

``SpriteUI/NetworkInteractionAuthority`` and ``SpriteUI/NetworkInteractionClient`` live in ECSCore. They provide bounded history, host-issued references, sequenced intent, cooldowns, cached receipts, and pending feedback bookkeeping. Gameplay provides ``SpriteUI/HistoricalCollisionScene2D`` and affine hit proxies using the existing CollisionGeometry queries. ``SpriteUI/NetworkInteractionController2D`` in GameplayECS connects them to an existing NetworkSession. No Game Center dependency is added to the engine or pure geometry targets.

This is exact-sample compensation, not clock synchronization or arbitrary timestamp rewind. An action returns a ``SpriteUI/NetworkInteractionViewReference`` actually issued to that owner, containing the network actor, fresh host epoch, random reference ID, and sample tick. A client cannot invent a muzzle position, damage amount, range, or hit result. It may choose an issued sample within the host's allowed window; that bounded trust is an explicit gameplay policy, not anti-cheat server authority.

The following complete value-only exercise queries the state that was issued, even after the host records a newer state. Validation and query callbacks must be pure and use value-semantic data. Apply effects only after resolve commits a new accepted receipt.

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

## Select hit proxies deliberately

Attach ``SpriteUI/NetworkInteractionBodyComponent`` only to synchronized entities whose query geometry may be disclosed to this player. The first adapter includes all active marked synchronized entities; it has no secret-entity filtering or interest management. The component is an explicit hit proxy independent of native CollisionComponent/PhysicsBodyComponent. Its offset and full ancestor affine transform become historical scene geometry. Source position comes from this host-recorded proxy origin.

A scene supports at most 64 unique proxies, 16 vertices per shape, local geometry up to 10,000 units, finite positions within ±1,000,000, and bounded nonsingular bases. Queries support circles, rectangles, convex polygons, and edges. ``SpriteUI/HistoricalCollisionBody2D`` records target, blocker, and proximity eligibility flags. Nearest rays include blockers and use stable identity ordering for exact-distance ties. Proximity checks center distance and historical line of sight; a target along the line can block interaction with a different target.

The body's incarnation distinguishes respawns. Cloning creates a fresh incarnation. Replace the marker with a new instance on respawn or a semantic shape/lifetime replacement. Do not recycle an old incarnation for a new target. Before granting a hit/interaction, the adapter also checks that the current host target is active, still synchronized under that network identity, has the same incarnation, and remains eligible. Health, teams, inventory, game phase, current-range requirements, and other game rules belong in the host's pure validateAction callback. Damage and rewards belong outside it, after acceptance.

This complete host helper is called after the application has started a connected session, attached the remotely owned actor, and attached eligible target/blocker markers. Keep the returned controller for the match lifetime. It uses the presentation phase after networking so capture sees simulation/backend results; it does not require a fixed clock or change the existing movement controller.

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

## Predict feedback and wait for confirmation

Create the client controller only after the owned canonical replica baseline exists. Retain it alongside the session and wait until status is running. Its latestView is a host-issued collision sample. Display and aim from that exact view when claiming compensation. Ordinary replicated model poses and interpolated/predicted visuals can represent different times; aiming from those while sending an unrelated view reference does not guarantee the shot the player saw.

Client `perform(_:)` sends either a finite unit ray direction or a network target ID for proximity interaction. The host owns both range limits. Successful send reserves one pending action and publishes Predicted once for transient feedback only. No speculative damage or reward is inferred. A final Resolved event completes that action once, whether accepted, missed, blocked, or refused.

This complete helper attaches a client to an existing baseline. The app retains the returned controller, chooses an explicit input action, computes its aim from latestView, and calls perform when ready.

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

The following complete listener separates temporary effects from host gameplay. Its keys include the stream epoch and action index, so different actors or new incarnations do not share feedback IDs. Retain subscriptions and cancel them with the match. A host hit counter illustrates the effect boundary; a real game must validate current state and apply its own damage, inventory, and durable reward policy.

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

## Bound time, work, and retries

``SpriteUI/NetworkInteractionConfiguration`` defaults to a 0.5-second maximum rewind, 0.2-second cooldown, 128 retained snapshots/views/results, and 16 pending local actions. Construction bounds rewind to 0.05...2 seconds, cooldown to 0...10 seconds, capacity to 2...256, and pending actions to 1...64. Host history uses monotonically increasing application-owned host time, never client timestamps. The adapter advances its clock from unscaled presentation deltas. Pausing stops automatic updates; no background time is replayed. Stop/rebuild on lifecycle interruption rather than retaining old view tokens across a suspended session.

Receiving a command does not immediately grant an effect. The adapter queues at most 32 commands and resolves them after NetworkSession's update, outside its reentrant-operation boundary. At most 16 active controllers are allowed per world, one per actor. The host cooldown is charged for accepted actions including misses/blocks and survives a fresh client handshake within the same controller. Rejected actions consume their sequence without granting effects. Burst requests therefore cannot obtain extra hits by backdating samples or asking for another epoch.

A cached duplicate returns the original receipt without querying again or publishing another host event. An evicted old index stays retired and cannot become a fresh action. Client bookkeeping accepts a final result only for a pending index in its current epoch; duplicate receipts cannot play confirmation twice. This is session-scoped duplicate protection, not a durable exactly-once currency ledger. Recovery must not re-grant rewards from old receipts.

Views, actions, and final receipts use reliable application messages through the existing session. The entire encoded payload must fit maximumCommandBytes and the outer envelope must fit maximumPacketBytes. Default application payload capacity is 4,096 bytes; the geometry bound does not imply that 64 proxies fit this byte limit. Keep views small or configure a mutually supported bounded limit; oversize publication fails explicitly. There is no chunking, compression, or per-recipient visibility filtering. Ordinary replica poses may still use unreliable delivery and existing read-only interpolation.

Keep exactly one world/session update path. Stop controllers and clear speculative feedback on menu exit, interruption, session teardown, source removal, ownership transfer, account change, or recovery. A new baseline requires new controllers, fresh host epochs, and fresh history; never restore issued references or pending effects from a checkpoint. Runtime controllers are weakly registered with the world and must be retained by the app. Construction does not authenticate, match, or reconnect. See <doc:multiplayer-recovery-and-rejoining> and <doc:multiplayer-prediction-and-reconciliation>.

## Test the interaction contract

The showcase's Interactions & lag compensation lab and <doc:validating-multiplayer-interactions> compare a moving live target with an exact received historical view. Fire, compare host hit counts with an uncompensated current-position query, burst into cooldown, add a wall, interact with a nearby beacon, or respawn the target before an action arrives. Latency and jitter can age a view beyond the maximum window and cause refusal. The pose-loss slider affects ordinary unreliable replicas; it does not claim to drop reliable action/view/receipt messages.

Tests cover forged and expired references, wrong owners/epochs, cooldowns, duplicate/evicted indices, reordered confirmations, shape bounds, occlusion, target removal/respawn, application validation, and lifecycle cleanup. This layer does not provide projectile simulation, arbitrary world rollback, clock synchronization, native-physics determinism, interest management, or a trusted dedicated server. Signed two-account native Game Center verification remains pending in this checkout. The local simulator showcase has no signed Game Center entitlement; offline results and successful builds do not establish live service delivery.
