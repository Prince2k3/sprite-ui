# Multiplayer recovery and rejoining

Keep an application-owned checkpoint, explicitly match again, and resume only after the original host restores approved state and clients apply a fresh baseline.

## Separate saved state from a connection

``SpriteUI/NetworkRecoveryCheckpoint`` and ``SpriteUI/NetworkRecoveryDescriptor`` live in ECSCore. They use the session's ``SpriteUI/NetworkReplicationSchema`` allowlist, not the saved-world component registry. Runtime services, local entity IDs, physics, cameras, subscriptions, and unselected components are not implicitly saved. The optional application payload is inert Data with its own game-defined schema.

``SpriteUI/GameCenterParty`` supplies the activity-specific orchestration in SpriteUIGameCenter. It retains no hidden checkpoint file and never retries, restores, spends a reward, or changes game presentation automatically. Keep a checkpoint and its exact approved descriptor in application-owned storage. A checksum detects corruption; it does not authenticate a player, establish server authority, or make a currency transaction safe.

Only a connected host can author a checkpoint. `party.recoveryCheckpoint(applicationState:at:)` uses the prepared world's compatibility ID and pins the original activity definition and party code as a recovery scope. It also captures the original host and sorted roster, original session incarnation, publication sequence, unique checkpoint ID, and SHA-256 digest. The following complete helper saves a checkpoint from a caller-retained facade. Call after the game decides it is a consistent recovery point, before interruption.

```swift
import Foundation
import SpriteUIGameCenter
import ECSCore

@MainActor
func saveMultiplayerRecovery(using services: GameCenterServices, to url: URL,
                             roundState: Data) throws -> NetworkRecoveryDescriptor {
    let checkpoint = try services.party.recoveryCheckpoint(applicationState: roundState)
    try checkpoint.write(to: url)
    return checkpoint.descriptor
}
```

The archive is limited to 256 KiB, including at most 64 KiB of application payload and 512 records. Session capture also verifies that selected state fits the current replication packet limit. File loading checks size before and after reading. Codable decoding validates metadata, version, digest, and bounds. Schema validators run before restored hierarchies are attached. Keep those validators side-effect free. Attachment still invokes app-owned world observers; it is not a rollback transaction over arbitrary event-handler side effects.

An exact approved descriptor rejects an unexpected older or relabeled checkpoint. A newer timestamp or larger sequence is not a generic conflict policy: publication sequences belong to their original session incarnation. The game must choose and persist its authoritative checkpoint ID/digest and validate its application payload. Decoding a file or receiving a host offer is not itself permission to restore it.

## Interrupt deliberately

`party.interrupt(reason:)` stops the current connection/session, releases lobby and preparation references, and enters `.interrupted`. It retains the activity through the activity service and does not report or discard staged scores. Native transport failures enter `.failed` with an interruption diagnostic. `leave()` is the explicit return-to-menu cleanup and clears interruption metadata; the app chooses its menu/world and retains or discards its own file.

``SpriteUI/GameCenterRecoveryConfiguration`` defaults to a 60-second fresh-match timeout, a 15-second recovery synchronization timeout, and background interruption. The `.gameCenter(services)` modifier calls `applicationDidEnterBackground()` only on background, not merely inactive; appearance and becoming active do not retry. A custom host can call this method itself. Disable the default only when the application supplies a deliberate background/networking policy. The ordinary prepared-world attachment timeout remains 15 seconds.

This complete view uses the caller's stable service host. ``SpriteUI/GameCenterPartyView`` shows interruption diagnostics and explicit Rejoin and Return to game menu controls; it does not select a checkpoint or prepare a world.

```swift
import SpriteUIGameCenter
import SwiftUI

@MainActor
struct RecoveryActions: View {
    let services: GameCenterServices
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GameCenterPartyView(services: services)
            Button("Interrupt connection") { services.party.interrupt() }
        }
    }
}
```

Keep the one facade/modifier above lobby and gameplay so a presentation switch does not call shutdown. An account change or shutdown clears party offers and releases the native match. It does not delete application files; verify account identity and approval before considering those files again. A Game Center sign-in is still an explicit separate flow.

## Match again, then approve recovery

