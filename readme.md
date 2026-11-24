---
title: SpriteUI
tags: [spriteui, library, documentation]
created: 2026-11-23
updated: 2026-11-24
status: active
type: permanent
---

# SpriteUI

SpriteUI brings a RealityKit-style entity-and-component API to 2D games, with SpriteKit rendering and a SwiftUI host. Add entities to a `GameView`, describe them with value components, and run frame logic in query-driven systems.

## Requirements

- Swift 6 and an Xcode toolchain that supports it.
- iOS 18 or macOS 15 or later.
- Python 3 for the documentation commands; XcodeGen only when regenerating the example app projects.

## Installation

In your SwiftUI app's Xcode project, choose **File > Add Package Dependencies > Add Local**, then select this checkout's root folder. Add the **SpriteUI** library product to your app target and set its deployment target to iOS 18 or macOS 15 or later.

For a package alongside this checkout, add a local dependency and link its product:

```swift
// In your Package.swift, inside Package(...):
dependencies: [
    .package(path: "../swiftui-ecs")
],
targets: [
    .target(
        name: "MyGame",
        dependencies: [.product(name: "SpriteUI", package: "swiftui-ecs")]
    )
]
```

Adjust the path to your checkout. Import `SpriteUI` to use the complete library. Choose `SpriteUICore` for the complete engine without Game Center, and add `SpriteUIGameCenter` when wanted. `ECSCore` and `Gameplay` remain independent products; `DemoBotsGame` contains the example game's implementation. [[Package.swift]] defines the products, and [[Sources/SpriteUI/SpriteUI.swift]] re-exports the SDK modules.

## Quick start

This complete view displays a cyan square without requiring any assets. Present `ContentView()` from your app's window.

```swift
import SpriteUI
import SwiftUI

@MainActor
struct ContentView: View {
    var body: some View {
        GameView { content in
            let player = Entity(
                name: "player",
                components: SpriteComponent(color: .cyan, size: [40, 40])
            )
            player.position = [0, 0]
            content.add(player)
        }
        .frame(minWidth: 320, minHeight: 240)
    }
}
```

With no camera, the scene origin is at the view's center. Positions are in points, with positive y upward, and an entity's position is relative to its parent.

- **Entities** provide identity, hierarchy, and transforms.
- **Components** hold data describing appearance, movement, collisions, and game state.
- **Systems** query entities and update their components each simulation frame.
- **Events** connect systems, scene owners, and app interfaces without coupling their implementations.

Create entities and install systems in `GameView`'s setup closure. Use its `update` closure to apply SwiftUI state to existing entities; use a `System` for movement and other elapsed-time work. The `update` closure runs with SwiftUI updates, rather than once per simulation frame.

## Features

| Area | Included tooling |
| --- | --- |
| Scene structure | Entity hierarchies, relative transforms, activation, prefabs, cloning, pooling, and managed level transitions |
| Simulation | Query-driven systems, opt-in fixed ticks, bounded catch-up, kinematic transform interpolation, scheduling, typed events, pause, and time control |
| Rendering | Sprites, shapes, text, materials, cameras, single-world split screen and minimaps, sprite-only parallax and bounded repeating backgrounds, bounded render-target quality, lighting, masks, and effects |
| Resources | Scene and tile-map loading, resource caching, animation and audio playback |
| Movement | Collision shapes and queries, character controllers, physics bodies, joints, and transform constraints |
| Gameplay | Agents and goals, pathfinding, navigation meshes, spatial indexes, state machines, decisions, rules, strategists, noise, and seeded random generators |
| Input | Fixed-tick recording/replay with bounded versioned archives, diagnostic checksums, pause/step/speed controls, observable actions, stacked and Codable binding maps, virtual controls, focused hardware input, opt-in calibrated hinge actions with virtual fallbacks, explicit local-player device ownership, adaptive prompts, and capability-checked controller feedback |
| Presentation | Automatic entity dragging, rotation, and scaling; targeted gestures; SwiftUI attachments; passive local mirrors and an optional OS external accessory; adaptive surface geometry, region-based cameras, and fully fitting HUD placement; particles and contact effects |
| Persistence and debugging | Registered component snapshots, entity-reference remapping, scene inspection, and frame diagnostics |
| Basic game services | One retained Game Center facade, opt-in native screens, achievement progress, global/all-time leaderboards, typed saved turns, and account-free in-memory previews |
| Multiplayer | Explicit Game Center authentication and matchmaking, host-authoritative entity replication, join snapshots, validated command channels, remote presentation smoothing, and a controlled offline transport |

## Package modules

| Module | Responsibility |
| --- | --- |
| `SpriteUI` | Convenience aggregate for SpriteUICore, SpriteUIGameCenter, and SpriteUISaves |
| `SpriteUICore` | Full engine and cross-layer bridges without a Game Center target dependency |
| `SpriteUIGameCenter` | Optional Apple services and UI; depends only on ECSCore and Gameplay |
| `SpriteUISaves` | Optional typed profiles, local wallet transactions, and GameSave; depends only on Gameplay |
| `ECSCore` | Entities, components, transforms, events, scheduling, and snapshots |
| `Gameplay` | Standalone algorithms and value types |
| `GameplayECS` | Components and systems that adapt gameplay algorithms to entities |
| `SpriteBackend` | SpriteKit rendering, physics, resources, playback, and scene services |
| `GameUI` | SwiftUI hosting, attachments, input, and inspection interfaces |

