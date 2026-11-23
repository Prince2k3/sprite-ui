---
title: DemoBots with SpriteUI
tags: [spriteui, demobots, example]
created: 2026-11-22
updated: 2026-11-23
status: active
type: permanent
---

# DemoBots with SpriteUI

A playable recreation of Apple's DemoBots sample using SpriteUI instead of GameplayKit. Restore the corrupted GroundBots and FlyingBots with a rechargeable Debug Beam before the timer expires.

The new `Examples/DemoBots/` folder contains a standalone iOS/iPadOS and macOS app, game module, original licensed resources, and a repeatable asset importer. It is separate from the existing library demo app. [[project.yml]] defines both app targets; [[Game/DemoBotsSession.swift]] coordinates a match.

## Run

Open `DemoBots.xcodeproj`, choose **DemoBots** for an iPhone/iPad simulator, or **DemoBotsMac** for macOS, and Run. The project uses the SpriteUI package from this checkout. To regenerate the project, run `xcodegen generate` in this directory.

Both targets link Apple's native `GameController.framework`. [[project.yml]] generates [[App/Info.plist]] with the Game Controller capability metadata `GCSupportsControllerUserInteraction = true` and `GCSupportedGameControllers` entries for `ExtendedGamepad` and `MicroGamepad`. A controller is optional; touch and keyboard controls remain available. These declarations follow [Apple's Game Controller configuration guidance](https://developer.apple.com/documentation/gamecontroller/).

The adapter polls native `GCController` snapshots for extended gamepads (sticks, D-pad, face buttons, triggers, and Menu) and micro gamepads (D-pad, south button, and Menu). Automated native-profile tests use synthetic `GCController.withExtendedGamepad()` controllers to check element mapping, independent hosts, and disconnect handling. MicroGamepad mapping is implemented; physical controller checks remain manual.

From the repository root:

```sh
swift test --filter DemoBots
xcodebuild -project Examples/DemoBots/DemoBots.xcodeproj -scheme DemoBots -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath /tmp/demobots-build build
```

## Play

- Touch left stick: move. Tap an open floor point to walk there using A*. Firing leaves that route intact; direct movement takes over from walking.
- Touch right stick: hold to fire, drag to aim. Center-fire assists nearby visible corrupted bots, favoring your facing direction; dragging narrows assistance to your aim. The lock stays steady between similar targets. Without a valid target, the beam fires where you face, including your last tap-to-walk direction.
- Gamepad: left stick or D-pad moves; right stick aims and automatically fires outside its dead zone. The south face button or right trigger fires in the current aim/facing direction; Menu pauses or resumes. Keyboard, gamepad, and touch can be mixed: the strongest movement/aim source wins, and releasing or disconnecting it falls back to another held source.
- Menus: South or Return starts the selected home level, resumes a paused match, advances after a win (replaying level 3 after the final win), or retries after a loss. On the home screen, D-pad left/right or keyboard left/right arrows select levels 1–3. Release South after confirming before pressing it again to fire; a held menu selection direction also waits for neutral before moving the player.
- Keep a beam on a red bot until it becomes green. The beam has a two-second battery and a forced recharge interval.
- GroundBots chase and attack; bad bots can infect good bots. FlyingBots produce area attacks; curing a FlyingBot also cures nearby bad bots.
- Your charge recovers automatically after depletion. You are protected while recharging.
- The radar shows the player in cyan, corrupted bots in red, and healthy bots in green.
- Pause to save or restore a checkpoint, restart, select a level, toggle sound, or see bot paths. A saved checkpoint is also available from the home screen; restoring waits for Resume.
- Bot status labels stay readable while the camera zooms. Hits flash red, the beam marks its locked target, and repairs show a rising caption. Blast rings mark the area affected.
- Keyboard: WASD or arrow keys move, F/Space fires, P/Escape pauses or resumes, and I opens scene tools. Window deactivation pauses a match. Pausing, changing levels, opening tools, or leaving the game clears held movement, aiming, and firing; release keys/buttons and center sticks before reusing them.

## Scene tools

Open the ladybug button in the game HUD, choose **Scene tools** from the pause menu, or press **I**. The match initially pauses and the gameplay HUD gives way to SpriteUI's built-in inspector. Player movement, aiming, firing, and tap-to-walk are disabled while tools are open.

- Expand **Debug** for pause/resume, single-frame stepping, time scale, frame statistics, and system timings.
- **Pick entity** selects displayed artwork; **Hierarchy** also reaches disabled entities and actor parents. **Player** selects the player actor directly, including its bot, steering, state-machine, and character-controller components.
- Collision outlines and selection highlighting start enabled. **More guides** adds origins, bounds, joint connections, and constraint targets.
- A step runs the match's simulation and presentation systems while keeping the world paused. Bots, timer, state machines, and animation advance together; audio stays suspended.
- Close with the X button, **I**, or **Escape**. The prior pause state and time scale return, with held player input cleared. Opening from the pause menu returns there; a completed or lost match stays terminal. In tools, **P** toggles scene pause.

[[Game/DemoBotsView.swift]] owns the view-scoped `SceneDebugController` and passes it through `GameView(debug:)`. [[Game/DemoBotsSession.swift]] manages the inspection lifecycle so the debugger can step the game without enabling player controls. These tools are available in both app targets and require no SpriteKit access in the game module.

## SpriteUI integration

- `SceneLoader` loads all three original `.sks` levels into entity hierarchies. The original `.plist` files provide patrol routes and initial bot dispositions.
- `BotComponent`, `SteeringComponent`, `SpatialIndexComponent`, and `StateMachineComponent<BotMode>` represent characters.
- Two game systems surround `SteeringSystem`: game decisions and input before movement, collision correction and presentation afterward. `SpatialIndexSystem` then refreshes neighbors.
- `RuleSystem` selects patrol, hunt, or flee. The SDK's padded `ObstacleGraph` provides routes around the original scene polygons and board edges. Waypoints advance every frame after the following segment is clear; intermediate goals seek corners, and final goals arrive and brake. Stable patrol routes retain their remaining corners. Characters stopped within the planner’s tiny extra margin recover through a bounded controller sweep before replanning. `CollisionComponent`, scene raycasts/overlaps and `CharacterControllerComponent.moveCharacter` handle targeting and swept movement.
- `PrefabResource` caches normalized level hierarchies and shared actor templates. Instantiation gives each match and bot fresh IDs, independent components and playback, while sharing immutable resources.
- `CameraComponent` follows the player with a view-aware margin around the original board bounds. `ResourceLibrary` preloads atlas clips and the cure sound; explicit animation/audio playback controllers handle them.
- `SpriteMaterial` with `.spriteEffects` supplies independent damage flashes and zapped outlines through directional frame changes. The beam and route guides use `VectorPath`/`ShapeComponent`; guides keep their entities and native shapes while edited or hidden with activation. A visual `TransformConstraintComponent` tracks the beam target after final presentation without moving its character controller.
- `GameAttachment` and passive screen-sized `AttachmentComponent` labels show observed bot status without intercepting movement taps. `TextComponent` repair/damage captions use grouped move/scale/fade animation resources.
- [[Game/DemoBotsInput.swift]] owns one `InputController`, named move/aim/fire actions, and a retained synchronous event subscription. [[Game/DemoBotsView.swift]] installs `.gameInput(_:isActive:)` around the game host for focused keyboard/controller capture. Each touch stick has an independent virtual device and feeds the same action map. Gameplay, menu, and inspection contexts gate player actions while retaining the appropriate pause/tool shortcuts; device loss cancels only that device. The match receives resolved vectors and firing state without importing hardware frameworks.
- Bounded `EntityPool`s reuse particle bursts, blast rings and captions. Cosmetic saturation drops an effect rather than affecting combat; expiry releases leases, pause freezes them, and restart replaces the pools. Non-pooled sound entities still use `LifetimeSystem`.
- `WorldSnapshot`, registered Codable components and entity-reference remapping save bots, charge, corruption, patrol/state timers, steering, camera and remaining match time. Checkpoints are validated before replacing the world and written atomically to Application Support. Pools, live playback, beam/route artwork and held input are transient; they are rebuilt after restore. See [[Game/DemoBotsCheckpoint.swift]] and [[Game/DemoBotsPresentation.swift]].
- `GameView` hosts the world; SwiftUI supplies menus, HUD, radar, and independent touch sticks. Its optional `SceneDebugController` adds scene inspection, diagnostics, profiling, and frame stepping. The game module imports no SpriteKit or GameplayKit.

## Source and scope

Apple's original sample: https://developer.apple.com/library/archive/samplecode/DemoBots/Introduction/Intro.html

The three level layouts, patrol configurations, logo, scenery, and robot animation art come from DemoBots 2.3. Retained terms are in `APPLE-LICENSE.txt`. The original six raster variants are reduced to one universal image per selected animation frame. `Tools/import-apple-sample.py` regenerates these resources from the extracted Apple sample archive. `cure.wav` is synthesized for this recreation.

The example adopts SDK features where they serve this game. Tile maps do not replace the authored sprite/polygon levels; physics joints and dynamic-body simulation do not replace character controllers. Painted art/shadows are retained without adding lighting or scene-wide filters, and masks are unnecessary for the passive status labels.

This recreation includes the core game, all three levels, 16-direction robot art, touch/keyboard/gamepad controls, AI, timer, pause/retry/progression, and effects. It does not port ReplayKit, on-demand resource downloads, the original shader effects, or every original animation. AI weights and charge-recovery tuning are adapted to SpriteUI. Collision outlines use the imported obstacle rectangles rather than recovering arbitrary SpriteKit body geometry. SpriteUI's package tests intentionally run without the app asset catalog; SpriteKit can log missing visual resources during those headless tests.
