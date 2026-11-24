# Player profiles and cloud saves

Persist typed player state and quest rewards locally, then explicitly opt into GameSave directory synchronization.

## Select the optional save product

`SpriteUISaves` is a separate target and library product. It depends on Gameplay for quest receipts, not on ECSCore, SpriteBackend, GameUI, or SpriteUIGameCenter. Select it and `import SpriteUISaves` for saves without the engine; `import SpriteUI` re-exports it for convenience. SpriteUICore and SpriteUIGameCenter do not depend on this product.

Local saving works on iOS 18 and macOS 15. The native [GameSave framework](https://developer.apple.com/documentation/gamesave) requires iOS/macOS 26 or later. ``SpriteUI/CloudSaveDirectory/isSupported`` distinguishes OS support from configuration; true does not mean the consuming app has the required entitlement or an iCloud account.

## Bind an identity and slot

``SpriteUI/PlayerProfileID`` separates `.guest(id)` from `.account(provider:id:)`. The same subject string in two namespaces does not share storage. The application supplies stable IDs and handles authentication; these values do not verify credentials, move guest data into an account, or detect Game Center sign-out. Recreate the store when your active game identity changes and retire outstanding application tasks. Game Center and iCloud identities are separate.

``SpriteUI/SaveSlotID`` names a slot such as campaign or autosave. Player and slot identifiers are hashed before use as filenames, so separators in a display identifier do not become path traversal. Use ``SpriteUI/ProfileSaveLocation/applicationSupport(appIdentifier:)`` for app-scoped durable local files. The store constructor does not create a save or start cloud work.

This complete example creates a quest profile and claims its reward inside one store transaction. Pass a new slot, or explicitly load an existing one before updating it; `create` never overwrites an existing or damaged slot.

```swift
import Foundation
import Gameplay
import SpriteUISaves

struct CampaignProgress: Codable, Sendable {
    var level: Int
    var quests: QuestJournal
}

func startCampaign(at now: Date) async throws -> PlayerProfile<CampaignProgress> {
    let player = PlayerProfileID.guest("local-player")
    let root = try ProfileSaveLocation.applicationSupport(appIdentifier: "com.example.game")
    let store = try PlayerProfileStore<CampaignProgress>(player: player, directory: root,
        schema: ProfileSaveSchema())
    let slot = try SaveSlotID("campaign")
    let goal = try QuestDefinition(id: "first-coins", title: "Two coins",
        objectives: [QuestObjective(id: "coins", metric: "coin", target: 2)],
        rewards: [QuestReward("gold", amount: 10)])
    var quests = try QuestJournal(playerID: player.subject, quests: [goal])
    try quests.record(QuestEvent(id: "pickup-1", metric: "coin", amount: 2, at: now))
    let profile = try await store.create(in: slot, state: CampaignProgress(level: 1, quests: quests), at: now)
    return try await store.update(profile, at: now) {
        try $0.claimQuestReward("first-coins", in: \.quests, at: now)
    }
}
```

The ``SpriteUI/PlayerProfile`` result carries owner, slot, schema version, revision, parent revision, save time, typed state, and ``SpriteUI/ProfileWallet``. Keep the returned revision after every successful write. `save(_:at:)` persists a modified candidate; `update(_:at:_:)` combines a synchronous candidate mutation and persistence. Use value-semantic `State` and keep closures brief. The actor serializes its operations, and a filesystem lock protects against independent stores/processes overwriting the same revision. A stale candidate throws `staleRevision`; reload and make an explicit game decision rather than blindly retrying an old state.

## Commit rewards with their receipts

`claimQuestReward(_:in:at:)` validates the journal's owner, claims the occurrence, and applies its rewards to the candidate wallet. ``SpriteUI/PlayerProfileStore/update(_:at:_:)`` encodes the state, journal receipts, wallet balances, and applied claim keys together in one atomic slot-file replacement. A throwing closure, validation/overflow failure, capacity failure, or failed atomic replacement does not persist a partial reward. `spend(_:currency:)` rejects negative amounts and overdrafts. A retained claim key prevents granting the same receipt again even if the application replaces its journal with an unclaimed copy.

This guarantee is local to the committed profile. Restoring an older backup, choosing another cloud version, copying data elsewhere, editing a save, or granting external rewards is not a distributed wallet transaction. Use a trusted server for valuable shared currency and competitive authority. The checksum detects accidental corruption; it is not encryption, authentication, or anti-cheat protection.

## Migrate payloads deliberately

``SpriteUI/ProfileSaveSchema`` has a current positive version and sequential migration closures. A step keyed by n receives version n's raw JSON payload and returns version n+1 JSON. Local loading and cloud-version inspection can migrate in memory but never rewrite the original file. Saving the loaded profile commits the new payload schema and a new revision. Missing migration steps, malformed data, and future schema/archive versions throw; do not replace them with a new game automatically.

```swift
import Foundation
import SpriteUISaves

struct OldProgress: Codable, Sendable { var score: Int }
struct CurrentProgress: Codable, Sendable { var points: Int; var stage: Int }

func campaignSchema() throws -> ProfileSaveSchema<CurrentProgress> {
    try ProfileSaveSchema(version: 2, migrations: [1: { bytes in
        let old = try JSONDecoder().decode(OldProgress.self, from: bytes)
        return try JSONEncoder().encode(CurrentProgress(points: old.score, stage: 1))
    }])
}
```

## Inspect and recover without erasing damage

`slots()` returns ``SpriteUI/ProfileSlotSummary`` values. Health is available, recoveryAvailable, or unreadable. A completely unreadable entry may not have a recoverable raw slot ID; its opaque storage key remains visible. Loading never silently falls back to older progress. After a successful replacement, the previous committed archive is retained in the same slot file. `recoverBackup(in:at:)` explicitly promotes it to a new revision, rolling back wallet and state together. It refuses to use recovery to overwrite a recognized future schema/archive version. A completely destroyed outer file may destroy both archives; keep your own exported backups if that risk matters.

`delete(_:)` explicitly removes the current slot and its retained backup, with the same revision check as saving. The library never deletes slots automatically. Default archive size is four MiB, configurable from one KiB through 64 MiB; limits include metadata/wallet. The outer slot file can contain two base64-encoded archives. Reads are size-checked and malformed/symbolic-link slot files are rejected. A cancelled task is checked before work and immediately before the atomic write, but cancellation after commit is not rollback. An atomic replacement protects against partial replacement; it is not a guarantee against all filesystem or hardware failure modes.

## Open a native cloud directory explicitly

``SpriteUI/CloudSaveDirectory`` wraps GameSave without exposing its native types. Configure the consuming app's iCloud capability, select iCloud Documents and its container, and use compatible signing/provisioning. `Tools/templates/saves-icloud.entitlements` is a starting plist whose placeholder container must be replaced; it does not configure an Apple account. Local saves require none of these capabilities.

Call `open()` at a deliberate transition and show progress while waiting. It does not display native sign-in or conflict alerts. Handle these statuses:

- `ready`: initial synchronization has completed and the directory is usable.
- `offline`: local data is usable, but cloud synchronization is incomplete.
- `localOnly`: GameSave is using local storage without cloud synchronization.
- `conflicted`: choose a whole-directory version before obtaining a writable store.
- `syncing`, `closed`, or `failed`: no writable store is available.

GameSave's available directory is separate from a default Application Support store. SpriteUI never copies the local profile into it or silently switches between the two; offer an explicit application import/migration policy when changing backends. This avoids replacing a cloud profile with unrelated local progress.

```swift
import Foundation
import SpriteUISaves

struct CloudProgress: Codable, Sendable { var points: Int }

@MainActor
func openCloud(container: String) async throws -> CloudSaveDirectory {
    let directory = try CloudSaveDirectory(containerIdentifier: container)
    try await directory.open()
    return directory // Retain it while inspecting conflicts or using stores.
}

@MainActor
func loadCloudProfile(directory: CloudSaveDirectory, player: PlayerProfileID) async throws -> PlayerProfile<CloudProgress> {
    let store = try directory.makeStore(for: player, schema: ProfileSaveSchema<CloudProgress>())
    return try await store.load(from: SaveSlotID("campaign"))
}
```

Retain the directory for the entire store lifetime. Close it on gameplay exit or a relevant application lifecycle transition. Stores and read-only inspectors from that session reject subsequent access with `directoryClosed`, including after a later reopen. Account-change notifications invalidate access before native teardown. A synchronous in-progress file transaction finishes before close invalidates its lease; native syncing never resumes in the middle of that transaction.

After GameSave makes a directory available, synchronization is paused while the game uses it. `close()` releases it for synchronization; close and reopen to refresh at another deliberate boundary. `requestUpload()` can trigger pending native work, but true only means uploads were pending. It is not a server acknowledgment that your latest reward is durably synchronized. Opening/finishing can be cancelled; late native completion is ignored. Native cloud work may continue after cancellation.

## Choose conflicts as whole directories

``SpriteUI/CloudSaveVersion`` contains an ephemeral choice ID, saving-device label, timestamp, and local flag. Inspect each version through a read-only store. Inspection cannot create lock files, modify slots, claim rewards, recover, or delete. Preview stores are invalidated when a choice is resolved. A future-schema version remains an error rather than being discarded in favor of an older profile.

```swift
import Foundation
import SpriteUISaves

struct ConflictProgress: Codable, Sendable { var points: Int }

@MainActor
func inspectChoices(directory: CloudSaveDirectory, player: PlayerProfileID) async throws -> [(UUID, Int)] {
    var choices: [(UUID, Int)] = []
    for version in directory.conflicts {
        let store = try directory.inspect(version.id, for: player, schema: ProfileSaveSchema<ConflictProgress>())
        let profile = try await store.load(from: SaveSlotID("campaign"))
        choices.append((version.id, profile.state.points))
    }
    return choices
}

@MainActor
func chooseVersion(_ id: UUID, directory: CloudSaveDirectory) async throws {
    try directory.resolve(using: id)
    if directory.status == .syncing { try await directory.finishSyncing() }
}
```

Selecting a version may replace every profile and slot in the directory, not just the currently displayed campaign. Do not automatically choose the highest score, latest timestamp, or greatest currency balance. Those policies can lose other valuable progress or duplicate grants. This milestone offers explicit selection; application-specific merging and authoritative economies remain application/server work.

`CloudSaveDirectory.preview(directory:status:)` exposes account-free ready/offline/local-only fixtures. `preview(versions:)` accepts explicit ``SpriteUI/CloudSavePreviewVersion`` directories; selection chooses the corresponding local fixture without uploading, copying, merging, or deleting directories. The showcase's Game Services tab links to a Profiles & saves lab with durable local profiles, guest/account and slot separation, atomic rewards, stale revision rejection, and two-device conflict previews. <doc:saving-player-profiles> provides a complete asset-free tutorial.

Signed iCloud multi-device verification is **pending**. Account-free tests validate rules, persistence, and adapter lifecycle seams, not Apple's live synchronization. On configured builds, verify offline edits, reconnect, conflict inspection/selection across devices, account changes, close/reopen, and launch on the package's older supported OS versions to verify local-only behavior.
