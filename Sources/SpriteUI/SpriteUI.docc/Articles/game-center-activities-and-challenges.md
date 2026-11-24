# Game Center activities and challenges

Route incoming activities deliberately, stage round results, and report each completed challenge attempt through the optional SpriteUIGameCenter product.

## Choose the service lifetime

``SpriteUI/GameCenterServices`` retains ``SpriteUI/GameCenterActivities`` and ``SpriteUI/GameCenterChallenges`` as `.activities` and `.challenges`. Keep one facade and one `.gameCenter(services)` host on a stable parent. Import `SpriteUIGameCenter` for the optional product, or `SpriteUI` for the complete SDK. Neither SpriteUICore nor SpriteUISaves acquires a new dependency.

Native activities and challenges require iOS/macOS 26+, configured Game Center resources, and an authenticated player. Explicit previews work on iOS 18/macOS 15 without accounts. Construction, installing the host, opening a catalog menu, and view appearance never authenticate, load catalogs, start rounds, or submit scores automatically.

This complete preview factory registers known routes before anything can deliver an incoming activity. Configuring fixtures performs no Apple work.

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

For a live facade, configure routes before presenting sign-in. The facade starts its configured listener after authentication, with routing ready even if GameKit delivers an intent during registration. Standalone services and previews can call `startListening()` explicitly. `hasPendingActivities()` is an explicit pre-authentication existence check; it does not display authentication UI or accept a request.

## Let the game accept an activity

``SpriteUI/GameCenterActivityRequest`` holds inert metadata, including a definition ID, properties, party code, and optional party URL. Incoming requests wait in `pendingRequests`; they never replace gameplay, load a level, spend currency, or restore a profile. Check content readiness, progression, and application-owned property allowlists before accepting. Reject unknown levels and choose what to do with an existing active or paused round before accepting another.

This complete helper requires the caller to have prepared the arena. It works without loading the definition catalog, matching a cold-launch intent. A real route should additionally check its own profile and content requirements.

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

Routes are capped at 256 definition IDs, the pending queue at 16, and the handled-instance ledger at 256 per service epoch. Unknown routes, wrong-account deliveries, ended activities, and overflow are not accepted. Duplicate incoming instances are not requeued. Raw GameKit activities with results already staged outside SpriteUI are rejected to avoid submitting another owner's scores.

Live listener ownership is exclusive within SpriteUI. `stopListening()` unregisters it and releases unconsumed requests, allowing those instances to be delivered again after restart; it retains the current round. `shutdown()` and account changes retire pending work and clear local state. An account change also dismisses the facade's current service presentation.

## Stage the latest round result

Load definitions explicitly before starting a new activity. `start(definitionID:partyCode:properties:)` merges supplied properties with definition defaults. Party codes must be valid for GameKit; previews use equal-length numeric parts such as `1234-5678`. Metadata exposes the party code and URL for an application-owned sharing flow. This milestone does not connect an activity party code to real-time `connect(in:schema:request:)` matchmaking.

The following complete helper starts one round, stages a replacement score even though it is lower, and finishes once. The returned receipt contains 40 points, not the previous 100. Use configured identifiers with live services.

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

Up to 64 distinct leaderboards and 64 achievements can be staged per round; replacements do not grow the attempt. Staging does not call the global leaderboard or achievement reporter. `finish()` ends the current attempt once and retains up to 64 local receipts. GameKit's end operation provides no server-durability acknowledgment; a receipt means the local end was requested.

`discard()` clears SpriteUI-staged results before ending and creates no completion receipt. It does **not** restore native quotas or consumed attempts. Follow the configured challenge's rules for an appropriate final score when the player quits. Releasing an owned native wrapper clears its staged results before cleanup rather than implicitly flushing gameplay scores.

## Report each completed challenge attempt

``SpriteUI/GameCenterChallengeDefinition`` describes configured native social challenges, separate from SpriteUI's custom quests and seasonal leagues. `load()` fetches metadata only. `hasActiveChallenges(for:)` is an optional separate query for a UI decoration. Repeatability is metadata; previews do not reproduce friend rosters, attempt quotas, invitations, or server competition state.

For direct reporting, provide the **latest completed-attempt score**, even below a personal best. Configure the native leaderboard's ordering to retain a best score; do not substitute that rolling best for each new attempt. Apple consumes attempts through the associated leaderboard submission. Never call both activity `finish()` and `challenges.submitAttempt` for the same attempt and leaderboard.

This complete preview exercise records 100 and then 20 as two attempts. Reusing the second ID with the same payload requests no additional report. The leaderboard's preview best remains 100.

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

An attempt ID is a local guard, not a Game Center idempotency key. A reused ID with changed data is rejected. `requested` records suppress another local report; errors or cancellation after reporting starts leave `uncertain` records that reject automatic retry. Scores may already have reached Apple or its offline queue. `context` is score metadata, not a remote deduplication token.

The in-memory ledger retains at most 256 IDs and refuses new IDs at capacity rather than forgetting prior submissions. Shutdown, account changes, and relaunch clear it. Games that need durable attempt tracking must persist application IDs and uncertainty policy themselves. There is no cross-device exactly-once transaction or automatic startup retry.

## Present native options explicitly

Use `.activities` and `.challenges` destinations for SpriteUI's catalog menus. Their Load buttons request metadata. `present(.activityDefinition(id))` opens the configured activity's native options; `.challengeDefinition(id)` opens challenge creation options, and `.challengeOverview` opens native challenge browsing. These screens use the facade's existing presentation host and availability checks. They do not prepare a game world for the app. Preview destinations display an explanation instead of contacting Apple.

Configure activity and challenge definitions, leaderboard associations, and supported app versions in App Store Connect, then enable Game Center and signing in the consuming app. Configure activity entry points and any required linked content so the app can prepare the correct route. Follow Apple's [activity guide](https://developer.apple.com/documentation/gamekit/creating-activities-for-your-game) and [challenge guide](https://developer.apple.com/documentation/gamekit/creating-engaging-challenges-from-leaderboards) for service setup and attempt rules.

The showcase's Activities & challenges lab and <doc:routing-game-center-activities> exercise cold requests, explicit acceptance, staged completion, lower-score attempts, and duplicate suppression without an account. They do not prove signed native invitations or remote challenge consumption. Verify those separately with configured resources and two test accounts, including cold/warm delivery, account changes, cancellation after reporting, and older-OS availability.