The module boundaries let pure gameplay algorithms run independently of rendering. Most apps can start with `import SpriteUI`.

## Documentation and tutorials

The DocC catalog lives in [[Sources/SpriteUI/SpriteUI.docc/SpriteUI.md]]. It includes a getting-started guide, conceptual articles, the public API reference, and nineteen hands-on tutorials covering your first scene, systems and targeted input, collision-aware agents, player input actions, direct entity manipulation, local-player device ownership and feedback, shared-world viewports, camera-specific render layers, repeating parallax landscapes, persistent-player level transitions, adaptive game surfaces, optional hinge input, bounded read-only presentation, fixed-step simulation with interpolation and buffered input, input recording/replay with diagnostic checksums, host-authoritative network sessions with optional Game Center, basic achievement, score, and saved-turn services with optional native screens, and local quests and seasonal leagues.

The tutorial sequence includes complete Swift code for every stage and expected-result illustrations:

1. **Creating your first scene:** add entities, arrange them, and change component data from SwiftUI.
2. **Moving with systems and input:** implement frame-based movement, targeted taps, and pause/resume.
3. **Steering and collision-aware movement:** combine agent goals, collision queries, character movement, and a route around a wall.
4. **Controlling a player with input actions:** build on-screen controls, read held 2D movement from a system, observe press transitions, and add optional keyboard, pointer, and gamepad bindings. No physical keyboard or gamepad is required.
5. **Manipulating sprites with gestures:** opt into automatic drag, rotation, and scale, constrain a child under a rotated and scaled parent, observe lifecycle events, and add accessible session controls with physics release.
6. **Sharing devices between players:** create independent action sessions, assign two virtual pads, transfer held input through neutral, and add adaptive prompts and optional native controller feedback. All three stages run without physical hardware.
7. **Sharing a world between viewports:** create two cameras in one world, drive independent players with virtual buttons, change side-by-side, stacked, and single layouts, then add a third-camera minimap, viewport-scoped selection, labels, and actual simulation counters. All three stages are complete replacements for `ContentView.swift`; no hardware is required. [[Sources/SpriteUI/SpriteUI.docc/Tutorials/sharing-a-world-between-viewports.tutorial]] links the staged Swift and SVG previews.
8. **Presenting a world with render layers:** start with world squares and map diamonds under neutral parents, add shared physical motion and ancestor hiding, then combine camera masks, viewport restrictions, visible-target selection, and pane-scoped attachments. All three stages replace `ContentView.swift` and use no assets or hardware. [[Sources/SpriteUI/SpriteUI.docc/Tutorials/presenting-a-world-with-render-layers.tutorial]] includes matching SVG previews.

9. **Building a parallax landscape:** generate deterministic star, mountain, and ground textures in code, add bounded repetition, then compare independent camera movement and zoom with layer factors, repeat/split switches, and unchanged model-anchor counters. All three stages replace `ContentView.swift` without external assets or hardware. [[Sources/SpriteUI/SpriteUI.docc/Tutorials/building-a-parallax-landscape.tutorial]] includes matching SVG previews.
10. **Switching levels with persistent players:** replace detached physics rooms in one world, preserve a component-backed score and camera, then try fade, crossfade, deterministic preparation failure, and cancellation. All three stages completely replace `ContentView.swift` and need no bundled resources, temporary files, or input hardware. [[Sources/SpriteUI/SpriteUI.docc/Tutorials/switching-levels-with-persistent-players.tutorial]] includes complete sources and SVG previews.

11. **Adapting to game surfaces:** inspect active and inactive reservations with explicit Book, Tabletop, Clear, and Native fixtures; resolve stable cameras inside usable regions; then place a fully fitting HUD, observe attachment geometry, and release held virtual input only on effective layout changes. All three stages replace `ContentView.swift` without assets or special hardware. [[Sources/SpriteUI/SpriteUI.docc/Tutorials/adapting-to-game-surfaces.tutorial]] links complete sources and schematic previews.

12. **Controlling a scene with hinge input:** inspect optional live sensor data, bind a calibrated Bend action with virtual-slider and keyboard alternatives, then explicitly assign a native hinge to one of two retained player sessions. All three stages replace `ContentView.swift` and run without hinge hardware; fallback controls never simulate a sensor. [[Sources/SpriteUI/SpriteUI.docc/Tutorials/controlling-a-scene-with-hinge-input.tutorial]] includes complete sources and SVG previews.

13. **Bounding rendering and sharing presentation:** vary quality without changing point geometry, inspect bounded target-plan reservations and actual simulation counters, mirror one existing pane through two passive consumers, then publish the full canvas and request an optional iOS 27 external accessory. All three stages replace `ContentView.swift`, retain the existing app entry point, and support macOS 15 with iOS-only code gated. [[Sources/SpriteUI/SpriteUI.docc/Tutorials/bounding-rendering-and-sharing-presentation.tutorial]] includes complete sources and schematic SVG previews.

