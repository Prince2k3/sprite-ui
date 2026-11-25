# Resume a round after the connection ends

Two friends have nearly finished an arena when one game goes into the background. The connection ends, but they want to resume the same round. Reconnecting alone cannot tell them which score, actors, or remaining time to use.

Save an agreed recovery point, meet again with the original players, and let everyone receive that restored state before gameplay resumes.

## Save the host's view of the round

Only a connected host can create a ``SpriteUI/NetworkRecoveryCheckpoint``. It contains the entity values selected by the session's replication schema, plus optional application data such as remaining round time. Cameras, native physics objects, subscriptions, and other runtime services must be rebuilt separately.

The checkpoint also records which activity, party code, content/protocol version, host, roster, and session it came from. Its ``SpriteUI/NetworkRecoveryDescriptor`` identifies that exact checkpoint and digest. Retain the descriptor your game approved, alongside the saved file.

Call this helper when the host has reached a consistent recovery point. The app chooses the file location and validates the format of `roundState`.

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

Loading a file checks its format and integrity; it does not decide whether your game should resume it. Comparing with the saved approval prevents an unrelated older checkpoint from being selected accidentally. A later timestamp or a larger publication sequence is not a universal rule for choosing between saves, because sequences belong to their original sessions.

## Stop play when the connection stops

`party.interrupt(reason:)` stops the session and transport, releases lobby preparation, and enters `.interrupted`. It keeps the activity and any staged scores. A native transport failure enters `.failed` with an interruption diagnostic.

Keep one services object and modifier above both lobby and gameplay. This view adds an interruption button to the party's Rejoin and Return to game menu controls. The controls do not choose a save or prepare a world for you.

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

By default, the `.gameCenter(services)` host interrupts on background, rather than merely inactive. Becoming active does not retry. Neutralize input when focus is lost; on full interruption, stop movement and interaction controllers and clear temporary effects.

`leave()` is the return-to-menu cleanup and clears interruption metadata. Your app chooses its screen and whether to keep the checkpoint file. Account changes and shutdown clear offers and native match ownership, but do not delete your files; recheck identity and approval before using them again.

## Meet the original players again

After interruption or failure, call `party.findMatch()` from a player action. It enters `.rejoining` and asks the current activity for a fresh match. Each original player must participate. This does not add players to the old connection or revive it automatically.

The new roster, original host, activity definition, and party code must match the checkpoint. If the original host cannot return, offer a return to the menu or a separately approved new game. A client cannot silently take over the saved host's authority.

Once the party reaches `.lobby`, the host loads and offers the approved checkpoint. This helper checks exact descriptor equality before broadcasting the offer's metadata.

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

Clients inspect `recoveryOffer` and decide whether to accept. Validate the expected content version, progression requirements, checkpoint choice, and application payload. A changed offer clears preparation and readiness, so players cannot unknowingly start from different saves.

## Prepare fresh worlds

Each participant supplies a new retained world to `prepareRecovery`. The host restores the selected entity data through the schema. Clients keep their local cameras and artwork, then wait for a fresh host baseline. Network identities are preserved; local entity IDs are new.

This helper returns a prepared world for the app to retain and finish setting up. Readiness is still a separate action.

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

Worlds with an active session or existing synchronized entities are refused. Do not seed a client's new world with stale replicas. Rebuild host rules, runtime adapters, observer positions, and local content as needed. If preparation awaits content, cancel the load on leave and recheck the current offer after every wait.

## Wait until everyone has the restored state

When all players have called `setReady(true)` for the same content ID and descriptor, the host uses `canStart` and `startSession()`. Attachment enters `.starting`. Recovery then enters `.resynchronizing`, while clients receive and validate the new host baseline.

The host commits play only after the entire roster acknowledges that baseline. Gate simulation and game presentation on `.playing`, while keeping networking advancing through one update path. New session, join, and launch IDs keep packets from the retired connection out of this attempt.

After the baseline, create fresh movement and interaction controllers. Do not resume pending input, held buttons, smoothing offsets, old view references, or cached feedback. Restoring an absolute score is also separate from granting rewards: saved progress must not replay an earlier reward receipt.

The showcase's Multiplayer recovery lab saves progress 3, advances to 4, interrupts, and resumes the approved progress-3 checkpoint. It also lets you test an absent partner or a stalled baseline.

## Limits and native validation

Checkpoints allow 256 KiB total, including up to 64 KiB of application data and 512 records. Selected state must also fit the session's full replication packet limit. Loading validates sizes, metadata, version, and digest; schema validators run before hierarchy attachment. Keep validators free of side effects. Application observers invoked during attachment are not covered by a rollback transaction. A checksum detects corruption, not authenticated server authority or a safe currency transaction.

Defaults are 60 seconds to find the fresh match, 15 seconds for recovery synchronization, and 15 seconds for ordinary attachment. A missing player, invalid offer, released world, failed baseline, cancellation, or timeout ends the attempt with gameplay disabled. The app handles cleanup and any retry; host entities remain and client replicas are removed. All players need compatible party protocol version 2 and application versions.

Native activity recovery requires iOS/macOS 26+, configured party support, and authentication. Signed two-account testing remains **pending**. Verify original-code matching, cold/warm invitations, backgrounding on both devices, same-roster rejoining, baseline acknowledgments, cancellation, account changes, and stale-version rejection on signed builds. See <doc:multiplayer-validation-and-release-checks> for separating those observations from local checks.