Call `party.findMatch()` explicitly after interruption/failure. It enters `.rejoining` and requests a **fresh match** through the current activity's native matchmaking API; it does not append players to an old GKMatch or assume a disconnected transport will reconnect. Every original player must explicitly participate. Native activities require OS 26+, authentication, configured party support and player counts. See Apple's [activity matchmaking API](https://developer.apple.com/documentation/gamekit/gkgameactivity/findmatch(completionhandler:)).

The fresh roster must exactly match the checkpoint and elect the same original host. The activity definition and party code must match its scope. There is no host migration or transfer of checkpoint authority. If the original host cannot return, return to the game's menu or start a separately approved new game; do not silently promote a client. Cancelled or timed-out requests retire their generations and disconnect late successful matches rather than replacing a newer attempt.

Once the fresh party is in `.lobby`, only the host can `offerRecovery(checkpoint)`. It broadcasts bounded metadata, not a client-supplied world archive. A changed offer invalidates local preparation/readiness. Clients see `recoveryOffer` and choose to accept or leave. The game validates checkpoint freshness, expected content/protocol ID, profile/progression requirements, and application payload before acceptance.

This complete helper loads a file only if it equals an application-approved descriptor. It must run on the original host after the explicit fresh match completes. Construct the URL and trusted approval through the game's persistence policy; do not trust arbitrary downloaded metadata as approval.

```swift
import Foundation
import ECSCore
import SpriteUIGameCenter

@MainActor
func offerApprovedRecovery(from url: URL, approved: NetworkRecoveryDescriptor,
                           services: GameCenterServices) throws {
    let checkpoint = try NetworkRecoveryCheckpoint(contentsOf: url)
    guard checkpoint.descriptor == approved else { throw NetworkRecoveryError.incompatibleCheckpoint }
    try services.party.offerRecovery(checkpoint)
}
```

Each participant supplies a retained **fresh prepared world** to `prepareRecovery(in:accepting:compatibilityID:schema:configuration:)`. It requires the exact current offer and the application's expected content ID. Worlds with an active session or existing synchronized entities are refused. The host decodes and restores the payload through its allowlisted schema; clients keep local-only cameras/art and wait for the new host baseline. Selected entity IDs/hierarchy are preserved as network identities, while local Entity IDs are new. Readiness remains a separate action.

The complete helper below is called by each player's acceptance button after validating content readiness. The caller retains the returned world, installs local content, and later readies it. Do not copy stale client replicas into it. Async content loaders remain application-owned: cancel them on leave, and recheck the current activity/offer after every await before preparing a newer lobby.

```swift
import ECSCore
import SpriteUIGameCenter

@MainActor
func prepareApprovedRecovery(services: GameCenterServices, approved: NetworkRecoveryDescriptor,
                             expectedContentID: String, schema: NetworkReplicationSchema) throws -> World {
    let world = World()
    try services.party.prepareRecovery(in: world, accepting: approved,
                                       compatibilityID: expectedContentID, schema: schema)
    return world
}
```

## Wait for client resynchronization

After every participant explicitly calls `setReady(true)`, the host uses `canStart` and `startSession()`. Readiness must match both content compatibility and the **exact checkpoint descriptor**. Attachment/launch acknowledgments first enter `.starting`. A recovery commit then enters `.resynchronizing`, rather than immediately playing. Clients send a synchronization acknowledgment only after NetworkSession applies its initial validated host baseline. The host commits recovery only when the entire roster acknowledges; then everyone returns to `.playing`.

Fresh NetworkSession and join UUIDs reject packets from retired sessions even when they arrive from the same authenticated host identity. Checkpoint IDs/digests and launch UUIDs bind recovery control to the chosen attempt. The control envelope uses party protocol version 2; all players must use compatible library and application protocol versions. Existing packet and bounded early-message limits remain in force.

Continue pumping the prepared worlds' networking during resynchronization, while authoritative game rules and presentation swaps remain gated on `.playing`. A running world's presentation-phase system already updates its session; do not also update it manually in that frame. For a paused or headless world, the existing `networkSession.update(deltaTime:)` policy can drain messages explicitly. A validated initial baseline publishes NetworkEvents.DidApplyState, which advances recovery acknowledgments even without a SwiftUI view polling state.

A missing player, invalid offer, wrong roster/scope, cancelled request, abandoned world, failed baseline, or deadline ends the attempt without replacing the old application world or reporting scores. Host entities remain after teardown; client replicas are removed. The app owns simulation gating, hiding/releasing prepared content, returning to its menu, and any retry button. Restoring absolute round state is separate from granting rewards; use an application-owned durable receipt/transaction policy for side effects.

## Verify offline and native behavior separately

The showcase's Multiplayer recovery lab and <doc:recovering-a-multiplayer-session> use two independent preview services and a shared GameCenterPartyPreview. Save progress 3, advance to 4, interrupt, then request a fresh match and explicitly resume the approved progress-3 checkpoint. Toggle an offline partner to time out matching, or stall the client baseline to time out resynchronization. Nothing authenticates, reports a score, or retries automatically.

Native signed two-account verification remains pending. The local showcase setup checker found no signed Game Center entitlement; an ad-hoc simulator build cannot establish live party behavior. Before release, configure and sign the consuming app, confirm App Store Connect activity/player compatibility, and test cold/warm activity routing, original-code matching, backgrounding on each device, same-roster rejoining, client baseline acknowledgment, cancellation/timeout/retry, account changes, and stale-version rejection. Local fixtures and successful compilation do not prove those service results.

Prediction is transient session state. Stop movement controllers when interrupting; after the new baseline, create fresh controllers and a fresh host ownership epoch. Do not checkpoint or resume pending input, held buttons, or visual smoothing offsets. See <doc:multiplayer-prediction-and-reconciliation>.

Interaction view references, pending feedback, and cached action receipts also belong to the old session. Recreate interaction controllers after the new baseline and clear temporary effects on interruption; do not grant rewards again from an earlier action receipt. See <doc:multiplayer-interactions-and-lag-compensation>.