14. **Running fixed-step simulation:** move a pure kinematic actor at 20 Hz, compare canonical orange and interpolated cyan actors under a 30/60/120 preferred-FPS selector, then consume buffered held values and short taps once per tick with explicit pause cleanup and live clock status. All three stages replace `ContentView.swift` and require no assets or hardware. [[Sources/SpriteUI/SpriteUI.docc/Tutorials/running-fixed-step-simulation.tutorial]] includes complete Swift sources and schematic SVG previews.

15. **Running input replays:** record virtual movement and short taps with one fixed-system owner, restore registered entity state, root pose, and the complete random stream, then compare selected-state checksums with pause, single-step, speed, divergence diagnostics, and explicit lifecycle cleanup. All three stages replace `ContentView.swift` and need no assets or input hardware. [[Sources/SpriteUI/SpriteUI.docc/Tutorials/running-input-replays.tutorial]] includes complete Swift sources and schematic SVG previews.

16. **Synchronizing a small network match:** connect host/client worlds through a controlled offline hub, validate client commands, repair lost small pose updates, preserve a local client camera across stop/rejoin, and optionally present explicit Game Center authentication and matchmaking. All three stages replace `ContentView.swift` without assets; the offline path needs no accounts or entitlements even in stage three. [[Sources/SpriteUI/SpriteUI.docc/Tutorials/synchronizing-a-small-network-match.tutorial]] includes full Swift sources and schematic SVG previews.

17. **Starting with Game Center services:** report local achievement progress and a highest local score, save/pass/finish typed versioned turns between two identities sharing one in-memory store, then add optional native service buttons and setup help. All three stages replace `ContentView.swift` without assets; the local path remains account-free in stage three, with no automatic authentication or matchmaking. [[Sources/SpriteUI/SpriteUI.docc/Tutorials/starting-with-game-center-services.tutorial]] includes complete Swift sources and schematic SVG previews.

18. **Building quests and leagues:** define counted objectives, claim a stable reward receipt, save/restore local progress, finalize tie-preserving season placements, and report an account-free preview achievement. [[Sources/SpriteUI/SpriteUI.docc/Tutorials/building-quests-and-leagues.tutorial]] supplies one complete asset-free stage.

19. **Saving player profiles:** persist a player/slot, claim a quest reward with its local wallet in one revision, reload across launches, and open an account-free offline directory preview. [[Sources/SpriteUI/SpriteUI.docc/Tutorials/saving-player-profiles.tutorial]] includes one complete asset-free stage.

The complete sequence now has **nineteen tutorials and 54 standalone stages**.

The twenty-three guides cover player profiles and cloud saves, package product selection, getting started, entity and scene lifecycle, systems and input, fixed-step simulation and interpolation, input recording and replay, input actions and controllers, player input sessions and feedback, direct manipulation, gameplay and movement, rendering and resources, viewports and split screen, render layers and camera visibility, parallax and repeating backgrounds, scene transitions and level management, adaptive game surfaces, hinge input and effects, bounded rendering and read-only presentation, basic Game Center services, quests and leagues, Game Center sessions and replication, and saving and debugging. The guides contain **73 Swift examples**. [[Sources/SpriteUI/SpriteUI.docc/Articles/input-actions-and-controllers.md]] explains context priority, cancellation and dead zones, shared controller ownership, and persisted rebinding.

[[Sources/SpriteUI/SpriteUI.docc/Articles/game-center-sessions-and-replication.md]] covers explicit `NetworkReplicationSchema` allowlists independent of saved-world registration, network UUID references distinct from local IDs, host-validated commands, and complete selected-state snapshots. Register only inert value data; keep native physics, cameras, entity-ID references, resources, and runtime services local. Each replicated parent must also be synchronized or be the world root; independent local client cameras survive session teardown. Baselines come only from the configured host after complete validation, with generation/session/join IDs rejecting retired work. Structural changes, including transform presence, are reliable; unchanged coordinates may be unreliable only when the full packet fits 1,000 bytes. Reliable packets are capped at 48,000 bytes. This targets bounded small matches without automatic host migration, prediction, rollback, or native-physics determinism.

`NetworkSession.start()` installs a presentation-phase system. Use that automatic path or disable it and call `update(deltaTime:)` explicitly once per chosen update. Pause stops automatic session updates; an app-owned pump is required for paused networking. Remote native smoothing and picking use read-only presentation while canonical queries and snapshots retain the latest validated model. The offline `InMemoryNetwork` needs explicit `advance(by:)`, with controlled latency and seeded unreliable loss.

