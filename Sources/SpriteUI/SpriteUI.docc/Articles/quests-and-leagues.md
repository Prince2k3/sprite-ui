# Quests and leagues

Define player goals and seasonal competition as deterministic values, then optionally report progress through Game Center.

## Own the rules separately from remote services

``SpriteUI/QuestJournal`` and ``SpriteUI/LeagueSeason`` live in Gameplay. They are `Codable`, `Sendable` values with explicit player identifiers, occurrence identifiers, and timestamps. They never read a clock, authenticate, write files, submit scores, or grant currency. Supply time from your application's chosen authority.

For a single-player game, keep these values in your saved player profile. For a shared competitive league, run the rules on an authoritative server and distribute validated snapshots. Local saves and stable result IDs are useful duplicate protection, not protection against a modified client or rollback to an earlier save.

``SpriteUI/GameCenterProgression`` is the optional bridge at `services.progression`. Game Center handles configured achievements and leaderboard scores; SpriteUI handles quest objectives, claim receipts, league rosters, divisions, and promotion policy. Reporting does not synchronize those custom rules between devices. Apple's [recurring leaderboards](https://developer.apple.com/documentation/gamekit/creating-recurring-leaderboards) can supply scheduled score competitions, but a leaderboard page alone is not a complete custom league roster.

## Create a quest occurrence

Every objective has a stable ID within its quest, an event metric, and a positive target. All objectives must finish. Progress percentage is the mean objective fraction, so two objectives contribute equally even if their targets differ. Prerequisites reference completed quests; claiming the earlier quest is not required. A single event can complete a prerequisite but cannot also advance the newly unlocked dependent.

This complete example uses explicit timestamps and event IDs. Recording a duplicate ID, even with a different payload, does nothing. Events that match no active quest are also retained, preventing an old event from counting after a quest unlocks. Record events in nondecreasing time order.

```swift
import Foundation
import SpriteUI

func makeCoinJournal(playerID: String, start: Date) throws -> QuestJournal {
    let window = try ProgressionWindow(start: start, end: start.addingTimeInterval(86_400))
    let daily = try QuestDefinition(id: "coins-day-1", title: "Collect five coins",
        objectives: [QuestObjective(id: "coins", metric: "coin", target: 5)],
        window: window, rewards: [QuestReward("gold", amount: 25)])
    var journal = try QuestJournal(playerID: playerID, quests: [daily], eventCapacity: 2_000)
    let collected = try QuestEvent(id: "pickup-001", metric: "coin", amount: 5, at: start)
    try journal.record(collected)
    try journal.record(collected) // Still five coins, not ten.
    let receipt = try journal.claim("coins-day-1", at: start)
    assert(receipt.rewards.first?.amount == 25)
    return journal
}
```

Time windows include their start and exclude their end. An unfinished quest expires at its end; a completed quest remains claimable. For another daily occurrence, create a definition with a new ID and interval. Never clear claim history and reuse an occurrence ID to make it repeat. A journal's definitions are immutable; catalog changes require an explicit application migration into a new profile/journal rather than silently reinterpreting an old ledger.

## Claim and save together

`claim(_:at:)` returns a ``SpriteUI/QuestRewardClaim`` once within the retained journal. It contains the player, quest occurrence, rewards, and a stable `id`. Grant the application's reward using that receipt ID and persist the receipt and wallet in one transaction. A failed save, a crash between granting and saving, concurrent copies, or restoring an older save can otherwise repeat a grant. This library does not provide a distributed wallet transaction.

JSON decoding replays validated events and claims rather than trusting persisted derived counters. Unknown versions, duplicate ledger entries, invalid definitions, impossible receipts, and out-of-order quest events throw. Each ledger has a configured capacity; reaching it rejects new unique records without forgetting prior IDs. Archive an old occurrence and migrate deliberately when a long-lived profile approaches its capacity.

With an ECS player, use ``SpriteUI/QuestJournalComponent`` and `entity.recordQuestEvent(_:)` / `claimQuestReward(_:at:)`. These update the component first, then publish ``SpriteUI/QuestEvents/Recorded`` or ``SpriteUI/QuestEvents/RewardClaimed``. Duplicate occurrences publish nothing. Register the component before world snapshots. Retain subscriptions for their desired lifetime.

```swift
import Foundation
import SpriteUI

@MainActor
func installPlayerQuests(in world: World, journal: QuestJournal) -> Entity {
    QuestJournalComponent.registerComponent(named: "player-quests")
    let player = Entity(name: "player")
    player.components.set(QuestJournalComponent(journal))
    world.addEntity(player)
    return player
}

struct ProgressionProfile: Codable {
    var journal: QuestJournal
    var season: LeagueSeason
}

func saveProgress(_ profile: ProgressionProfile, to url: URL) throws {
    try JSONEncoder().encode(profile).write(to: url, options: .atomic)
}

func loadProgress(from url: URL) throws -> ProgressionProfile {
    try JSONDecoder().decode(ProgressionProfile.self, from: Data(contentsOf: url))
}
```

