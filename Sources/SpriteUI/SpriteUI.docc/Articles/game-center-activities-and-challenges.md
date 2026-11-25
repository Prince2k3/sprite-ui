# Invite players to a round and report its result

A friend sends an invitation to a score-attack arena while the player is midway through a campaign. The game needs to hold that invitation, prepare the right arena, and report the score of the round they actually played.

An activity carries the entry point and round results. A native challenge uses a configured leaderboard to compare attempts. Neither replaces your game's level loading or progression rules.

## Give incoming rounds a place to wait

Retain one ``SpriteUI/GameCenterServices`` above the screens that share it, with one `.gameCenter(services)` modifier. Its `.activities` and `.challenges` services are available through `SpriteUIGameCenter`, or the complete `SpriteUI` product.

Register routes before sign-in. In this preview, the score-attack route names an arena, and the sprint challenge points to a leaderboard. Nothing contacts Apple.

```swift
import SpriteUIGameCenter

@MainActor
func makeSocialPractice() throws -> GameCenterServices {
    let services = GameCenterServices.preview()
    try services.activities.configurePreview([
        .init(id: "score-attack", title: "Score attack",
              defaultProperties: ["level": "arena"], supportsPartyCode: true)
    ])
    try services.activities.configureRoutes(["score-attack"])
    try services.challenges.configurePreview([
        .init(id: "sprint", title: "Sprint", leaderboardID: "challenge-score", isRepeatable: true)
    ])
    return services
}
```

A live facade starts its configured listener after authentication. Standalone services and previews can call `startListening()`. `hasPendingActivities()` checks whether an entry is waiting before authentication without accepting it or showing sign-in.

## Ask the game whether it can accept

An incoming ``SpriteUI/GameCenterActivityRequest`` waits in `pendingRequests`. Use its definition and properties to decide whether the player has the content and progression needed. Decide what should happen to the current round before accepting another.

Here, an unknown arena is declined. A known arena stays pending while it loads. The helper can handle a cold-launch request without first loading the definition catalog.

```swift
import SpriteUIGameCenter

@MainActor
func acceptPreparedArena(_ request: GameCenterActivityRequest,
                         services: GameCenterServices, arenaIsReady: Bool) throws {
    guard request.activity.definitionID == "score-attack",
          request.activity.properties["level"] == "arena" else {
        try services.activities.decline(request: request.id)
        return
    }
    guard arenaIsReady else { return } // Keep the request pending until preparation completes.
    _ = try services.activities.accept(request: request.id)
}
```

After acceptance, the app chooses the screen. For a shared real-time arena, continue through `services.party.findMatch()` and <doc:activity-party-matchmaking-and-handoff>.

## Keep the result for this round

A player might earn 100 points, restart, then finish with 40. Staged activity scores describe the latest result, so setting 40 replaces 100 rather than preserving a personal best.

Load definitions before starting a new activity. The helper starts one round, pauses and resumes it, replaces its score, and finishes it once.

```swift
import SpriteUIGameCenter

@MainActor
func completePracticeRound(using services: GameCenterServices) async throws -> GameCenterActivityCompletion {
    _ = try await services.activities.load()
    _ = try await services.activities.start(definitionID: "score-attack", partyCode: "1234-5678")
    try await services.activities.setScore(100, for: "activity-score")
    try services.activities.pause()
    try services.activities.resume()
    try await services.activities.setScore(40, for: "activity-score")
    try services.activities.setAchievementProgress(25, for: "arena-progress")
    return try services.activities.finish()
}
```

Staging results does not call the global achievement or leaderboard reporter. `finish()` ends the attempt and returns a local receipt with the staged 40 points. GameKit provides no server-durability acknowledgment for this end operation.

`discard()` clears the staged results before ending, but cannot refund a native attempt or quota. Choose the appropriate final score for a player who quits according to the challenge's rules.

## Submit a challenge attempt once

A challenge attempt also uses the latest completed score, even when it is below the player's best. Configure the leaderboard's ordering to preserve the best score; still submit each attempt's own result. Apple consumes attempts through the associated leaderboard submission.

Choose one reporting path for an attempt and leaderboard: activity `finish()` or `challenges.submitAttempt`. Calling both can report it twice.

This example records 100 and 20 as separate attempts. Reusing the second ID with the same data suppresses a third local submission. The preview leaderboard still shows a best of 100.

```swift
import Foundation
import SpriteUIGameCenter

@MainActor
func practiceChallengeAttempts(using services: GameCenterServices) async throws -> Int {
    _ = try await services.challenges.load()
    _ = try await services.challenges.submitAttempt(score: 100, for: "sprint", attemptID: UUID())
    let second = UUID()
    _ = try await services.challenges.submitAttempt(score: 20, for: "sprint", attemptID: second)
    _ = try await services.challenges.submitAttempt(score: 20, for: "sprint", attemptID: second)
    return services.challenges.attempts.count // Two in a fresh practice service.
}
```

The attempt ID protects this service's memory, not Apple's servers. Reusing it with changed data fails. If reporting starts and then errors or is cancelled, the attempt becomes `uncertain`: Apple or its offline queue may already have received it. Do not automatically retry it. Persist your own IDs and uncertainty decisions if they must survive relaunch or account changes.

## Let players browse native options

The `.activities` and `.challenges` destinations show catalog menus with Load buttons. `.activityDefinition(id)` presents an activity's native options; `.challengeDefinition(id)` presents challenge creation options; `.challengeOverview` opens browsing. These screens use the existing presentation host. Your app still prepares the game world.

The showcase's Activities & challenges lab lets you follow a queued invitation through acceptance, staged results, and completion.

## Availability and limits

Native activities and challenges require iOS/macOS 26+, authentication, and configured Game Center resources. Previews work on iOS 18/macOS 15 but do not reproduce friend rosters, attempt quotas, or remote competition. Configure definitions, leaderboard associations, supported versions, and linked content using Apple's [activity guide](https://developer.apple.com/documentation/gamekit/creating-activities-for-your-game) and [challenge guide](https://developer.apple.com/documentation/gamekit/creating-engaging-challenges-from-leaderboards). Challenge approval is required for player availability.

Incoming requests are deduplicated; unknown routes, wrong accounts, ended activities, and activities with externally staged results are rejected. The service accepts up to 256 routes, 16 pending requests, and 256 handled instances per service epoch. Stopping the listener releases unconsumed requests for later delivery while keeping the current round.

A round can stage 64 leaderboards and 64 achievements; the service keeps 64 completion receipts. The attempt ledger holds 256 IDs and rejects new ones when full. Shutdown, account changes, and relaunch clear its memory. Signed two-account invitation and challenge verification remains pending, including cold/warm entry, cancellation after reporting, and older-OS availability.