[[Sources/SpriteUI/SpriteUI.docc/Articles/game-center-services.md]] starts with the basic services milestone: `GameCenterServices(mode: .live)` or `.preview(player:)`/`.preview()`, `.multiplayer`, `.achievements`, `.leaderboards`, and `.turnBased`. Retain the facade and install `.gameCenter(services)` once on a stable parent for the environment, sheet host, and account/match state handling. `GameCenterServicesView` supplies entry buttons and setup help. Construction and appearance do not authenticate or find matches. `present(_:)` opens a service destination; `connect(in:schema:request:)` drives sign-in/matchfinding and retains `networkSession` once ready, while `startSession` attaches an already-ready match. Use `disconnect()` for real-time teardown and `shutdown()` for the complete service lifetime.

Preview achievement/score data is instance memory only; leaderboard preview keeps the highest local score at rank 1, not a league placement. For two-identity turn experiments, pass the same `InMemoryTurnBasedStore` to separate `GameCenterTurnBasedMatches` instances and reload explicitly. Live turns save typed, versioned application values asynchronously through Apple; they do not restore world snapshots or provide lockstep. A server write may commit before later cancellation or failure is reported, and reported errors are not queued automatically. Quests, leagues, and challenges are outside this basic milestone.

[[Tools/check-game-center-setup.py]] checks a built `.app`'s local metadata and entitlements extracted from its signing data. It does not validate signature authenticity or remote App Store Connect/provisioning state. Run `python3 Tools/check-game-center-setup.py /path/to/MyGame.app --bundle-id com.example.MyGame --json`. `--entitlements FILE` instead checks a supplied plist, explicitly unverified against the signed bundle. [[Tools/templates/game-center-ios.entitlements]] and [[Tools/templates/game-center-macos.entitlements]] are starting templates, not portal setup. The guide covers App Store Connect configuration and Xcode local GameKit configuration separately from SpriteUI's preview path. Signed two-account/two-device service and persistence verification remains **pending**.

The **Game Services** tab in [[Demo/SpriteUIDemo/GameServicesDemoView.swift]] provides a companion local lab for two preview identities, saved turns, achievement progress, and scores, plus explicit native service entry buttons. Its preview operations stay in memory; opening the tab does not authenticate with Apple.

Game Center remains opt-in: the consuming app needs the Game Center capability, GameKit linkage, signed entitlement/provisioning, matching bundle ID, enabled Game Center app version, and multiplayer compatibility in App Store Connect; sandboxed Mac apps need network permissions. The coordinator waits for the complete initial roster and elects from sorted full-roster Game Center IDs. Native matches have a fixed roster with no midmatch additions or reinvites. Late replication baselines support an already connected participant starting its session later; the offline hub can additionally connect new peers. Signed two-account/two-device Game Center verification is **pending** because credentials and configuration are unavailable; offline checks and compilation do not prove live matchmaking. See [[Sources/SpriteUI/SpriteUI.docc/Articles/game-center-sessions-and-replication.md]] for setup sources and the native verification checklist.

The **Network** tab in [[Demo/SpriteUIDemo/NetworkDemoView.swift]] starts with an account-free offline host/client arena. It exposes controlled one-way latency and unreliable loss, actual state packet byte counts and reliability, host movement and structural changes, validated client commands, delayed session start/reconnect, and an independent local client camera. Packets above the small unreliable limit visibly fall back to reliable delivery. Game Center sign-in and matchmaking are separate explicit controls; loading the tab does not authenticate or configure the service. [[Demo/SpriteUIDemo/SpriteUIDemoApp.swift]] contains the tab entry point.

[[Sources/SpriteUI/SpriteUI.docc/Articles/fixed-step-simulation-and-interpolation.md]] covers opt-in `world.fixedStep` (nil by default), immutable `FixedStepConfiguration`, and `.fixedSimulation` before legacy simulation and presentation. The configuration defaults to 60 Hz, eight maximum catch-up steps, and a 0.25-second raw-delta clamp before time scaling. `WorldEvents.Update` stays once per frame; `WorldEvents.FixedUpdate` precedes each fixed tick. Fixed deltas are constant scaled time, while variable systems keep their display-frame deltas. The clock drops whole excess ticks while preserving the fraction; `fixedStepState` exposes lifetime tick count, ticks this frame, interpolation alpha, dropped scaled time for this frame, and accumulated executed simulation time.

`TransformInterpolationComponent(isEnabled: true)` smooths eligible local kinematic poses with one fixed tick of display latency. Displayed pose reads, hit testing, and attachments follow presentation; model queries and snapshots remain canonical. Native physics/body-related subtrees, camera/controller/constraint ownership, and active native transform animation reject interpolation. Teleports inside a fixed tick require the component's `reset()`; external transform writes snap automatically, and reactivation/reparenting invalidate history. Pause, clock-setting changes, root disable, and host suspension/resume clear debt and interpolation history without background catch-up. SpriteKit physics and actions retain their existing display-frame lifecycle, so fixed custom systems do not guarantee deterministic native physics or a deterministic whole world.

`FixedInputBuffer(input:capacity:)` preserves short press/release transitions and held values for once-per-tick consumption. Cancellation revisions clear stale edges even after release; overflow reports lost oldest events through `didOverflow`. The buffer is caller-owned: explicitly cancel input and/or reset it when pausing or leaving. Preferred render FPS stays independent through `GameRenderConfiguration`. The **Fixed Step** tab in [[Demo/SpriteUIDemo/FixedStepDemoView.swift]] is the companion feature demo. DemoBots keeps its existing simulation policy; fixed stepping is opt-in.

