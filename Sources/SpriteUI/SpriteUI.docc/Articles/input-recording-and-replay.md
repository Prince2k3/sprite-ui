# Record a run and replay its commands

A player reports that a quick turn and a tap sent their character the wrong way. A recording lets you restore the run's starting state, replay its inputs, and pause at the moment you want to inspect.

SpriteUI records resolved input for each fixed tick. It records commands rather than video, so your game runs those commands again. Begin with <doc:fixed-step-simulation-and-interpolation> if your rules still run once per display frame.

## Decide what a replay must restore

To reproduce a run, save everything that influences its rules: player state, relevant entities, resource-backed scores, and random-generator state. The same commands applied to a different starting state can produce a different result.

``SpriteUI/InputReplayController`` can capture SpriteUI entity snapshots, the root transform, and the full current `world.random` value through `init(world:input:maximumFrames:checksum:)`. Register every authoritative Codable component before recording. Saving only a random seed cannot resume a generator that has already drawn values.

The default snapshot excludes `world.resources`. Put game state on registered entities or supply a capture/restore provider for resources too. Controllers, buffers, subscriptions, and UI state stay runtime-only. Restore replaces saved entity trees, so query the restored entities again rather than retaining old instances. Root runtime references remain in place.

## Feed recorded commands to the movement rule

One fixed system should obtain the tick's sample, share it with the rules that need input, and call `finishTick(_:)` after applying them. Another recorded rule must not poll live input or drain a second buffer.

The system below moves an actor using either live or replayed commands. Its runtime component holds the replay controller without including that reference in cloned or saved entities. Install the system after setting the fixed configuration and runtime resource.

```swift
import SpriteUI

enum RecordedActions {
    static let move = InputAction("move", kind: .axis)
}

struct RecordedActor: Component, Codable {
    var distance: Float = 0
}

struct RecordedRuntime: Component {
    let replay: InputReplayController
    @MainActor func cloned() -> Self? { nil }
}

@MainActor
struct RecordedMotionSystem: System {
    static var phase: SystemPhase { .fixedSimulation }
    private let query = EntityQuery(where: .has(RecordedActor.self))
    init(world: World) {}

    func update(context: UpdateContext) {
        guard let replay = context.world.resources[RecordedRuntime.self]?.replay else { return }
        do {
            let sample = try replay.sample(for: context)
            let distance = sample.value(for: RecordedActions.move).scalar
                * 80 * Float(context.deltaTime)
            for entity in context.entities(matching: query) {
                guard var state = entity.components[RecordedActor.self] else { continue }
                state.distance += distance
                entity.components.set(state)
                entity.position.x = state.distance
            }
            // Marks this sample ready; the core commits at fixed-tick completion.
            try replay.finishTick(context)
        } catch {
            // Stop this tick's rules. Present the controller error from app UI.
            context.world.isPaused = true
        }
    }
}
```

`sample(for:)` returns the same cached sample for repeated requests in a tick. `finishTick` marks that sample ready. At the end of the fixed tick, after all fixed systems and transform capture, the controller records or checks it. That end point includes changes made by later fixed systems.

Call recording and playback controls from SwiftUI handlers outside updates. Inside the fixed system, use only the sample/finish pair. An unfinished or interrupted tick is not added to the archive, though changes already made to your game state are not rolled back. Surface the controller's error in the UI after completion.

## Capture state before starting the run

Call `startRecording()` between updates. It saves the initial state and fixed configuration before recording the first tick. Call `stop()` to finish, then read `recording`.

An ``SpriteUI/InputRecording`` stores that state, configuration, and ordered input frames. Its tick numbers run from 1 through the frame count, independently of the world's lifetime tick counter. Duration is frame count multiplied by step duration.

For a score kept in a root resource, supply your own provider. This example encodes the counter and decodes it before changing the world. The closures capture the world weakly because the world may retain the controller.

