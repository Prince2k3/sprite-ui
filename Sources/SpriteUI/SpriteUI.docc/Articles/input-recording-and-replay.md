# Input recording and replay

Record resolved input at fixed ticks, restore an initial application state, and replay the same commands with optional diagnostic checksums.

Read <doc:fixed-step-simulation-and-interpolation> and <doc:running-fixed-step-simulation> first. Then follow <doc:running-input-replays> for three complete, asset-free SwiftUI stages: record, replay with checksums, and inspect playback with pause, step, speed, and lifecycle cleanup.

## Choose the state that makes a run reproducible

``SpriteUI/InputRecording`` is an immutable, versioned archive of a `FixedStepConfiguration`, opaque `initialState: Data`, and ordered `InputRecordingFrame` values. Each frame holds a relative `tick`, a `FixedInputSample`, and an optional `InputRecordingChecksum`. Archive ticks are exactly `1...n`; they are independent of `world.fixedStepState.tick`, which remains a monotonic lifetime counter through restore, playback, and stepping. `duration` is frame count times the configured step duration.

``SpriteUI/InputReplayController`` is a main-actor observable runtime owner. Its SpriteUI convenience initializer, `init(world:input:maximumFrames:checksum:)`, captures registered entity snapshots, the root transform, and the **full current state** of `world.random`. Register every authoritative Codable component before recording. A seed alone cannot resume a generator that has already produced values.

Default entity snapshots exclude the hidden root and `world.resources`; the replay convenience provider saves the root transform separately. Keep authoritative game state on registered entities, or supply custom capture/restore providers that include persistent resource values. Systems, input subscriptions, buffers, controller references, and UI state stay runtime-only. A component holding those references should return `nil` from `cloned()` and remain unregistered. The default restore keeps root runtime references in place while replacing the saved entity trees; query restored entities again instead of retaining old entity instances.

The default provider validates required registered component names with `ComponentRegistry.isRegistered(named:)` before destructive restore, and rejects duplicate entity IDs, duplicate component types, and nonfinite root poses. Register custom types under stable names in every build that must read an archive. Unknown required types are a playback error; ordinary snapshot decoding's ability to skip unknown components is insufficient for replay.

## Give one fixed system ownership of the sample

Call `sample(for:)` once at the beginning of the owning `.fixedSimulation` system, pass that value to **all** its input-dependent rules, and call `finishTick(_:)` after those rules. A repeated sample request for the same tick returns the cached sample; it does not consume the next frame. Do not consume a separate buffer or poll live input for another recorded rule.

This complete system stores its controller on the root, excludes that reference from snapshots, and applies a single kinematic rule. Install it once with `world.systems.add(RecordedMotionSystem.self)` after assigning a fixed configuration and the runtime resource. Invoke lifecycle controls from SwiftUI outside system updates.

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

`finishTick` marks the sample ready. At core fixed-tick completion, **after all fixed systems and transform capture**, the controller computes the optional checksum, appends or compares the frame, and pauses at EOF or divergence. Put all authoritative replay rules under the owner and keep their order stable. Later fixed systems are included in the completion boundary; a checksum taken immediately inside the owner would be too early.

Interrupted or unfinished ticks fail closed and discard pending archive work; a half tick is never appended. This does not roll back application mutations already made during that tick. Wrong-world or wrong-phase contexts, changed configuration, skipped or incomplete ticks, and reentrant lifecycle mutations are errors. `startRecording`, `startPlayback`, `play`, `pause`, `step`, and `stop` belong outside system execution; only the sample/finish protocol belongs inside the fixed update. Check completion/error state from UI after the tick, not immediately after `finishTick`.

Live mode simply consumes the owned buffer. Recording reserves the next sample until completion. Playback supplies the next archived frame while live input is suppressed. Finished playback returns neutral input as documented by the controller so an outstanding catch-up callback cannot reuse the last command; neutral input is not a general recovery path for invalid calls or failed playback. An empty archive restores its initial state and becomes finished immediately without executing a replay tick.

## Capture and restore outside the tick

Call `startRecording()` between updates. It freezes the initial state and fixed configuration before the first recorded tick. `stop()` finalizes recording; read `recording` afterward. `startPlayback(_:paused:)` restores the initial state, applies the archive configuration, acquires live-input suppression, and prepares the clock without rewinding lifetime ticks. Lifecycle controls also reject an unfinished backend frame, even between its system callbacks. No earlier live-world snapshot is automatically restored on stop.

For authoritative root resources, use the designated ECSCore initializer. This complete example records a resource-backed counter, permits an opaque initial-state format, and validates data before mutating the world. Both closures capture the world weakly because the controller can itself be stored on the root.

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

That provider saves only the resource shown. Extend your own envelope to include entity state, every authoritative resource, and random-generator state if those affect the rules. A custom provider may legitimately use empty `Data` when it has no initial state; the core does not impose the default SpriteUI snapshot format. Provider validation and restore policy are application responsibilities.

