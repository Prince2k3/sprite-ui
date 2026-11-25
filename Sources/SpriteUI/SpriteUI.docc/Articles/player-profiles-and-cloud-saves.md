# Save a player's progress and rewards

A player collects the last quest coin, receives ten gold, and closes the game. The next launch must restore both the completed quest and the wallet. Saving them separately risks giving the reward again or losing it after a crash.

Keep them in one typed profile, commit the local change together, and add cloud synchronization when the local save flow works.

## Give each player a save slot

``SpriteUI/PlayerProfileStore`` saves your `Codable` state alongside a wallet and reward receipts. Use the optional `SpriteUISaves` product for saves without the engine, or import the complete `SpriteUI` product.

A ``SpriteUI/PlayerProfileID`` separates guests from accounts and separates account providers. Your app supplies stable IDs and handles authentication. Recreate the store when the active identity changes; a Game Center identity and an iCloud identity are separate choices.

A ``SpriteUI/SaveSlotID`` names progress such as campaign or autosave. `ProfileSaveLocation.applicationSupport` supplies an app-scoped local directory. Constructing the store does not create a save.

This example creates a new campaign and claims a completed quest inside a store update. For an existing slot, load it first: `create` refuses to overwrite existing or damaged data.

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

Keep the returned profile after every successful write. It carries the revision needed for the next update. If another store or process has saved first, a stale candidate throws `staleRevision`. Reload and decide how the game should proceed rather than blindly saving the old state again.

## Commit the reward with the claim

`claimQuestReward(_:in:at:)` checks the journal owner, claims the quest, and updates the candidate wallet. `update` writes the state, receipt, balances, and applied claim keys in one atomic slot-file replacement.

If the mutation, validation, encoding, or replacement fails, it does not persist half a reward. A retained claim key also stops the same receipt granting gold again if your app replaces the journal with an unclaimed copy. Use brief synchronous update closures with value-semantic state. `spend(_:currency:)` rejects negative amounts and overdrafts.

## Keep old saves readable as the game changes

Suppose an earlier game saved `score`, while the new game saves `points` and `stage`. A migration converts the old payload instead of treating it as a new campaign.

``SpriteUI/ProfileSaveSchema`` names the current version and each sequential conversion. This step reads version 1 and returns version 2 with the old score preserved.

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

Loading migrates in memory without rewriting the file. Saving the returned profile commits the new format and revision. Missing steps, malformed data, and future versions throw. Show a recovery choice or error rather than automatically overwriting the player's progress.

## Offer recovery when a save is damaged

`slots()` reports whether a slot is available, has recovery available, or is unreadable. The slot retains the previous committed archive after replacement. `recoverBackup(in:at:)` promotes that backup to a new revision, rolling back state and wallet together. It refuses to overwrite a recognized future version.

Recovery is a player/app decision; loading never silently switches to older progress. If the outer file is destroyed, both archives may be lost. `delete(_:)` removes the slot and backup only when called with the current revision. Completely unreadable entries still expose an opaque storage key even when their original slot ID cannot be recovered.

## Open cloud storage at a game transition

Cloud saving uses ``SpriteUI/CloudSaveDirectory``, backed by Apple's GameSave framework. Configure iCloud Documents, a container, signing, and provisioning in the consuming app. Local saves do not need these capabilities.

Open the directory at a transition where the UI can show waiting or conflict choices. `open()` does not present sign-in or conflict alerts for you. After opening, create a store from that directory rather than reusing an Application Support store.

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

A `ready` directory has completed initial synchronization. `offline` permits local use while cloud synchronization is incomplete; `localOnly` has no cloud synchronization. `conflicted` requires a choice before writing. `syncing`, `closed`, and `failed` provide no writable store.

Retain the directory while using its stores. Native synchronization pauses while the game uses an available directory; `close()` releases it for synchronization. Close and reopen at another transition to refresh. Stores from a closed session stay invalid even after reopening, so create new ones. Account changes also invalidate access. An in-progress synchronous file transaction finishes before its lease is invalidated.

Cloud and default local storage are separate. If the game changes backends, provide an import policy rather than assuming the cloud directory already contains the local campaign.

## Help the player choose between device versions

Two devices can make different offline progress. Inspect the conflicting directory versions through read-only stores and show useful game values, such as level or points, before asking which to keep.

This example reads points from each choice, then resolves the chosen version and finishes synchronization if needed.

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

The choice replaces the whole directory, potentially affecting every player profile and slot inside it. A higher score or newer timestamp alone may lose other progress or repeat rewards. Read-only inspectors cannot claim, recover, or delete, and become invalid after resolution. Future-schema data remains an error rather than an excuse to select an older save.

The showcase's Profiles & saves lab lets you inspect local rewards, stale revisions, and two-device conflict previews. Continue with <doc:quests-and-leagues> to define the goals stored in the profile.

## Limits and cloud validation

Local saving supports iOS 18/macOS 15. Native GameSave requires iOS/macOS 26+; `isSupported` checks OS availability, not entitlement or account readiness. Preview directories exercise choices without uploading or merging data.

Local atomic reward commits do not protect against restored older backups, edited saves, or independent cloud versions. Valuable shared currency needs server authority. The checksum detects accidental corruption, not tampering. Atomic replacement protects against partial replacement, not every hardware failure. Archive size defaults to four MiB, configurable from one KiB to 64 MiB, including wallet and metadata. Symbolic-link and malformed slot files are rejected.

Cancellation after a file commit cannot roll it back. `requestUpload()` returning true means uploads were pending, not that the latest reward is durably on a server; native cloud work can also continue after cancellation.

Signed iCloud multi-device verification remains **pending**. Test offline edits, reconnect, conflict inspection and selection, account changes, and close/reopen on configured devices. Also test local saving on older supported systems. Account-free previews cannot establish Apple's live synchronization.