[[Sources/SpriteUI/SpriteUI.docc/Articles/input-recording-and-replay.md]] covers immutable version-one `InputRecording` archives, relative ticks `1...n`, bounded `InputRecorder` capture, overflow rejection, stable action encoding, and file/version validation. `InputReplayController(world:input:maximumFrames:checksum:)` captures registered entity state, root transform, and full `world.random` state. Root resources and installed system state need custom capture/restore providers. Runtime controllers stay on the root, and provider/checksum closures capture the world weakly. Default restore validates required registered component names before replacing entities.

One fixed owner samples before all rules and calls `finishTick` afterward; the core commits and checks only at completed-tick boundaries after all fixed systems and transform capture. Interrupted ticks fail closed without half-frame commits. Checksums hash explicit stable application bytes, not automatic world IDs or pixels. Replay suppresses live input, supports pause/step/speed, and restores clock preferences and neutral input gates on Stop without restoring the earlier live world. `World.stepFixedSimulation()` runs one paused fixed tick without variable/presentation systems, native physics, actions, or a backend debug physics frame; lifetime ticks never rewind. Native physics and whole-world determinism are not guaranteed.

[[Sources/SpriteUI/SpriteUI.docc/Articles/player-input-sessions-and-feedback.md]] explains exclusive device ownership, transfer cancellation, last meaningful input, remapped control presentations, and feedback results. The **Players** tab in [[Demo/SpriteUIDemo/PlayerInputDemoView.swift]] has two independently moving sprites, assignable virtual pads, a live device list, adaptive Fire hints, and feedback outcome readouts. Tap a direction to hold it, transfer its pad, release, then press again to exercise neutral gating. Assign real controllers when available; none are required. Keyboard and pointer entries represent logical sources rather than hardware discovery. Sessions and assignments are runtime state; save action maps instead.

[[Sources/SpriteUI/SpriteUI.docc/Articles/manipulating-entities.md]] covers parent-local axis locks, bounds and snapping, uniform local scale limits, lifecycle events, and renderer sessions. Add `InputTargetComponent` plus `ManipulationComponent` for automatic `GameView` gestures without an explicit `.gesture` modifier. The [[Demo/SpriteUIDemo/ManipulationDemoView.swift]] playground includes free, constrained-child, and dynamic-body examples with accessible buttons. Physics capture temporarily suspends native bodies without changing component configuration; end/cancel restores dynamics with zero release velocity by default, or `.restoreVelocity`. Placement does not avoid collisions or throw on release. Character-controller, transform-constraint, and joint-connected ownership deliberately reject manipulation.

[[Sources/SpriteUI/SpriteUI.docc/Articles/viewports-and-split-screen.md]] covers the single-world Metal viewport host, normalized top-left frames, stable string viewport IDs and camera entity IDs, overlap/input rules, camera bounds, and attachment projection. The **Viewports** tab in [[Demo/SpriteUIDemo/ViewportDemoView.swift]] keeps a 360-point-tall arena above two independent virtual pads. Tap an arrow to keep moving and Stop to release; switch layouts without rebuilding the world. The third-camera map blocks scene input beneath it. Tap entities in a player pane to select only there; name labels project in every viewport, while selection labels use a specific `viewportID`. Optional keyboard and controller assignment is below the controls. One hub is attached once to the game surface.

Its world-update, presentation-completion, and physics-contact counters count actual event callbacks, and scene time sums actual update deltas. They stay continuous through layout changes. Counts are not multiplied by pane count, and presentation completion is not a GPU-pass count. The bouncing probe supplies real contacts; exact totals depend on elapsed simulation. Supplying `viewports: []` chooses one automatic-camera Metal view; a plain call without viewports, rendering configuration, monitor, or presentation source preserves the legacy host. The checked-in demo project lists files explicitly: after adding new demo sources, regenerate it with `xcodegen generate` from `Demo/` before building.

[[Sources/SpriteUI/SpriteUI.docc/Articles/bounded-rendering-and-read-only-presentation.md]] explains `GameRenderConfiguration`, native pressure resolution, optional `GameRenderMonitor` statistics, and one-publisher `GamePresentationSource` ownership. Scale defaults to 1 and clamps to 0.1...1; preferred FPS defaults to 60 and clamps to 15...240. The default 16,777,216-pixel plan covers the canvas, all pane targets, and three presentation buffers; the default 8192 dimension limit can be raised to 16384. `estimatedRenderTargetBytes` is four times planned pixels, a reservation estimate that excludes SDK caches, in-flight resources, and other GPU allocations. Logical points and native-resolution SwiftUI attachments stay unchanged. Opt-in pressure adaptation caps serious at 0.75/30 and critical at 0.5/20; low-power mode caps FPS at 30, always respecting lower requests.