## Compare selected application state

The optional `checksum` closure returns `Data` representing selected application state. The controller hashes those bytes using deterministic FNV-1a 64-bit diagnostics. `InputRecordingChecksum(rawValue:)` and `init(data:)` are Codable, Hashable, and Sendable; `description` is hexadecimal. These checksums detect divergence for the bytes you selected; they are not cryptographic integrity checks or automatic hashes of the world, entity IDs, or rendered pixels.

Encode stable application values using a `JSONEncoder` with `.sortedKeys`. Sort collections by stable application keys as well; sorted JSON keys do not reorder arrays. Include the full `world.random` value when random draws matter. The tutorial hashes its actor's Codable position and event counts plus the generator, excluding UI counters, world lifetime ticks, IDs, and presentation transforms. Capture the world weakly in checksum closures retained by a root-owned controller.

A mismatch exposes the relative tick and expected/actual checksums through `divergence`, changes state to `.diverged`, and pauses at tick completion. A checksum provider must be present when comparing checksummed frames. Inspect `lastError` when state becomes `.failed`; neither divergence nor failure silently switches to live commands.

## Pause, step, and change speed

The public states are `.live`, `.recording`, `.playing`, `.paused`, `.finished`, `.diverged`, and `.failed`. Use `pause()` and `play()` for playback transport. `playbackSpeed` accepts finite values in `0.1...4`; invalid assignments retain the prior speed and set `lastError`. Use throwing `setPlaybackSpeed(_:)` for explicit error handling. Valid playback speed drives `world.timeScale` during playback; it changes wall-clock playback cadence, not recorded fixed deltas.

While playback is paused, `step()` delegates to `world.stepFixedSimulation()`. This world API executes exactly one fixed tick at 1× with equal scaled and unscaled deltas of `1 / stepsPerSecond`. It requires a paused world, an active root, a fixed configuration, no reentry, and no unfinished backend frame. It publishes `WorldEvents.FixedUpdate` and runs fixed systems, without publishing `WorldEvents.Update` or running variable systems, presentation systems, native physics, or actions. It creates no backend debug physics frame. Clock remainder and interpolation history clear; lifetime ticks continue upward. It is distinct from a renderer debug-frame step.

End-of-file, divergence, and playback failure keep live input suppressed until explicit cleanup. `stop()` releases the controller's suppression lease and restores prior clock preferences. It preserves the caller's `input.isEnabled` preference rather than overwriting it to implement playback suppression. Live controls resume through neutral gates. The current replay world remains in place.

On focus loss, cancel input and neutralize app-owned virtual controls. Pending buffer transitions are discarded; playback remains suppressed and committed archive frames are unchanged. For inactivity, pause active playback or stop recording outside updates, then explicitly resume when appropriate. On disappearance, call `stop()` and clear controls. The tutorial shows this policy without a second input buffer.

## Validate archives and bound recording

`InputRecorder(configuration:initialState:maximumFrames:)` defaults to 36,000 frames and clamps the limit to `1...1_000_000`. Its mutating `append(_:checksum:)` assigns consecutive relative ticks. At the limit it throws `.frameLimitReached` instead of dropping old frames. Overflowed input throws `.inputOverflow`; the original `FixedInputBuffer` still drops its oldest event and reports `didOverflow`, but recording refuses to archive that lossy sample.

`FixedInputSample(values:events:didOverflow:)` is a nonthrowing initializer of immutable, Codable, Equatable data. Decoding and recorder append validate action/value kinds and normalized finite values. Decoding rejects duplicate action entries. The action dictionary serializes as a sorted array for stable bytes; event order is preserved, including cancellation phases. Cancellation is not a release. `InputActionEvent(action:value:phase:)` is public, Hashable, and Codable.

Version 1 archives validate their format, supported version, frames, input, and exact tick sequence. `InputRecordingError` includes `.invalidFormat`, `.unsupportedVersion(Int)`, `.invalidFrame`, `.inputOverflow`, and `.frameLimitReached`. Catch file I/O errors as well. Archives are immutable; construct a validated value instead of mutating an unchecked decoded archive.

This complete file helper writes the finalized recording and reads it through the version-validating initializer. Choose an application-owned URL; loading a file does not itself start playback.

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

Use `jsonData(prettyPrinted:)` and `InputRecording(data:)` for an in-memory round trip. File validation cannot guarantee that an application's current rules still reproduce an older run. Custom fixed systems can reproduce selected application logic when state, ordering, random draws, and algorithms agree. Native physics and actions retain their display-frame lifecycle; recording/replay does **not** guarantee deterministic native physics or deterministic whole-world behavior.

## See also

- <doc:running-input-replays>
- <doc:fixed-step-simulation-and-interpolation>
- <doc:input-actions-and-controllers>
- <doc:saving-and-debugging>