```swift
import ECSCore
import Foundation

struct PersistentRun: Component, Codable {
    var score: Int = 0
}

enum RunProviderError: Error { case worldUnavailable }

@MainActor
func makeResourceReplay(world: World, input: InputController) -> InputReplayController {
    InputReplayController(
        world: world, input: input, maximumFrames: 36_000,
        captureState: { [weak world] in
            guard let world else { throw RunProviderError.worldUnavailable }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(world.resources[PersistentRun.self] ?? PersistentRun())
        },
        restoreState: { [weak world] data in
            guard let world else { throw RunProviderError.worldUnavailable }
            let state = try JSONDecoder().decode(PersistentRun.self, from: data)
            world.resources.set(state)
        }
    )
}
```

This provider saves only the counter shown. Extend it with entity state, other resources, and random state when those affect play. Choose and validate your own initial-state format before mutation. The default SpriteUI provider checks required component registrations, duplicate identities and component types, and the root pose before replacing entities; custom providers own their validation and restore policy.

## Replay and inspect a moment

Call `startPlayback(_:paused:)` to restore the starting state and apply the recorded fixed configuration. Live input is suppressed during playback. The controller supplies one archived frame per fixed tick; it does not rewind the world's lifetime tick count. An empty recording restores its starting state and finishes without running a tick.

Use `pause()` and `play()` for transport, and `step()` to advance one tick while paused. A step runs fixed rules only: it does not run ordinary frame updates, presentation systems, native physics, or actions. It clears interpolation history so inspection shows the new simulation pose.

Set `playbackSpeed` from 0.1 through 4 to change real-time playback speed. Recorded tick durations stay the same. Invalid values retain the previous speed and report an error; `setPlaybackSpeed(_:)` provides a throwing form.

At the end, on divergence, or on failure, live input remains suppressed until `stop()`. Stopping releases suppression and restores the previous clock preferences while preserving the caller's input-enabled setting. Controls resume through neutral gates. The current replay world remains; stopping does not restore the world that existed before playback.

On inactivity, pause playback or stop recording outside updates. Cancel input and clear virtual controls on focus loss. On disappearance, stop the controller and clear controls. [the complete example](https://github.com/Prince2k3/sprite-ui/blob/main/Sources/SpriteUI/SpriteUI.docc/Resources/spriteui-input-replay-03.swift) combines these controls in a complete scene.

## Check whether the same commands produced the same state

An optional checksum closure selects state to compare after each tick. Encode stable values such as actor position, event counts, and the complete random generator. Use sorted JSON keys and sort collections by stable game keys; sorted keys do not sort arrays. Exclude unrelated UI counters and presentation transforms.

A mismatch records the relative tick and expected and actual checksums in `divergence`, enters `.diverged`, and pauses. A checksummed recording needs a checksum provider for comparison. Inspect `lastError` for `.failed`; neither case silently resumes live play. These FNV-1a checksums compare the bytes you chose, rather than automatically checking the whole world, and are not cryptographic integrity checks.

## Save a finished recording

Choose an app-owned URL. This helper finishes the recording, writes it, and reads it through the validating initializer. Reading a file does not start playback.

```swift
import SpriteUI
import Foundation

@MainActor
func saveAndLoadReplay(_ replay: InputReplayController, at url: URL) throws -> InputRecording? {
    try replay.stop()
    guard let recording = replay.recording else { return nil }
    try recording.write(to: url)
    return try InputRecording(contentsOf: url)
}
```

For in-memory storage, use `jsonData(prettyPrinted:)` and `InputRecording(data:)`. Archives validate their version, input values, and consecutive tick sequence. Keep component names stable in builds that must read the same recordings; a missing required component is a playback error.

## Limits to keep in mind

Recording defaults to 36,000 frames and stops with an error at its configured limit rather than dropping earlier frames. An overflowed input sample also fails recording because its transition history is incomplete. Catch file and recording errors and show them to the user.

Configuration changes, skipped or unfinished ticks, wrong-world or wrong-phase calls, and lifecycle controls during system execution are errors. Wait for a complete backend frame before starting or changing playback.

A valid archive cannot guarantee that changed game rules will reproduce an older run. Native physics and actions still advance per display frame; replay does not guarantee deterministic physics or whole-world behavior. It can reproduce your fixed game logic when the saved state, ordering, random draws, and algorithms agree.

## See also

- <doc:input-actions-and-controllers>
- <doc:saving-and-debugging>
