# Explore the DemoBots sample app

@Metadata {
    @PageKind(sampleCode)
    @CallToAction(url: "https://github.com/Prince2k3/sprite-ui/tree/main/Examples/DemoBots", purpose: link, label: "View the sample")
}

Repair the corrupted robots before the timer runs out. DemoBots puts movement, bot decisions, collisions, animation, and SwiftUI controls into one playable game, so you can see how the pieces cooperate beyond a small code example.

This is a walkthrough of Apple's [DemoBots sample](https://developer.apple.com/library/archive/samplecode/DemoBots/Introduction/Intro.html) rebuilt with SpriteUI instead of GameplayKit. It is a sample app to explore after the core lessons, rather than a course lesson or a prerequisite for learning SpriteUI.

## Play the campaign first

Open `Examples/DemoBots/DemoBots.xcodeproj` and run the DemoBots scheme for iPhone/iPad or DemoBotsMac for Mac. The ordinary schemes launch the campaign. `Examples/DemoBots/readme.md` explains controls, setup, and the sample's scope.

The campaign keeps all three original level layouts, patrol configurations, scenery, and robot animation artwork from DemoBots 2.3. Retained Apple terms are in `Examples/DemoBots/APPLE-LICENSE.txt`. This is a recreation of the game with SpriteUI, rather than a port of every original platform feature. The game module imports neither SpriteKit nor GameplayKit.

Start a level, move toward a red bot, and hold the rechargeable Debug Beam on it until it turns green. GroundBots pursue and attack; FlyingBots attack an area, and curing one also cures nearby bots. Try pausing and restoring a checkpoint, then open Scene tools to inspect the actors that make the round work.

## Follow a frame through the campaign code

Begin with the SwiftUI host, then follow its retained session into the simulation. These are the main repository entry points:

| File under `Examples/DemoBots/` | What to follow |
| --- | --- |
| `App/DemoBotsApp.swift` | App entry and the campaign's `DemoBotsView` |
| `Game/DemoBotsView.swift` | `GameView`, menus, HUD, touch controls, and scene inspection |
| `Game/DemoBotsSession.swift` | One round's world, level loading, resources, player, and timer |
| `Game/DemoBotsInput.swift` | Touch, keyboard, and gamepad actions feeding the same player input |
| `Game/BotComponents.swift` and `Game/DemoBotsSystems.swift` | Bot state and the decisions applied each update |
| `Game/BotNavigation.swift` | Routes around the original level obstacles |
| `Game/DemoBotsPresentation.swift` and `Game/DemoBotsCheckpoint.swift` | Visible feedback and the state saved between play sessions |

The session loads the authored `.sks` hierarchy and reads patrol data from the level's `.plist`. Components describe the bots; systems make decisions before steering and correct movement afterward. SwiftUI presents the HUD while `GameView` renders the world. That separation is useful to watch when a bot changes from chasing the player to being repaired.

For the engine ideas behind this campaign, read <doc:gameplay-and-movement> and <doc:saving-and-debugging>.

## Optionally try the separate co-op arena

After exploring the campaign, choose Co-op Debug Arena from its home menu. This small arena asks two players to cure four bots within 120 seconds; each bot needs two confirmed hits. It has an open floor and rectangular movement bounds, separate from the campaign's irregular walls and checkpoints.

The `DemoBotsGame` package product also exposes the co-op view. This host uses procedural artwork, so it needs no asset catalog.

```swift
import DemoBotsGame
import SwiftUI

@MainActor
struct ContentView: View {
    var body: some View { DemoBotsCoopView(usesArtwork: false) }
}
```

Choose Start local co-op. The sample runs two independent preview service coordinators and worlds through `GameCenterPartyPreview`. You control the client; an optional scripted teammate runs on the host. Turn off teammate movement and firing to inspect your own contribution. Add Delay, Unreliable loss, or Vary packet delay to see late poses and confirmations. Reliable control and receipts retain delivery and order.

Follow `Game/DemoBotsCoopView.swift` for those controls and `Game/DemoBotsCoopSession.swift` for the match owner. The latter retains the network worlds, services, controllers, and recovery choice. A separate presentation world mirrors actor state and the locally predicted visual. Only the host changes bot corruption, time, shared score, or round completion.

Shots use host-issued interaction views. The host checks cooldown, range, view age, target lifetime, and the current round before accepting a hit. Temporary beams can appear immediately, but confirmed particles and audio wait for a final receipt. A bot already cured cannot add another cure to the score.

For an experiment outside the bundled view, this helper creates a stopped fixture with a stationary teammate. Start it from your own action and advance it once per application update. The bundled view already owns this clock, so it needs no second pump.

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

## Follow an interruption and recovery

Save recovery point stores the host's selected actor and round state with a versioned time payload. The session retains the exact descriptor approving that local file. It does not read an arbitrary older file when the view appears.

Interrupt clears input, controllers, feedback, and connection ownership. Rejoin saved round requests a fresh match with the original roster and host. The host offers the approved checkpoint; clients accept it; fresh worlds are prepared. Gameplay waits until all clients acknowledge the restored baseline. New movement and action epochs start without old held input or feedback. Restoring the score does not grant rewards again.

The bundled view owns its lifecycle cleanup. This hook shows how a custom menu owner would stop movement and interrupt, without adding a second lifecycle owner around that view.

```swift
import DemoBotsGame

@MainActor
func interruptCoopFromGameMenu(_ game: DemoBotsCoopSession) {
    game.move(.zero)
    game.interrupt()
}
```

When a checkpoint is missing, incompatible, or cannot reach the original players, the sample leaves gameplay disabled and shows the error. A retry is a player action. Closing co-op returns to the campaign's own home menu.

## Native play and sample limits

The co-op adapter predicts rectangular kinematic movement, not movement through the campaign's collision walls or native physics. Only portable validated actor and round values are shared. Cameras, physics bodies, input, playback resources, and controller histories stay local. The entity traffic budget does not include application/control messages, which have separate limits.

Use live Game Center stops the local fixture. Sign in, load/start `dev.spriteui.demobots.coop`, and enter the same party code on both devices. Native activity parties require iOS/macOS 26+, a configured two-player party-capable activity, matching bundle IDs, signing, provisioning, and compatibility. Keep one services host through lobby, gameplay, and recovery; queued invitations wait for acceptance.

Signed two-account co-op verification remains **pending** for this checkout. Local rounds do not establish native invitations, matching, delivery, or rejoin. Before release, test those flows, account changes, and backgrounding on signed devices. Continue with <doc:activity-party-matchmaking-and-handoff> to understand the lobby flow, or <doc:multiplayer-recovery-and-rejoining> to follow the saved-round handoff.
