---
title: DemoBots with SpriteUI
tags: [spriteui, demobots, example]
created: 2026-11-22
updated: 2026-11-24
status: active
type: permanent
---

# DemoBots with SpriteUI

A playable recreation of Apple's DemoBots sample using SpriteUI instead of GameplayKit. Restore the corrupted GroundBots and FlyingBots with a rechargeable Debug Beam before the timer expires.

The new `Examples/DemoBots/` folder contains a standalone iOS/iPadOS and macOS app, game module, original licensed resources, and a repeatable asset importer. It is separate from the existing library demo app. [[project.yml]] defines both app targets; [[Game/DemoBotsSession.swift]] coordinates a match.

## Run

Open `DemoBots.xcodeproj`, choose **DemoBots** for an iPhone/iPad simulator, or **DemoBotsMac** for macOS, and Run. The project uses the SpriteUI package from this checkout. To regenerate the project, run `xcodegen generate` in this directory.

Both targets link Apple's native `GameController.framework`. [[project.yml]] generates [[App/Info.plist]] with the Game Controller capability metadata `GCSupportsControllerUserInteraction = true` and `GCSupportedGameControllers` entries for `ExtendedGamepad` and `MicroGamepad`. A controller is optional; touch and keyboard controls remain available. These declarations follow [Apple's Game Controller configuration guidance](https://developer.apple.com/documentation/gamecontroller/).

The adapter polls native `GCController` snapshots for extended gamepads (sticks, D-pad, face buttons, triggers, and Menu) and micro gamepads (D-pad, south button, and Menu). Automated native-profile tests use synthetic `GCController.withExtendedGamepad()` controllers to check element mapping, independent hosts, and disconnect handling. MicroGamepad mapping is implemented; physical controller checks remain manual. The portable `DemoBotsInputSessionTests` cover device assignment, safe joining/rejoining, adaptive/remapped prompts, mixed virtual/controller input, feedback cancellation/deduplication, and checkpoint ownership. Feedback uses a recording provider in tests; its feel on real hardware remains a manual check.

From the repository root:

```sh
swift test --filter DemoBots
xcodebuild -project Examples/DemoBots/DemoBots.xcodeproj -scheme DemoBots -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath /tmp/demobots-build build
```

## Play

- Touch left stick: move. Tap an open floor point to walk there using A*. Firing leaves that route intact; direct movement takes over from walking.
- Touch right stick: hold to fire, drag to aim. Center-fire assists nearby visible corrupted bots, favoring your facing direction; dragging narrows assistance to your aim. The lock stays steady between similar targets. Without a valid target, the beam fires where you face, including your last tap-to-walk direction.
- Gamepad: left stick or D-pad moves; right stick aims and automatically fires outside its dead zone. The south face button or right trigger fires in the current aim/facing direction; Menu pauses or resumes. Keyboard, gamepad, and touch can be mixed: the strongest movement/aim source wins, and releasing or disconnecting it falls back to another held source.
- Menus: South or Return starts the selected home level, resumes a paused match, advances after a win (replaying level 3 after the final win), or retries after a loss. On the home screen, D-pad left/right or keyboard left/right arrows select levels 1–3. Release South after confirming before pressing it again to fire; a held menu selection direction also waits for neutral before moving the player. New controllers and controllers returning after input suspension establish a fresh snapshot baseline: release buttons and center sticks before reusing them.
- Fire, pause, and menu-confirm hints follow the player’s active device, using its reported labels and SF Symbols when available. Newly connected, unclaimed controllers are automatically assigned to this single player; controllers owned by another player are left alone.
- Supported controllers give short feedback for bot repairs, player charge damage, and wins/losses. Feedback stops on pause, scene inspection, input cancellation, or focus loss; unsupported hardware stays silent.
- Keep a beam on a red bot until it becomes green. The beam has a two-second battery and a forced recharge interval.
- GroundBots chase and attack; bad bots can infect good bots. FlyingBots produce area attacks; curing a FlyingBot also cures nearby bad bots.
- Your charge recovers automatically after depletion. You are protected while recharging.
- The radar shows the player in cyan, corrupted bots in red, and healthy bots in green.
- Pause to save or restore a checkpoint, restart, select a level, toggle sound, see bot paths, or open **Display & performance**. A saved checkpoint is also available from the home screen; restoring waits for Resume.
- Bot status labels stay readable while the camera zooms. Hits flash red, the beam marks its locked target, and repairs show a rising caption. Blast rings mark the area affected.
- Keyboard: WASD or arrow keys move, F/Space fires, P/Escape pauses or resumes, and I opens scene tools. Window deactivation pauses a match. Pausing, changing levels, opening tools, or leaving the game clears held movement, aiming, and firing; release keys/buttons and center sticks before reusing them.

## Display & performance

Open **Display & performance** from the home screen or pause menu. Opening the panel immediately disables the existing `PlayerInputSession`, cancelling held gameplay input and gating late virtual-control samples while open. Closing it returns to the same home or paused phase and preserves the world's existing pause state; changing settings does not resume a paused match or rebuild its world, player, camera, or input session. Release buttons and center sticks before reusing them.

| Preset | Requested resolution scale | Preferred FPS | Render-plan pixel budget |
| --- | --- | --- | --- |
| Balanced | 1 | 60 | 16 MP |
| Battery Saver | 0.75 | 30 | 8 MP |
| High Refresh | 1 | 120 | 16 MP |

All three presets set `adaptsToSystemPressure: true`; native thermal or low-power pressure may lower the request, and render-plan limits may reduce resolution further. Preferred FPS is a requested cadence, not measured achieved FPS. The pixel budget bounds planned render targets, not global GPU memory; any byte estimate is a target reservation estimate. Point-space controls and native-resolution attachments keep their geometry.

The optional local `GamePresentationView` preview shares only the existing `main` gameplay pane's completed pixels. It is read-only and excludes the SwiftUI HUD, menus, and native attachments; it adds no simulation updates or input route. The primary host receives the presentation source while the local preview panel is visible or external presentation is enabled, and receives nil otherwise. These toggles retain the same world and rendering clock.

On iOS 27 or later, external presentation optionally requests the native noninteractive accessory. **Source available** means completed game pixels exist; **role available** means the OS offers the external accessory. Neither status proves the other. An unavailable role leaves local play available. This general role grants no Duo outer-display camera entitlement and requests no camera permission. See [[../../Sources/SpriteUI/SpriteUI.docc/Articles/bounded-rendering-and-read-only-presentation.md]] for the rendering contract and [[Game/DemoBotsSurfaceLayout.swift]] for point-space layout.

### Simulator verification and remaining QA

Verified on the iPhone Duo simulator with iOS 27.2: open, Book, Tabletop, closed outer-display, and reopened layouts; the panel fits a usable region and keeps the paused match unchanged. Battery Saver requested 75% / 30 FPS, and High Refresh requested 100% / 120 FPS. The gameplay-only preview reported a completed source while the external role correctly remained unavailable. Saving, folding, and restoring a checkpoint retained two of six restored bots and 2:49 remaining, awaiting Resume. The final iOS and macOS builds pass.

Automated tests exercise synthetic folds during preparation, installation, fade, cross-fade, failure, and cancellation; they preserve player/camera identity and device assignments and enforce fresh neutral input. Repeat the checks below on hardware before release. Native held-touch stress during folds, measured game-clock comparisons, and connected external-display output remain manual checks; no physical-hardware session is claimed.

- Start a match in the Duo simulator (and repeat on hardware before release) in the open posture, then move through Book, Tabletop, outer-display transitions, and back to open. Check reported usable regions, fitting controls, and retained match/player/camera state. An outer transition does not establish external-role availability.
- Hold movement and firing while folding. Check that effective layout changes release held controls, stale gestures stay gated until release, and fresh input works without an unintended phase or pause change.
- Save a checkpoint, pause, and switch Balanced → Battery Saver → High Refresh → Balanced in the panel. Close and reopen it; check that the phase and pause state remain unchanged and that the same world and input session survive. Inspect requested/effective settings without labeling cadence as achieved FPS.
- Enable local preview, resize or fold, then disable it. Compare actual world-update deltas at the same primary cadence; preview must add no updates or input. With external presentation also disabled, check that the primary receives nil for its source.
- Enable the external option on iOS 27 with no available role. Check the unavailable status, continued local play, and independent source status. If a role is available, exercise enable/disable and disconnect/reconnect; otherwise record **external-display presentation unverified**.
- After folding, restore the saved checkpoint from pause. Check restored bot/player state and remaining time, release held input, and verify that play waits for Resume.

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
- [[Game/DemoBotsInput.swift]] owns a `PlayerInputHub`, one `PlayerInputSession`, named move/aim/fire actions, and retained action/device subscriptions. Its `input` compatibility property exposes `player.input`. Keyboard, pointer, the two virtual sticks, and the virtual HUD are explicitly registered/assigned; the example’s device observer assigns only unclaimed controllers. [[Game/DemoBotsView.swift]] installs `.gameInput(controls.hub, isActive:)` around the game host for focused keyboard/controller capture. Each touch stick has an independent virtual device and uses `hub.submit` to feed the same action map. Player-session prompts adapt to active-device metadata. Changes in the session’s observed restored-bot count, player charge, and terminal phase produce one short feedback request per meaningful HUD change, with win/loss taking precedence. Beam drain, recharge, and unchanged state never pulse; restart/checkpoint restore reset the feedback baseline. Gameplay, menu, and inspection contexts gate player actions while retaining the appropriate pause/tool shortcuts; device loss cancels only that device. The match receives resolved vectors and firing state without importing hardware frameworks.
- Bounded `EntityPool`s reuse particle bursts, blast rings and captions. Cosmetic saturation drops an effect rather than affecting combat; expiry releases leases, pause freezes them, and restart replaces the pools. Non-pooled sound entities still use `LifetimeSystem`.
- `WorldSnapshot`, registered Codable components and entity-reference remapping save bots, charge, corruption, patrol/state timers, steering, camera and remaining match time. Checkpoints are validated before replacing the world and written atomically to Application Support. Pools, live playback, beam/route artwork and held input are transient; they are rebuilt after restore. See [[Game/DemoBotsCheckpoint.swift]] and [[Game/DemoBotsPresentation.swift]].
- `GameView` hosts the world; SwiftUI supplies menus, HUD, radar, and independent touch sticks. Its optional `SceneDebugController` adds scene inspection, diagnostics, profiling, and frame stepping. The game module imports no SpriteKit or GameplayKit.

## Source and scope

Apple's original sample: https://developer.apple.com/library/archive/samplecode/DemoBots/Introduction/Intro.html

The three level layouts, patrol configurations, logo, scenery, and robot animation art come from DemoBots 2.3. Retained terms are in `APPLE-LICENSE.txt`. The original six raster variants are reduced to one universal image per selected animation frame. `Tools/import-apple-sample.py` regenerates these resources from the extracted Apple sample archive. `cure.wav` is synthesized for this recreation.

The example adopts SDK features where they serve this game. Tile maps do not replace the authored sprite/polygon levels; physics joints and dynamic-body simulation do not replace character controllers. Painted art/shadows are retained without adding lighting or scene-wide filters, and masks are unnecessary for the passive status labels.

This recreation includes the core game, all three levels, 16-direction robot art, touch/keyboard/gamepad controls, AI, timer, pause/retry/progression, and effects. It does not port ReplayKit, on-demand resource downloads, the original shader effects, or every original animation. AI weights and charge-recovery tuning are adapted to SpriteUI. Collision outlines use the imported obstacle rectangles rather than recovering arbitrary SpriteKit body geometry. SpriteUI's package tests intentionally run without the app asset catalog; SpriteKit can log missing visual resources during those headless tests.


## Game Center test lab

In a Debug build, choose **Game Center Test Lab** from the campaign home menu. The default preview needs no account. Load test data, report 25% or unlock First Repair, submit 100 then 50 points to verify the best-score policy, start/finish Repair Test, simulate and explicitly accept an activity entry, or submit a new challenge attempt. None of these actions report campaign progress. Reopen the lab after an external achievement reset to clear its monotonic cache.

[[Game/DemoBotsGameCenterLab.swift]] owns explicit operations and cancellation. [[Game/DemoBotsGameCenterView.swift]] hosts one retained service facade; switching modes shuts down the old instance. Entering the lab cancels campaign input. Native sign-in, loading, and reports require explicit buttons, and unsupported activity/challenge controls remain disabled on older systems.

The project includes [[App/DemoBotsLocal.gamekit/gameCenterResources.json]] with these identifiers:

| Resource | Identifier |
| --- | --- |
| First Repair achievement | `dev.spriteui.demobots.first_repair` |
| Repair Score leaderboard | `dev.spriteui.demobots.repair_score` |
| Single-player Repair Test activity | `dev.spriteui.demobots.repair_test` |
| Two-player co-op activity | `dev.spriteui.demobots.coop` |
| Repeatable Repair Challenge, linked to Repair Score | `dev.spriteui.demobots.repair_challenge` |

The English definitions and small procedural 3840×2160 opaque placeholder art are local samples. Review real metadata, artwork, app records, and compatibility before any manual push to App Store Connect. The project never performs that push automatically.

For server-backed setup, [[../../Tools/game-center-connect.md]] provides a reusable API workflow. Run `python3 Tools/game-center-connect.py validate --bundle-id dev.spriteui.demobots --gamekit Examples/DemoBots/App/DemoBotsLocal.gamekit` from the repository root to validate this bundle offline. With your own App Store Connect API credentials, `status` reads component versions and app enablement, `plan` previews missing drafts, and `apply` explicitly creates reviewed draft definitions and localized text. Existing metadata differences are conflicts rather than automatic overwrites. Complete artwork and submit Game Center components for Apple's review separately; draft creation does not resolve or establish native challenge availability.

Choose **DemoBots Local Game Center** or **DemoBotsMac Local Game Center** in Xcode to open the lab with native GameKit selected and Run → Options → GameKit Configuration → Enable Debug Mode enabled. Sign in explicitly as required. On a supported physical device, use Debug → GameKit → Manage Game Progress to inspect/reset progress and exercise Repair Test activity entry points. Preview mode remains available through the toggle. A simulator can check the preview UI; it cannot establish Game Progress Manager or signed two-account results.

The example defaults to automatic signing with MFX Studios (`SHC9383T46`). Select your own team when building outside that organization. The Mac target still disables signing by default; enable it explicitly for signed Mac testing.

The challenge panel displays the loaded definition's leaderboard, or identifies an absent definition or missing link. If the configured challenge is unavailable, **Submit new test attempt** reports that no score was submitted. A successful standalone leaderboard submission does not establish that challenge reporting works.

The native lab also displays the installed app's bundled challenge count, duration-option count, and version/build. **Load test data** reports the counts returned by GameKit, separately from this bundled payload. A bundled definition is not proof that the native service loaded it. [[project.yml]] supplies `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`; [[../../Tools/check-game-center-setup.py]] rejects missing or unresolved versions in the built app. The local challenge includes `allowedDurations` for native decoder compatibility. The fixture checker catches its removal, including after editing the bundle in an Xcode version that omits that field.

The ordinary **DemoBots** and **DemoBotsMac** schemes leave GameKit Debug Mode off and launch the campaign. Release targets exclude `DemoBotsLocal.gamekit`; debug launch overrides and the campaign's lab button are compiled out of the app entry points. The package's reusable test view does not launch itself. [[project.yml]] invokes [[Tools/configure-game-center-schemes.py]] after XcodeGen so regeneration preserves the explicit scheme flag.

From the repository root, check IDs, links, art, and scheme isolation with:

```sh
python3 Examples/DemoBots/Tools/check-game-center-testing.py
```

Apple's [local Game Center configuration guide](https://developer.apple.com/documentation/gamekit/initializing-and-configuring-game-center) describes the physical-device workflow. Native checks on a physical Duo with iOS 27.3 beta (24C5049f) and Xcode 27.2 passed sign-in, achievement progress (0 → 25 → 100), the best-score policy (100 followed by 50 retained 100), and activity start/finish/discard. Game Progress Manager now lists the Duo and DemoBots, with the local achievement and leaderboard visible. The installed app reports one bundled challenge, three duration options, and version 1.0 (2), but an authenticated load still returns two activities and zero challenges, including after switching Debug Mode off and back on. These configuration corrections have **not** resolved the empty native challenge catalog; its remaining cause is unproven. No preview definitions are substituted for native results. Challenge reporting, dashboard content, Game Progress Manager resets/deep links, and signed two-account testing remain unverified. These results establish partial local coverage, not release readiness.