Any nonnil rendering configuration, monitor, or presentation source selects Metal for the host lifetime; quality toggles never swap clock drivers. Plain `GameView` without those options or viewports stays legacy. A nil monitor produces no SwiftUI statistics updates. A source immutably chooses an existing pane or full canvas; multiple noninteractive, aspect-fit `GamePresentationView` consumers share completed GPU pixels without adding a host, world, simulation, or input route. Unsafe leased buffers are never reused; backpressure drops mirror frames. Hidden or suspended primaries clear availability and resume without background-time physics catch-up. The backend has one main-world observer; do not attach two GameViews to the same World.

Local mirrors support iOS 18 and macOS 15. On iOS 27, `.gameExternalDisplay(source, isEnabled:onAvailabilityChange:)` uses `ExternalNonInteractiveAccessory(isEnabled: .constant(isEnabled))`; the callback reports actual OS-role availability separately from `source.isAvailable`. There is no automatic macOS secondary window. The guide's native checklist covers Duo Book/Tabletop and outer transitions, rotation, quality changes while touching, unchanged simulation clocks with mirrors, and resume without physics catch-up. External presentation remains **unverified** unless an actual available OS role is exercised; schematic previews and local mirrors do not verify it.

[[Sources/SpriteUI/SpriteUI.docc/Articles/adaptive-game-surfaces.md]] explains local top-left point geometry, safe bounds, active/inactive reserved regions, deterministic usable regions, `GameViewport.region`, and HUD placement that fully fits or returns nil. Read `content.surfaceGeometry` in `update:`, observe one host with `.onGameSurfaceChange`, or read the environment inside attachment descendants. Attachments avoid reserved regions by clipping by default; their world anchors do not move. Effective changes to size, safe bounds, or active usable rectangles cancel pointer/touch captures, manipulation, and other native-routed actions and invalidate attachment contexts while preserving native hinge input and player sessions; scale-only and inactive-metadata changes publish events without cancellation. App-owned controls submit their own releases.

The **Surfaces** tab in [[Demo/SpriteUIDemo/AdaptiveSurfaceDemoView.swift]] provides System and explicitly simulated Flat, Book, Tabletop, and Obstructed layouts, optional resizing, and usable-region outlines around one retained world. Native UIKit on iOS 27.1 queries active and inactive regions on frames and layout passes; older iOS and macOS use safe areas only. Explicit `surfaceRegions` replace native regions; nil restores native reporting. Folds depend on reported regions; optional hinge input is documented separately. Read-only local mirrors and the optional iOS 27 general external accessory are now supported; that role does not grant Duo outer-display camera hosting. The camera-only role requires the full inner display and an active camera in a camera app; game presentation creates no camera capability or permission request. [[Examples/DemoBots/Game/DemoBotsSurfaceLayout.swift]] places the game's HUD and controls around usable geometry; DemoBots releases held virtual controls on effective layout changes without pausing the match.

[[Sources/SpriteUI/SpriteUI.docc/Articles/hinge-input-and-effects.md]] explains optional live `GameHingeState`, OS-provided status, radians and normalized openness, attachment-only hinge environment, host callbacks, and scene change events. Native `UIHingeInteraction` requires iOS 27.1 or later and available hardware; older iOS, macOS, and nonhinged devices report nil. Content and attachment environment values retain the last observed raw telemetry while native observation pauses hidden or inactive. Focus, scope, and app disable separately invalidate action-sample currency; resume requests a fresh OS sample even at an unchanged angle, and cached neutral cannot arm input. Unknown status suspends actions; genuine unavailability reports nil and disconnects the device. Raw hinge data drives effects while surface regions remain the layout source. Opt into normalized `.hinge` actions with `.gameInput(input, hinge:)` or `.gameInput(hub, hinge:)` and `HingeInputConfiguration`. Initial connection, reconnect, resume after focus or scope loss, input-blocking transitions, manual cancellation, configuration changes, and ownership transfer require raw calibrated neutral before native input can act. Coordinate-space-only changes preserve hinge input and its armed state; ordinary resizing or changed usable regions do not require another neutral reading. Smoothing uses monotonic real time. A hub announces a hinge only when available and configured; the app explicitly assigns it in a connection handler. Player sessions persist, physical loss disconnects, and hinge haptics are unsupported. Map the same axis action to keys or a virtual slider for fallback.

[[Sources/SpriteUI/SpriteUI.docc/Articles/render-layers-and-camera-visibility.md]] explains `RenderLayer` (`.default` uses bit zero; custom `.map` uses bit one), explicit ancestor subtree gates, unrestricted untagged entities, and camera/viewport mask intersection. The **Layers** tab in [[Demo/SpriteUIDemo/RenderLayersDemoView.swift]] shows one shared world in a left world camera and an interactive right map camera. Each physical object has separate world-square and map-diamond children. Select art in either pane to attach a label there; hiding that art hides its label. Visual hiding leaves motion, contact events, model queries, systems, and audio active.

The 280-point arena keeps visual hide switches, the map camera picker, and the optional world-only map-pane restriction within a compact scrolling phone screen. Choose Map only plus the pane restriction to see their empty intersection, then Both to admit only world art through the restricted pane. Bounce count, elapsed time, update count, and accumulated travel come from actual simulation events and positions. One `GameView(viewports: ...)` supplies a single world clock for both panes. The new source requires the main integration step to regenerate the demo project before building.

