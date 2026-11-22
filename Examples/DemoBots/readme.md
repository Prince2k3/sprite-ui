---
title: DemoBots with SpriteUI
tags: [spriteui, demobots, example]
created: 2026-11-22
updated: 2026-11-22
status: active
type: permanent
---

# DemoBots with SpriteUI

A playable recreation of Apple's DemoBots sample using SpriteUI instead of GameplayKit. Restore the corrupted GroundBots and FlyingBots with a rechargeable Debug Beam before the timer expires.

The new `Examples/DemoBots/` folder contains a standalone iOS/iPadOS and macOS app, game module, original licensed resources, and a repeatable asset importer. It is separate from the existing library demo app. [[project.yml]] defines both app targets; [[Game/DemoBotsSession.swift]] coordinates a match.

## Run

Open `DemoBots.xcodeproj`, choose **DemoBots** for an iPhone/iPad simulator, or **DemoBotsMac** for macOS, and Run. The project uses the SpriteUI package from this checkout. To regenerate the project, run `xcodegen generate` in this directory.

From the repository root:

```sh
swift test --filter DemoBots
xcodebuild -project Examples/DemoBots/DemoBots.xcodeproj -scheme DemoBots -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath /tmp/demobots-build build
```

## Play

- Left stick: move. Tap an open floor point to walk there using A*.
- Right stick: hold to fire, drag to aim. Hold its center to automatically aim at the nearest visible corrupted bot within beam range.
- Keep a beam on a red bot until it becomes green. The beam has a two-second battery and a forced recharge interval.
- GroundBots chase and attack; bad bots can infect good bots. FlyingBots produce area attacks; curing a FlyingBot also cures nearby bad bots.
- Your charge recovers automatically after depletion. You are protected while recharging.
- The radar shows the player in cyan, corrupted bots in red, and healthy bots in green.
- Pause to restart, select a level, toggle sound, or see bot paths.
- Keyboard: WASD or arrow keys move, F/Space fires, P/Escape pauses. Window deactivation pauses a match.

## SpriteUI integration

- `SceneLoader` loads all three original `.sks` levels into entity hierarchies. The original `.plist` files provide patrol routes and initial bot dispositions.
- `BotComponent`, `SteeringComponent`, `SpatialIndexComponent`, and `StateMachineComponent<BotMode>` represent characters.
- Two game systems surround `SteeringSystem`: game decisions and input before movement, collision correction and presentation afterward. `SpatialIndexSystem` then refreshes neighbors.
- `RuleSystem` selects patrol, hunt, or flee. `GridGraph`/`GridSpace` provide obstacle-aware routes. Swept movement prevents crossing the scene's polygon walls.
- `CameraComponent` follows the player with a view-aware margin around the original board bounds. `ParticleEmitterComponent`, `LifetimeSystem`, and `AudioComponent` provide beam-hit, cure, and blast effects.
- `GameView` hosts the world; SwiftUI supplies menus, HUD, radar, and independent touch sticks. The game module imports no SpriteKit or GameplayKit.

## Source and scope

Apple's original sample: https://developer.apple.com/library/archive/samplecode/DemoBots/Introduction/Intro.html

The three level layouts, patrol configurations, logo, scenery, and robot animation art come from DemoBots 2.3. Retained terms are in `APPLE-LICENSE.txt`. The original six raster variants are reduced to one universal image per selected animation frame. `Tools/import-apple-sample.py` regenerates these resources from the extracted Apple sample archive. `cure.wav` is synthesized for this recreation.

This recreation includes the core game, all three levels, 16-direction robot art, touch/keyboard controls, AI, timer, pause/retry/progression, and effects. It does not port ReplayKit, on-demand resource downloads, hardware game-controller support, the original shader effects, or every original animation. AI weights and charge-recovery tuning are adapted to SpriteUI. Collision outlines use the imported obstacle rectangles rather than recovering arbitrary SpriteKit body geometry. SpriteUI's package tests intentionally run without the app asset catalog; SpriteKit can log missing visual resources during those headless tests.
