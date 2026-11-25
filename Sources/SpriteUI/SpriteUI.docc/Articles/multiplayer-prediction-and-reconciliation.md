# Make multiplayer movement respond immediately

A player presses right, but the host's reply takes time to arrive. Waiting for that reply makes movement feel sluggish. Let the local game show the expected movement immediately, then correct it when the host reports what actually happened.

This is prediction followed by reconciliation: keep the player's unconfirmed inputs, accept the host's answer, and replay only the inputs the host has not processed yet.

## Move a local visual, keep the host's answer

The client uses two entities for its player. A synchronized replica holds the latest host state. A separate, unsynchronized visual shows the predicted movement. Queries and snapshots still read the replica, while presentation can feel immediate.

``SpriteUI/NetworkPrediction`` manages this idea with value state and input. ``SpriteUI/NetworkInputAuthority`` processes those inputs on the host. The 2D movement adapter connects them to worlds and sessions; Game Center is only one possible transport.

## Count inputs instead of trusting client time

Each input has a sequence number. The host creates a stream identifying the actor, authenticated owner, and a fresh ownership period, called an epoch. The client cannot choose its own simulation time delta.

On each host fixed tick, `advance()` consumes at most the next contiguous input. A missing input uses neutral movement without skipping its acknowledgment. Duplicates cannot run again, and sending a burst cannot buy extra simulation time.

This example predicts two steps but sends only the first to the host. When the host acknowledges one step, the client starts from that answer and replays the remaining step. The displayed result stays at two.

```swift
import SpriteUI

func reconcileTwoInputs() throws -> Int {
    let owner = NetworkPeerID(rawValue: "player")
    let stream = NetworkPredictionStream(entity: NetworkEntityID(), owner: owner)
    var host = try NetworkInputAuthority<Int, Int>(stream: stream, state: 0, idleInput: 0,
        validateInput: { guard (-1...1).contains($0) else { throw NetworkPredictionError.invalidSequence } },
        step: { state, input, _ in state + input })
    var client = try NetworkPrediction<Int, Int>(authoritative: host.snapshot,
        step: { state, input, _ in state + input })
    let first = try client.predict(1)
    _ = try client.predict(1)
    _ = try host.receive(first, from: owner)
    let result = try host.advance()
    _ = try client.reconcile(result)
    return client.state // 2: host state 1 plus the one unacknowledged input.
}
```

Keep the `step` and validation closures pure and value-based. Replaying movement may run them again, so they must not play sounds, publish events, or grant rewards. The generic values also need an authenticated transport around them; they do not establish sender identity themselves.

A host result includes a revision and the last input actually simulated. Older results do nothing. Invalid acknowledgments or an incorrect epoch fail validation rather than discarding uncertain input history.

## Let one controller move the host actor

Use the same fixed-step duration and movement rules in both worlds. The host controller advances the remotely owned actor; do not also move it from an application command handler.

Attach it after the connected session and root-level synchronized actor exist. The actor must select `transform` and belong to the authenticated remote player. Retain the returned controller in your match state, because world registrations hold it weakly.

```swift
import SpriteUI

@MainActor
func attachHostMovement(world: World, session: NetworkSession,
                        actor: Entity) throws -> NetworkMovementController2D {
    let rules = KinematicMovement2D(maximumSpeed: 120,
        bounds: BoundingBox(center: .zero, size: [800, 600]))
    return try .host(in: world, session: session, entity: actor, rules: rules)
}
```

These rules move at up to 120 units per second and keep the actor's center inside an 800-by-600 rectangle. Input length is limited to one, preventing faster diagonal movement.

## Give the client its own visual

Wait until the client has received its initial host replica. Then create a separate root-level visual without `SynchronizationComponent` or native physics and attach the client controller. Hide the owned replica's artwork if it would draw a second player.

```swift
import SpriteUI

@MainActor
func attachClientMovement(world: World, session: NetworkSession,
                          entityID: NetworkEntityID, visual: Entity) throws -> NetworkMovementController2D {
    let rules = KinematicMovement2D(maximumSpeed: 120,
        bounds: BoundingBox(center: .zero, size: [800, 600]))
    return try .client(in: world, session: session, entityID: entityID, visual: visual,
        rules: rules, presentation: .init(smoothingDuration: 0.12, snapDistance: 100))
}
```

The controller waits for the host-approved stream and checks the movement rules and fixed duration. Its visual can smooth a small correction over 0.12 seconds; a correction of 100 units or more snaps. The model accepts the host correction immediately regardless of visual smoothing.

## Sample held input on fixed ticks

Call `setInput(_:)` when the player's direction changes. The controller captures one ordered command per client fixed tick, including zero input. Avoid sending a second prediction from the presentation loop.

This helper turns movement neutral when gameplay loses focus without stopping a healthy controller.

```swift
import SpriteUI

@MainActor
func updateMovementInput(_ direction: SIMD2<Float>, controller: NetworkMovementController2D,
                         gameplayActive: Bool) throws {
    try controller.setInput(gameplayActive ? direction : .zero)
}
```

For a full interruption, stop the controller and use the app's party/session cleanup. Returning to the foreground must not revive an old held button. After recovery or ownership changes, wait for a new baseline and create fresh controllers and epochs. Prediction history and smoothing offsets belong to the old connection, not to a checkpoint.

## Observe a correction

The host can call `correct(to:)` to apply a position immediately and send a reliable result. Watch `pendingInputCount`, `acknowledgedInput`, and `correctionDistance` to see how much local work remains and how far the visual differs from the host.

Inputs and initial stream setup use reliable delivery. Normal complete results can use unreliable delivery when they fit 1,000 bytes; a later result repairs a dropped one. Corrections are reliable. Keep world and session updates advancing exactly once. A failed controller needs the app to stop or rebuild it rather than silently restart.

The showcase's Prediction & reconciliation lab lets you add delay, vary packet timing, and nudge the host position. For shots, read <doc:multiplayer-interactions-and-lag-compensation>: movement replay must never grant an interaction effect.

## Limits and native validation

This adapter handles root-level kinematic movement inside rectangular center bounds. It does not predict native SpriteKit physics or replay collisions through an arbitrary level. Do not add native physics to the predicted visual. The host remains a cooperative player's device, not a trusted anti-cheat server.

Prediction defaults to 60 Hz and 256 pending inputs. Supported durations are 1/240 through 1/10 second, history capacity is 1 through 512, and a world supports 16 movement controllers, one per actor. Overflow refuses new input rather than losing unacknowledged history. Session command and packet limits also apply. Custom response protocols must validate their own ordering and send responses outside session update callbacks.

Signed two-account Game Center verification remains pending. Test movement, backgrounding, neutral input, rejoin, and rejection of old epochs on configured signed devices; local byte-link results do not establish native delivery. See <doc:game-center-sessions-and-replication> for connection setup.