[[Sources/SpriteUI/SpriteUI.docc/Articles/parallax-and-repeating-backgrounds.md]] explains sprite-only camera offsets, per-axis factors and reference positions, normal zoom/rotation behavior, decorative picking, fixed model anchors, and bounded repetition. The **Parallax** tab in [[Demo/SpriteUIDemo/ParallaxDemoView.swift]] presents one procedural night landscape through independent A and B cameras. Move each camera with buttons or sliders, adjust its zoom, choose a layer and factor, and toggle Repeat or Split. Single mode preserves B’s position and zoom. The cyan child and label stay at the mountain’s model anchor while its own artwork shifts. The activity readout counts real events and compares five local model positions; it should remain at zero changed anchors. Background tiles create no extra entities or physics bodies. Main integration regenerates the demo project and runs the final builds and documentation checks.

[[Sources/SpriteUI/SpriteUI.docc/Articles/scene-transitions-and-level-management.md]] explains `content.levels`, detached preparation, persistent top-level siblings, scoped resources and cleanup, commit-aware cancellation, and transition input gating. The **Levels** tab in [[Demo/SpriteUIDemo/LevelTransitionDemoView.swift]] keeps one cyan player and camera while Garden and Workshop replace their own floor, bouncing ball, and update counter. Move the player and add score before switching; its ID, position, and component-backed score persist. Each later preparation loads the existing tiny `coin.wav` through `context.resources` and waits one second so Cancel and the one-shot failure control are deterministic to exercise. Choose Instant, Fade, or Crossfade; gameplay buttons stay usable during preparation and follow `blocksInput` during transitions, while Cancel stays enabled. Crossfade blends one captured outgoing game surface over the live incoming world without a second simulation; attachments are not captured. Model-owned tasks cancel on disappearance. Main integration regenerates the demo project and performs builds, simulator checks, and DocC validation.


With Xcode command-line tools and Python 3 installed, run from the repository root:

```sh
# Build a DocC archive and a static-hosting site.
Tools/build-documentation.sh

# Also type-check every tutorial stage and guide example in Swift 6.
Tools/build-documentation.sh check

# Rebuild on documentation edits and browse locally.
Tools/build-documentation.sh preview
```

Browse `http://localhost:8080/documentation/spriteui` during preview. Open `.build/documentation/SpriteUI.doccarchive` in Xcode to read the generated archive in its Documentation window. Stop preview with Control-C.

For a site hosted under a subdirectory, specify its base path:

```sh
Tools/build-documentation.sh build --hosting-base-path SpriteUI
```

You can change the output directory with `--output /path/to/SpriteUI.doccarchive` and the preview port with `--port 8081`. These commands build local files; publishing them is a separate step.

[[Tools/documentation.py]] extracts SwiftPM symbol graphs, restores source comments on the umbrella module's re-exported symbols, and verifies that all public APIs are present. It normalizes module-qualified documentation links for the single SpriteUI archive. DocC warnings fail the build, and generated graphs, logs, diagnostics, and archives stay under the ignored `.build/documentation/` directory. No documentation plugin or network dependency is added to the package.

## Working on the documentation

