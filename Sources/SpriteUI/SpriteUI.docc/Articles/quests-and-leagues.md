# Give players goals and a season to compete in

A daily goal asks the player to collect five coins and rewards 25 gold. A weekly competition adds each round's points and promotes the leaders. Both need stable records so loading a save or receiving the same result twice does not count it again.

``SpriteUI/QuestJournal`` tracks goals and claims. ``SpriteUI/LeagueSeason`` tracks a roster, scores, and placements. They are saveable values: your game supplies events and time, then decides when to persist or report the result.

## Turn coin pickups into quest progress

A quest describes objectives, rewards, and an optional time window. Each objective has a stable ID, an event metric such as `coin`, and a positive target. Every objective must finish; when showing a percentage, each objective contributes equally.

Give each real pickup a stable event ID. The journal ignores a repeated ID even if its payload changes. It also remembers events that matched no active quest, so an old pickup cannot count later when a goal unlocks. Record quest events in nondecreasing time order.

This example records a five-coin pickup twice. The player still has five coins of progress and can claim one 25-gold reward.

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

The window includes its start and excludes its end. An unfinished quest expires at the end, while a completed quest remains claimable. Tomorrow's daily quest needs a new occurrence ID and window; clearing history and reusing today's ID would undermine duplicate protection.

A prerequisite unlocks on completion, without waiting for a claim. The event that completes it cannot also advance the newly unlocked dependent quest. Definitions stay fixed inside a journal, so changing the catalog requires a profile migration rather than reinterpreting old events.

## Save the claim and the wallet together

`claim(_:at:)` returns a ``SpriteUI/QuestRewardClaim`` containing the player, quest occurrence, rewards, and stable receipt ID. It records the claim but does not itself grant your game's currency.

Use the receipt ID when granting the reward, and persist the claim and wallet together. Otherwise, a crash between granting gold and saving the journal could grant it again. <doc:player-profiles-and-cloud-saves> shows a profile store that commits this local transaction for you.

For an ECS player, `QuestJournalComponent` stores the journal and entity helpers update it before publishing quest events. Retain subscriptions for as long as the game needs them. Register the component before taking world snapshots.

The following example attaches the journal to an entity, then shows a file profile holding both quests and a season.

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

The file write keeps those progression values together. Include the wallet and a profile schema version in that same transaction if rewards change currency. A registered journal component can instead travel in a `WorldSnapshot`.

## Add rounds to a season

Create tiers in ascending order, a fixed participant roster, and a season window. Choose `.total` to accumulate nonnegative points or `.best` to retain each member's best result. Higher scores always rank first.

A result has an occurrence ID and can contain several players' scores. Validation happens before any score changes. Repeated result IDs do nothing. Unlike quest events, unique results can arrive out of time order, provided their timestamps fall inside the season.

Here, Alice earns 20, Bob earns 10, and receiving `round-1` again changes neither score. Finalizing at the window's end promotes Alice to silver.

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

Equal scores share competition ranks such as `1, 1, 3`. Stable player IDs order the display without breaking ties. Promotion and demotion move whole tied groups; a group that crosses the cutoff stays in its division. In a small cohort, promotion slots take priority over demotion slots. Players with no results have zero and follow the same rules.

`finalize(at:)` freezes placements at or after the end. Repeating it returns the same outcome; new results then fail, while recorded IDs remain no-ops. Create the next season with a new ID, window, roster, and the placements' `nextTierID` values. No timer starts a season for you.

## Report milestones and points to Game Center

Your quest and league rules stay in the game. ``SpriteUI/GameCenterProgression`` can report a quest to a configured achievement or submit the current player's season score to a leaderboard.

Achievements are permanent and only increase. Map a daily quest to a lasting milestone when appropriate, rather than implying that an achievement resets daily. The season leaderboard should sort higher first and retain the best submitted cumulative total, rather than adding the same total again.

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

Use the current identity's `NetworkPeerID.rawValue` for the journal owner and season participant ID; live mode uses the Game Center game-player ID. Reporting rejects foreign profiles and never claims rewards or chooses promotions.

For a recurring leaderboard, align its configured schedule with your season and submit while that occurrence is active, before local finalization. `context` is score metadata, not a selector for a past occurrence. A leaderboard does not supply a complete custom roster or promotion policy.

Read <doc:game-center-services> for reporting and setup, or <doc:player-profiles-and-cloud-saves> to make quest rewards part of a durable local profile.

## Limits and shared competition

Journals and seasons do not read a clock, write a file, authenticate, or synchronize themselves. Single-player rules can live in a local profile. A competitive league needs server-owned time, membership, results, and season management. Stable IDs prevent duplicates in retained history; they do not protect against a modified client or restoring an older save.

Decoding validates events and claims rather than trusting saved counters. Invalid versions, definitions, ledger entries, receipts, and quest-event ordering throw. Ledgers reject new unique records at capacity instead of forgetting IDs; archive old occurrences and migrate as they fill.

Game Center reports are not one transaction: an earlier write may succeed before a later one fails. Cancellation or account changes retire local results without undoing a server write. No retry queue is installed. Preview mappings run in memory; signed configured multi-account verification remains pending.
