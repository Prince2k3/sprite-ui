# Send each player the world they need

An arena has actors in several rooms, but a player can see only one room at a time. Sending every actor's position to every player wastes traffic. Choose which entities each player receives, then decide how quickly to spend bytes updating them.

These are two separate choices: replication interest selects the entities; a replication budget schedules their updates.

## Start by choosing the visible set

Default sessions publish complete selected state. Add a ``SpriteUI/NetworkReplicationPolicy`` when different recipients need different entities. It returns hidden, visible with a priority, or required for each entity and authenticated player.

This host always includes `round-score` and selects other entities by a player-specific name prefix. It also sets a 12,000-byte-per-second entity budget. The transport is already connected; retain the returned session and world.

```swift
import SpriteUI

@MainActor
func makeScopedHost(world: World, transport: any NetworkTransport) throws -> NetworkSession {
    let policy = NetworkReplicationPolicy { entity, peer in
        if entity.name == "round-score" { return .required }
        return entity.name.hasPrefix(peer.id.rawValue) ? .visible(priority: .high) : .hidden
    }
    let session = NetworkSession(world: world, transport: transport, role: .host,
        replicationPolicy: policy, replicationBudget: .init(bytesPerSecond: 12_000))
    try session.start()
    return session
}
```

The session always includes a player's owned actors and any synchronized ancestors needed by selected children. That keeps a child from arriving without its parent. When an actor leaves a player's set, only that client's replica is removed; the host actor remains.

Membership changes, parenting, names, ownership, component selection, and non-transform values travel in a reliable full frame for that player. Keep client-local entities outside replica subtrees so a scope exit does not remove their descendants too.

## Follow the player's position without flicker

Most games can choose nearby entities by distance. ``SpriteUI/NetworkSpatialInterest`` uses a host-supplied observer point and optional groups. Retain it beside the session and update that point as the host-owned player moves.

Here, entities enter within 500 units. The extra 60-unit exit margin keeps them present while the player moves back and forth near the edge. This difference between entry and exit distance is called hysteresis.

```swift
import SpriteUI

@MainActor
func makeSpatialHost(world: World, transport: any NetworkTransport,
                     player: NetworkPeerID, position: SIMD2<Float>) throws
    -> (session: NetworkSession, interest: NetworkSpatialInterest) {
    let interest = try NetworkSpatialInterest(world: world, radius: 500, exitMargin: 60)
    try interest.setObserver(at: position, groups: ["arena"], for: player)
    let session = NetworkSession(world: world, transport: transport, role: .host,
        replicationPolicy: interest.policy, replicationBudget: .init())
    try session.start()
    return (session, interest)
}
```

Use the host's validated player or camera policy for the observer position. An unvalidated client camera coordinate should not decide what the host publishes. `NetworkInterestComponent` can provide groups, always-relevant hints, and pose priorities. Group eligibility is checked before an always-relevant hint; owned actors and required ancestors are still forced into the set.

Remove departing observers and clear them on teardown or recovery. If an observer is missing or the weakly referenced adapter is released, optional actors become hidden.

## Spend bytes on structure before movement

``SpriteUI/NetworkReplicationBudget`` gives each recipient separate credits. Credits refill as the session advances. A full membership frame gets priority over pose updates because the client must know which actors exist before moving them.

A temporary lack of credits defers publication. A frame larger than the configured burst or packet limit fails instead of being split into an incomplete hierarchy. Choose a burst large enough for your largest expected full frame. Too low a sustained rate can delay the starting baseline or removal of an actor from scope.

Changed poses compete by priority and age, so continuous high-priority motion does not permanently starve older due actors. Stationary actors also get refreshed: losing the last movement packet should not leave a bot stuck at its previous position. Under an insufficient budget, the refresh threshold cannot promise a delivery deadline.

Pose packets identify the reliable membership frame they belong to. They only update existing selected transforms; they cannot create, remove, or reparent actors. A client ignores packets based on an old or unapplied membership frame and validates a whole packet before changing its model.

## Watch what each player costs

The budget covers entity replication, not all connection traffic. Commands, acknowledgments, lobby control, and interaction receipts have separate limits and do not spend pose credits. Compare both lanes when estimating traffic.

This view shows the player's entity count, entity and application bytes, and deferred poses from one retained session.

```swift
import SpriteUI
import SwiftUI

@MainActor
struct ReplicationTrafficView: View {
    let session: NetworkSession
    var body: some View {
        VStack(alignment: .leading) {
            ForEach(session.replicationStatistics, id: \.peerID) { value in
                Text("Scope: \(value.relevantEntities)/\(value.availableEntities)")
                Text("Entity bytes: \(value.replicationBytesSent); app bytes: \(value.applicationBytesSent)")
                Text("Deferred poses: \(value.deferredPoseUpdates)")
            }
        }
    }
}
```

If deferrals keep growing, either reduce the visible set or increase the budget. Counters include encoded envelopes and reset when the session starts. Remote smoothing still affects presentation only; queries and snapshots use the latest validated model.

## Carry the policy into a party

Set policy and budget when starting the session; they remain fixed for that session's lifetime. Party and recovery preparation can pass them through. This helper prepares an already-matched party world while leaving Ready and Start as separate player actions.

```swift
import SpriteUI

@MainActor
func prepareBudgetedParty(services: GameCenterServices, world: World,
                          policy: NetworkReplicationPolicy) throws {
    try services.party.prepare(in: world, compatibilityID: "arena-budget-v1",
        replicationPolicy: policy, replicationBudget: .init(bytesPerSecond: 12_000))
}
```

Owned actors remain available for movement controllers. Interaction views include only identities in the player's last published membership. Recovery checkpoints, however, retain the host's complete selected world, not just one client's view. Recreate observers and policy during recovery rather than saving weak references or byte credits.

The showcase's Relevance & traffic lab uses one host and two client worlds. Move observer points, change groups, lower the rate before reconnecting, and drop unreliable poses to see why each player's traffic differs.

## Limits and native validation

Interest is a publication policy, not a security boundary. Owned actors and ancestors override hiding, and a visible entity sends its selected component data. Keep secrets out of that data. Selective capture supports up to 512 synchronized host entities, with a default of 128 per recipient. Spatial interest supports 32 observers and up to 32 group IDs per observer.

Budget defaults are 12,000 bytes per second, a 48,000-byte burst, 1,000-byte pose packets, four pose packets per publication, and a 0.5-second refresh threshold. Supported rates are 512 through 1,000,000 bytes per second; bursts are 512 through 48,000 bytes. There is no automatic snapshot chunking or asset streaming. Recovery archives and full-state frames must still fit their limits.

All participants need compatible SDK and application versions for budgeted packets. Signed two-account Game Center verification remains a separate pending release requirement; local traffic experiments do not establish live delivery. Continue with <doc:multiplayer-validation-and-release-checks> when preparing a release.