The catalog uses native [DocC markup](https://www.swift.org/documentation/docc/), including symbol links, articles, tutorial directives, images, and complete Swift code resources. Keep catalog page titles first, as required by DocC.

Edit articles under `Sources/SpriteUI/SpriteUI.docc/Articles/`, tutorials under `Tutorials/`, and their staged code and illustrations under `Resources/`. Every code stage is a complete view or scene implementation that can replace the preceding stage. Run `Tools/build-documentation.sh check` before committing documentation changes. The script checks links and tutorial structure, every standalone tutorial stage, and every Swift guide example (combining explicitly marked fragments with their preceding example); its diagnostic report is `.build/documentation/diagnostics.json`.

The top-level `Tools/` folder contains documentation tooling and the read-only local Game Center setup checker. Its `templates/` subfolder contains iOS/macOS entitlement templates; `tests/` contains setup-checker tests. The existing documentation checker automatically discovers staged Swift resources and Swift guide examples, so new samples need no hard-coded compilation counts in the tool. The `.docc` directory is documentation source for the SpriteUI target; it is not an app resource bundle. Example layouts remain in place; product source relocation is documented below.

## Example apps

- **Feature demo:** open `Demo/SpriteUIDemo.xcodeproj` and run the **SpriteUIDemo** scheme on an iOS simulator. Its tabs demonstrate individual SDK features.
- **DemoBots:** open `Examples/DemoBots/DemoBots.xcodeproj` and choose **DemoBots** for iOS or **DemoBotsMac** for macOS. [[Examples/DemoBots/readme.md]] describes controls, checkpoints, scene tools, and the features used by the game.

DemoBots exposes **Display & performance** on home and pause: Balanced requests scale 1 / 60 FPS / 16 MP, Battery Saver 0.75 / 30 / 8 MP, and High Refresh 1 / 120 / 16 MP. All enable system-pressure adaptation, so the OS may lower the request. FPS is preferred cadence, not achieved FPS; pixel budgets bound planned render targets, not global GPU memory. Opening the panel immediately disables the existing `PlayerInputSession` to cancel held input and gate late virtual-control samples, then closing it returns to the same home or paused phase with the existing world pause state untouched.

Its optional read-only `GamePresentationView` shares only the existing `main` pane, excluding HUD, menus, and native attachments. The source is attached only while local preview or external presentation is enabled; otherwise the host receives nil, retaining the same world and clock. The optional iOS 27 native noninteractive external accessory reports OS-role availability separately from completed-source availability and grants no Duo outer-camera entitlement. The DemoBots readme contains planned Duo simulator open/Book/Tabletop/outer, held-input, paused-preset, unavailable-external, preview-clock, and checkpoint-after-fold checks, pending main verification. Repeat on hardware before release; no physical-hardware session is claimed.

Both projects reference the local package. To regenerate either project, run `xcodegen generate` in its containing directory.

## Build and test

From the repository root:

```sh
swift build
swift test
```

Package tests use Swift Testing. Run `Tools/build-documentation.sh check` when changing documentation or its examples. App interaction and graphics checks run in the example apps on a simulator or device.

## Quests and leagues

[[Sources/SpriteUI/SpriteUI.docc/Articles/quests-and-leagues.md]] covers the deterministic Gameplay progression layer: `QuestJournal` with objectives, prerequisites, half-open windows, bounded duplicate protection, and reward receipts; `LeagueSeason` with fixed rosters, total/best scores, stable tie ranks, and explicit promotion/demotion at finalization. Both are Codable and replay validated ledgers when loaded. `QuestJournalComponent` adds entity events and can be registered for world snapshots. The Game Services showcase links to the Quests & leagues lab with file save/load.

`GameCenterServices.progression` explicitly maps player-owned quest progress to configured achievements and active-season points to a configured leaderboard. It never authenticates automatically or treats a partial leaderboard page as a league roster. Recurring leaderboard schedules must match the application season. Custom shared league authority and wallet transactions belong to the consuming game/server. [[Sources/SpriteUI/SpriteUI.docc/Tutorials/building-quests-and-leagues.tutorial]] provides a complete local exercise.

`Sources/Gameplay/Progression/` holds the new quest, league, and common validation values; GameplayECS contains the entity adapter and SpriteUIGameCenter contains the optional Apple reporting adapter.

## Product boundaries

[[Sources/SpriteUI/SpriteUI.docc/Articles/package-products-and-dependencies.md]] describes seven library products. `import SpriteUI` still includes everything. Select the `SpriteUICore` product and import it for a complete engine without the Game Center target; add the `SpriteUIGameCenter` product explicitly when needed. `Gameplay` already provides pure algorithms and progression rules as its own target/product, with no rendering or ECS dependencies. It remains in this package so it shares the release version.

Source layout: Apple-service code and its tests moved from `Sources/GameUI/GameCenter*.swift` and `Tests/GameUITests/GameCenter*.swift` to `Sources/SpriteUIGameCenter/` and `Tests/SpriteUIGameCenterTests/`. The noise-image, tile-map-grid, and replay-world bridges moved from `Sources/SpriteUI/` to `Sources/SpriteUICore/`. The SpriteUI target retains the DocC catalog and re-exports both aggregates. Direct GameUI consumers must import SpriteUIGameCenter to use the moved service symbols. [[Package.swift]] defines the dependency graph; [[Tools/documentation.py]] includes both new modules when checking the single reference archive.

## Player profiles and cloud saves

[[Sources/SpriteUI/SpriteUI.docc/Articles/player-profiles-and-cloud-saves.md]] covers the optional `SpriteUISaves` product: `PlayerProfileStore<State>`, guest/account namespaces, save slots, atomic quest receipt/wallet updates, optimistic revisions, migrations, checksummed bounded archives, explicit backup recovery, and deletion. Local saves use an application-scoped Application Support directory. `CloudSaveDirectory` wraps GameSave on iOS/macOS 26+ with explicit open/close, ready/offline/local-only phases, read-only conflict inspection, whole-directory selection, and invalidated stores after close/account changes. Local persistence remains available on iOS 18/macOS 15.

The Game Services showcase links to Profiles & saves, including a two-device account-free conflict preview. Native signed iCloud multi-device verification remains pending; previews never upload data. `Tools/templates/saves-icloud.entitlements` is a placeholder template for the consuming app’s iCloud Documents capability. No container or account is configured automatically. [[Sources/SpriteUI/SpriteUI.docc/Tutorials/saving-player-profiles.tutorial]] supplies a standalone local exercise.

Source layout: `Sources/SpriteUISaves/` contains profile values, file transactions, GameSave lifecycle/adapter, and explicit local previews; `Tests/SpriteUISavesTests/` contains their tests. `SpriteUI` re-exports the optional save module; neither SpriteUICore nor SpriteUIGameCenter depends on it.