The file example saves the progression values together. Include your application wallet and profile schema version in the same transaction if you grant rewards. ``SpriteUI/WorldSnapshot`` is another storage option for the registered component; a game-scoped season can remain in the profile.

## Run a season and preserve ties

Supply ``SpriteUI/LeagueTier`` values in ascending order and a fixed ``SpriteUI/LeagueParticipant`` roster. ``SpriteUI/LeagueRules`` supports nonnegative accumulated points (`.total`) or each member's best result (`.best`). Higher is always better. A ``SpriteUI/LeagueResult`` has one occurrence ID and can include several members; the whole result is validated before any score changes. Unique results can arrive out of chronological order, but every result's time must belong to the season window.

Standings are per division. Equal scores receive competition ranks such as `1, 1, 3`; player IDs provide stable display order without breaking the tie. Promotion and demotion apply to whole tied groups. If a group crosses the cutoff, it stays in its division. In a cohort smaller than the configured movement slots, promotion positions reserve priority over demotion positions. Boundary tiers cannot move beyond the tier list. Members with no accepted results have score zero and participate in these same tie rules.

`finalize(at:)` requires time at or after the end. It freezes placements and is idempotent. New results then fail, while already-recorded IDs remain no-ops. The application creates a future season explicitly, using the placements' `nextTierID` values, a new occurrence ID, a new window, and an appropriate roster. Nothing starts a timer or rolls over automatically.

```swift
import Foundation
import SpriteUI

func finishPracticeSeason(start: Date) throws -> LeagueSeason {
    let window = try ProgressionWindow(start: start, end: start.addingTimeInterval(3_600))
    var season = try LeagueSeason(id: "practice-1", title: "Practice",
        window: window,
        tiers: [LeagueTier(id: "bronze", title: "Bronze"), LeagueTier(id: "silver", title: "Silver")],
        participants: [
            LeagueParticipant(id: "alice", displayName: "Alice", tierID: "bronze"),
            LeagueParticipant(id: "bob", displayName: "Bob", tierID: "bronze")],
        rules: LeagueRules(scoring: .total, promotionPlaces: 1, demotionPlaces: 0))
    let result = try LeagueResult(id: "round-1", scores: ["alice": 20, "bob": 10], at: start)
    try season.record(result)
    try season.record(result) // Still 20 and 10.
    let placements = try season.finalize(at: window.end)
    assert(placements.first?.nextTierID == "silver")
    return season
}
```

## Report to Game Center explicitly

Use ``SpriteUI/GameCenterQuestMapping`` to map a specific quest occurrence to a configured achievement. Achievements are permanent and monotonic; a repeatable daily quest should not imply resetting an achievement. Choose a persistent milestone or use distinct configured achievement IDs where appropriate. All mappings validate before the first write, but a failed asynchronous batch can already have committed earlier reports.

Use ``SpriteUI/GameCenterLeagueMapping`` for one season and one configured leaderboard. Only the current player's points are submitted, during the local season window and before finalization. Configure the leaderboard to sort higher scores first and retain the player's best submitted cumulative total. Re-submitting a cumulative total must not add that total again on your remote backend.

For a recurring leaderboard, align the schedule in Xcode/App Store Connect with the local window and submit while the intended occurrence is active. The mapping's `context` is score metadata, not a way to select a past occurrence. This bridge does not create native configuration, verify remote occurrence timing, backfill previous occurrences, or download all entries as a promotion roster. A full shared league needs authoritative membership and season management beyond score submission.

```swift
import Foundation
import SpriteUI

@MainActor
func reportPlayerProgress(services: GameCenterServices, journal: QuestJournal,
                          season: LeagueSeason, now: Date) async throws {
    try await services.progression.report(journal, using: [
        GameCenterQuestMapping(questID: "coins-day-1", achievementID: "first-five-coins")
    ], at: now)
    try await services.progression.submit(season, using:
        GameCenterLeagueMapping(seasonID: season.id, leaderboardID: "season-score"), at: now)
}
```

The journal owner and season roster must use the current identity's `NetworkPeerID.rawValue` (the Game Center game-player ID in live mode). Foreign profiles are rejected. Cancellation/account changes retire pending local results; a server write may still have committed. No retry queue is installed, and reporting never claims local rewards or controls local promotion. `.preview(player:)` exercises these mappings in memory without Apple sign-in. Signed, configured multi-account verification remains separate from preview tests.

See <doc:game-center-services> for setup and cancellation semantics, <doc:saving-and-debugging> for world snapshots, and <doc:building-quests-and-leagues> for a complete asset-free exercise. The showcase's Game Services tab links to a progression lab with file save/load and folding support.
