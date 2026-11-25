---
title: App Store Connect Game Center Setup
tags: [spriteui, game-center, developer-tools]
created: 2026-11-24
updated: 2026-11-24
status: active
type: permanent
---

# Set up Game Center draft metadata

`game-center-connect.py` reuses a consuming game's Xcode `.gamekit` bundle to create Game Center draft definitions and localized text through Apple's App Store Connect API. It also reads the server's component version/review states and Game Center enablement for app versions. It runs from a checkout or CI with Python 3.10+ and OpenSSL; no third-party Python packages are required.

[[../README.md]] describes the library. [[../Examples/DemoBots/readme.md]] supplies a complete local configuration with achievements, a classic leaderboard, activities, and a linked challenge. The CLI sits in the existing `Tools/` folder alongside the built-app checker; it is developer tooling, not an app dependency or part of the `SpriteUIGameCenter` runtime target.

## Prepare the app and API access

Create the matching app record in App Store Connect and enable Game Center there first. Generate an API key with the role and app access needed to read and create Game Center resources. The tool resolves the app by its exact bundle ID and obtains the separate Game Center detail ID from Apple.

For a team API key, configure these environment variables in your shell or CI secret store:

```sh
export ASC_KEY_ID="YOUR_KEY_ID"
export ASC_ISSUER_ID="YOUR_ISSUER_ID"
export ASC_PRIVATE_KEY_PATH="/absolute/path/AuthKey_YOUR_KEY_ID.p8"
```

For an individual key, use `ASC_KEY_ID` and `ASC_PRIVATE_KEY_PATH`, omit the issuer, and pass `--individual-key` to each online command. The CLI signs ES256 JWTs with a ten-minute lifetime and refreshes them as needed. It keeps generated tokens in memory. An existing JWT can instead be supplied through `ASC_TOKEN`; that token's expiry is managed by its caller. Keys and tokens belong outside the repository.

See Apple's [API key guide](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api) and [JWT guide](https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests).

## Validate offline

From the repository root:

```sh
python3 Tools/game-center-connect.py validate \
  --bundle-id dev.spriteui.demobots \
  --gamekit Examples/DemoBots/App/DemoBotsLocal.gamekit
```

This command reads the configuration without credentials or network access. It validates required metadata, types, unique identifiers/locales, player and score ranges, and challenge-to-leaderboard links. It rejects unsupported nonempty resource categories and attributes instead of silently discarding them. A path directly to `gameCenterResources.json` also works.

The supported subset is ungrouped, app-scoped achievements, classic leaderboards, activities, challenges, and their text localizations. Recurring boards, leaderboard sets, grouped resources, activity associations/fallback URLs, and artwork synchronization should use Xcode's sync workflow. The local `allowedDurations` compatibility field is deliberately omitted from API requests: the current API challenge create schema does not accept it.

## Inspect the actual server state

```sh
python3 Tools/game-center-connect.py status --bundle-id dev.spriteui.demobots
```

`status` uses GET requests only. Its JSON report includes permanent resource identifiers, attributes, each component's version/state, and app versions with Game Center's `enabled` value and the linked App Store version's metadata. Missing app records, inaccessible resources, and authentication/role failures produce actionable errors. A missing challenge on the server and an empty native `GKChallengeDefinition.all` result are separate observations.

## Review a plan, then create missing drafts

```sh
python3 Tools/game-center-connect.py plan \
  --bundle-id dev.spriteui.demobots \
  --gamekit Examples/DemoBots/App/DemoBotsLocal.gamekit \
  > /tmp/demobots-game-center-plan.json
```

Inspect the JSON file. It contains the resolved app, Game Center detail ID, proposed requests, dependency references, conflicts, remaining manual steps, and a `sha256` fingerprint. `plan` uses GET only. Copy that fingerprint into the explicit write command:

```sh
python3 Tools/game-center-connect.py apply \
  --bundle-id dev.spriteui.demobots \
  --confirm-app dev.spriteui.demobots \
  --gamekit Examples/DemoBots/App/DemoBotsLocal.gamekit \
  --plan-sha256 "COPY_SHA256_FROM_REVIEWED_PLAN"
```

`apply` rereads the server and recomputes the plan. A changed fingerprint, incorrect target, or any conflict stops it before writing. It creates missing definitions with initial draft versions, creates missing localizations on editable drafts, and associates newly created challenges with their configured leaderboards. Current requests use `/v2/gameCenterLeaderboards`, `/v2/gameCenterAchievements`, `/v1/gameCenterActivities`, and `/v1/gameCenterChallenges`, with version-scoped localization endpoints. The pinned request contract is Apple OpenAPI 4.6.1.

Existing matching records are reused. Existing metadata, text, archive state, or challenge-link differences are reported as conflicts for explicit editing in App Store Connect/Xcode. Records absent from the local bundle are preserved. A matching LIVE component needs no change; adding missing text to a LIVE or in-review version is refused.

Writes are not one transaction. If a request fails after Apple accepts it, some drafts may exist even though the command reports failure. The CLI stops, reports the count of confirmed writes, and never automatically retries a POST. Run `plan` again, review the remaining operations, and apply the new fingerprint. It discovers accepted resources by their vendor identifiers and locales, avoiding duplicate creation on an unchanged rerun. Duplicate server identifiers or ambiguous versions stop reconciliation.

All commands print JSON; errors go to stderr. Exit status is `0` for success, `1` for a configuration/API/apply error, `2` for invalid CLI arguments, and `3` for a plan containing conflicts. A successful plan or apply does not mean the configuration is ready for release.

## Complete artwork, app setup, and review

The tool creates draft text metadata. Complete the required artwork in Xcode or App Store Connect, enable Game Center for the intended app version, review multiplayer compatibility and challenge minimum platform versions, and submit the components for review. If this is the app's first leaderboard, submit it with the challenge. Apple controls approval and availability to players; the script cannot grant approval. See [Manage challenges](https://developer.apple.com/help/app-store-connect/configure-game-center/manage-challenges) and [Game Center testing](https://developer.apple.com/help/app-store-connect/configure-game-center/overview-of-testing-game-center/).

Configure the consuming target's Game Center entitlement and signing separately. Check the built app with:

```sh
python3 Tools/check-game-center-setup.py /path/to/MyGame.app --bundle-id com.example.MyGame --json
```

Xcode's local Debug Mode/Game Progress Manager workflow remains separate from server-backed configuration and testing. Native authentication, component loading, score reporting, and two-account multiplayer still require device verification. Local configuration, API success, and approval status alone do not prove the installed app's runtime results.

## Verification

```sh
python3 -B -m unittest discover -s Tools/tests
```

Tests use an in-memory fake API, a pinned subset of Apple's [public OpenAPI specification](https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip), and temporary generated keys. The new `Tools/tests/fixtures/` folder holds that contract in [[tests/fixtures/asc-game-center-4.6.1.json]]. Tests exercise payload contracts, draft/link dependencies, reruns, partial writes, conflicts, pagination, credentials, and JWT signature verification. They do not contact an Apple account. Live App Store Connect provisioning remains unverified until run with a developer's explicitly configured credentials.
