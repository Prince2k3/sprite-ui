# Replication interest and bandwidth

Choose each player's replicated scope and bound entity traffic while retaining host authority, reliable membership, and loss repair.

## Keep existing behavior until opting in

A NetworkSession still uses complete selected-state frames by default. ``SpriteUI/NetworkReplicationPolicy`` opts into per-recipient relevance; ``SpriteUI/NetworkReplicationBudget`` additionally opts into token-budgeted membership frames and smaller prioritized pose packets. Both are fixed for the session lifetime and can be forwarded through ordinary Game Center setup, party preparation, and recovery preparation. Use matching SDK/application versions on every participant when enabling budgeted pose packets.

A host's policy returns hidden, visible with priority, or required for a canonical entity and authenticated recipient. The host forcibly retains that player's owned actors and the synchronized ancestors of every selected entity. A child never arrives without its required hierarchy. Membership entry, exit, reparenting, names, activation, ownership, selections, transform presence, and non-transform changes use a reliable full scoped frame. Removing a replica does not remove the authoritative entity. Client-local entities outside replica subtrees survive scope changes.

This complete helper selects one named area while retaining global state and owned actors. It starts only an already-connected caller-supplied transport; it does not authenticate or find a match. The caller retains the returned session and world.

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

Relevance is not an authorization boundary. Owned actors and required ancestors deliberately override hiding. A visible parent may carry selected component data; do not place secret state there. This first policy selects whole entities, not a different component schema per player. Validate all portable selected host state before sending. A selective host captures at most 512 synchronized entities; each recipient is independently limited by maximumEntities, default 128. Unscoped sessions retain their existing host-wide entity cap.

## Use distance, groups, and hysteresis

``SpriteUI/NetworkSpatialInterest`` lives in GameplayECS and holds a weak world reference. Retain it beside its session. Explicitly set a scene-space observer point from the host's canonical player/camera policy. ``SpriteUI/NetworkInterestComponent`` supplies optional groups, always-relevant hints, and pose priority. Empty groups are ungrouped; otherwise the entity must share an allowed observer group. Group eligibility is checked before always-relevant hints. Owned/ancestor forcing still applies in the core.

The entry radius and larger exit radius avoid repeated spawn/despawn at a boundary. The adapter supports at most 32 observers, 32 bounded group IDs each, and bounded membership memory. Departing peers are removed; call removeAllObservers on application teardown/recovery. Missing observers or a released adapter hide optional actors. Keep required owned/ancestor state free of secrets.

This complete helper returns both retained owners. Update the observer point as the host-owned player moves; do not accept unvalidated client camera coordinates as authority.

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

## Bound replication, not the entire connection

A budget uses separate per-recipient credits. Construction bounds sustained rate to 512...1,000,000 bytes/second, burst to 512...48,000 bytes, pose packets to 512...1,000 bytes including the envelope, packets per publication to 1...8, and refresh/age priority to 0.05...5 seconds. Defaults are 12,000 B/s, a 48,000 B burst, 1,000 B pose packets, four packets per publication, and a 0.5-second refresh threshold. Credits refill from the session's bounded update delta; synchronize does not manufacture more time or credits.

Initial membership and structural changes consume credits and take precedence over poses. If credits are temporarily insufficient, publication is deferred. If a full frame exceeds the burst or maximumPacketBytes, the session fails explicitly; it is not split into an incomplete hierarchy. The same applies if one encoded pose cannot fit the chosen pose-packet limit. Configure a burst large enough for the largest expected full scoped frame. A low sustained rate can delay baseline readiness or scope exit; surface diagnostics and own the game's timeout policy.

Control and application messages remain outside this **entity replication** token bucket so acknowledgments, validated commands, interaction receipts, and session control are not silently dropped to save pose bandwidth. They retain their own packet/queue bounds and application-owned admission rates. The token budget is not a cap on total Game Center traffic. Read all diagnostic lanes before estimating total bandwidth.

## Repair loss without deleting scope

Budgeted pose packets identify the exact reliable membership-frame sequence they depend on. A client ignores poses for an unapplied/retired membership frame and rejects stale session/join identities or packet sequences. It decodes and validates the complete pose packet before changing any model. These packets update existing selected Transform values only; they cannot spawn, delete, reparent, transfer ownership, or patch arbitrary components.

Changed transforms are prioritized. Critical/high priorities lead while older due actors gain precedence to avoid cheap continuous updates starving others. Stable identity breaks ties. Periodic refreshes include stationary final poses too: losing the last movement packet must not leave an actor permanently at an old position. Refresh is an age-priority threshold, not a guaranteed deadline under an insufficient budget. Deferred counters expose that condition. Remote interpolation remains read-only; canonical queries and snapshots use the latest validated model.

``SpriteUI/NetworkPeerReplicationStatistics`` exposes relevant/available entity counts, entity bytes/packets sent, application/control bytes, received bytes, remaining credits, deferred publications, and pending pose count. Counters include encoded envelopes and saturate. They reset at session start; peer departure releases peer caches. The following complete SwiftUI diagnostic uses one retained session.

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

## Keep movement, interactions, and recovery consistent

Owned actors remain replicated so their prediction controllers retain a canonical source. Interaction hit views now include only identities in the owner's last published membership frame, rather than revealing hit proxies for hidden actors. Historical actions still reference the exact earlier issued sample and use the existing host range, age, and current body-lifetime checks. Relevance does not transfer authority or make a client's replica suitable as a recovery checkpoint.

Recovery checkpoints retain the host's complete selected world, independent of per-player relevance. They still must fit archive and full-state packet limits. Recreate observer locations, runtime adapters, epochs, and policy during recovery preparation; never persist their weak references or token credits. Game Center party control and initial baseline acknowledgment keep their existing lifecycle. The following complete helper passes a caller-retained policy into an already-matched party's prepared world. Ready and Start remain separate explicit actions.

```swift
import SpriteUI

@MainActor
func prepareBudgetedParty(services: GameCenterServices, world: World,
                          policy: NetworkReplicationPolicy) throws {
    try services.party.prepare(in: world, compatibilityID: "arena-budget-v1",
        replicationPolicy: policy, replicationBudget: .init(bytesPerSecond: 12_000))
}
```

The Game Services showcase's Relevance & traffic lab and <doc:controlling-replication-traffic> use one host and two independent client worlds. Move observer points, change group eligibility, lower the rate before reconnecting, and drop unreliable poses. Watch scope, credits, and deferrals separately for each player. The preview performs no account or native matchmaking work. Signed two-account Game Center verification remains a separate release requirement.
