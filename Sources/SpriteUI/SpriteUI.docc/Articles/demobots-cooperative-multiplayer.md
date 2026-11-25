# DemoBots cooperative multiplayer

Exercise the library's multiplayer layers together in a complete two-player debug arena alongside the separate DemoBots campaign.

## Start with the local round

Select the DemoBotsGame package product for the reusable example, or open Examples/DemoBots/DemoBots.xcodeproj and choose Co-op Debug Arena from the campaign home menu. The full example uses Apple's existing DemoBots artwork. The asset-free fallback uses procedural sprites and needs no asset catalog. Neither construction nor appearance creates a party or authenticates.

This complete app-root view hosts the full co-op menu, arena, controls, local partner, recovery actions, and explicit optional Game Center setup. The example product depends on SpriteUI; it is not re-exported by the engine umbrella.

```swift
import DemoBotsGame
import SwiftUI

@MainActor
struct ContentView: View {
    var body: some View { DemoBotsCoopView(usesArtwork: false) }
}
```

Start local co-op runs two independent GameCenterServices preview coordinators over GameCenterPartyPreview. It uses the actual activity readiness/handoff and replica-baseline machinery, not a single shared world masquerading as two players. The local human is the client; an optional scripted teammate owns the host world. Turn teammate movement/firing off to inspect your own contributions. Delay, Unreliable loss, and Vary packet delay exercise adverse local delivery; reliable readiness/recovery and final receipts do not drop. The displayed queue remains bounded. Preparation advances the fixture clock until the required readiness/offer arrives instead of assuming zero delay. Preview matchmaking/handoff/recovery deadlines use that same explicit clock; native services retain wall-clock deadlines. A 120-second round ends after curing four corrupted bots or running out of time. Each bot needs two confirmed hits. Score is absolute shared round state, not a replayed reward.

This first co-op arena has an open floor and rectangular center bounds. It deliberately does not claim predictive movement through the campaign's irregular collision walls or deterministic native physics. The campaign's levels, checkpoints, and game logic remain separate and retain their existing behavior.

## Give each layer one owner

The retained `DemoBotsCoopSession` owns one local network world, an optional partner world, party services, prediction/interaction controllers, canonical observer locations, approved recovery metadata, and operation cancellation. Network worlds are headless kinematic simulation. GameView renders a separate local presentation world that mirrors inert actor state and the owned predicted visual. It never runs another network-session update or grants effects from visual positions.

Host rules run in the fixed phase after remote movement controllers. Only the host changes corruption, shared time, round completion, or score. The client receives a fresh movement epoch after its baseline and submits sequenced intent. Beams aim from an exact host-issued interaction view, selecting a nearby eligible bot, with facing as the fallback. The host validates cooldown, range, view age, target lifetime, and current round state. Already-cured bots cannot award another cure. Burst commands do not bypass the cooldown.

NetworkSpatialInterest follows canonical player positions. The round score/time is always relevant; owned players and ancestors stay present. NetworkReplicationBudget bounds entity traffic separately for each player while application commands and final receipts remain in their independently bounded lane. The UI shows entity/application bytes, scope, and deferrals. Interaction views include only published scope identities.

The example's actor/round schemas contain only portable validated values. Native bodies, playback resources, input sessions, runtime weak references, presentation entities, and controller histories are not replicated. See <doc:replication-interest-and-bandwidth>, <doc:multiplayer-prediction-and-reconciliation>, and <doc:multiplayer-interactions-and-lag-compensation> for the underlying contracts.

For headless experiments, this complete helper constructs a stopped local fixture. A button or test then calls start. Advance it exactly once per bounded application update; the bundled DemoBotsCoopView already owns that pump, so do not add another while using the view.

```swift
import DemoBotsGame

@MainActor
func makeStoppedCoopExperiment() -> DemoBotsCoopSession {
    let game = DemoBotsCoopSession(usesArtwork: false)
    game.previewPartnerMoves = false
    game.previewPartnerFires = false
    return game
}
```

## Keep input and feedback out of replay

Touch movement, keyboard WASD/arrows, and the gamepad left stick share PlayerInputHub and PlayerInputSession action maps. Space, the gamepad south button, and the on-screen Debug Beam button request a fresh shot. Controller ownership is explicit. Losing focus cancels input; returning requires neutral/released controls. Resizing/folding cancels captured touch input and rebuilds the thumbstick without replacing the match or its network worlds.

Predicted beam lines are short-lived local feedback. Confirmed hits produce local particles/audio once on a final client receipt. Only new authoritative receipts change corruption/score; replayed movement never runs sound or reward code. Host-local shots use the same inert geometry and host cooldown directly, without pretending to be remote commands. The teammate's host simulation is a local fixture policy, not Game Center matchmaking with another account.

## Recover an approved round explicitly

Save recovery point captures a host-approved checkpoint with selected actor/round state and a validated versioned time payload. It writes one local file under application-scoped Application Support. The retained exact descriptor approves that file for this run. Appearance never reads or selects it. An unrelated older file cannot silently resume another match, and the campaign save is untouched.

Interrupt clears input, pending feedback, controllers, and old connection ownership. Rejoin saved round requests a fresh same-roster activity match. The original host offers its approved checkpoint. Fresh worlds are prepared through GameCenterParty.prepareRecovery; host proxies, relevance, and runtime systems are rebuilt explicitly. The original host/roster/content policy and client baseline gate still apply. New prediction/action epochs start with no old input history. Saved round state restores score absolutely; it does not grant achievements or rewards again.

A native client chooses Accept host recovery offer after the fresh match receives the offer. Native hosts wait for both participants to ready before Start prepared round. A lost checkpoint, incompatible file, absent original player, or failed baseline leaves gameplay disabled and surfaces the error; retry is deliberate. Closing the co-op screen stops the services and leaves the campaign at its own home menu.

This complete application hook illustrates lifecycle ownership outside the bundled view. The bundled view already performs this cleanup, including neutral input on inactive and party interruption on background; do not run a second lifecycle owner around it.

```swift
import DemoBotsGame

@MainActor
func interruptCoopFromGameMenu(_ game: DemoBotsCoopSession) {
    game.move(.zero)
    game.interrupt()
}
```

## Configure live Game Center separately

Use live Game Center is an explicit mode switch that stops the previous local fixture. Sign in explicitly, load/start the configured `dev.spriteui.demobots.coop` activity, and enter the same party code on both players. Native activity parties require OS 26+ and a configured party-capable two-player activity definition in App Store Connect. Use the matching bundle ID, signed Game Center entitlement, provisioning, and multiplayer compatibility. Keep the co-op view's one gameCenter host stable through lobby, gameplay, and recovery. Queued configured invitations are accepted explicitly; they never replace an active round automatically.

Native setup, cold activity routing, matching, disconnect/rejoin, account changes, and actual network delivery must be verified with two signed test accounts/devices. The user chose to leave that work pending for this checkout. Local fixtures, setup templates, successful builds, and unit tests do not establish live Game Center behavior. See <doc:game-center-services>, <doc:activity-party-matchmaking-and-handoff>, and <doc:multiplayer-recovery-and-rejoining>.

See <doc:multiplayer-validation-and-release-checks> for the repeatable local gate, signing templates, and pending native matrix.

The local automated round covers delayed/lossy handoff and recovery, complete handoff, prediction convergence, host cooldowns, a shared win, approved checkpoint restoration, cancelled preparation, and input neutralization. Follow <doc:playing-a-cooperative-demobots-round> to exercise the same flows in the simulator before signed testing.
