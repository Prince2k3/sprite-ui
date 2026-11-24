# Multiplayer prediction and reconciliation

Predict a player's kinematic movement immediately, then reconcile it with acknowledged host state without giving the client authority over replicated entities.

## Keep prediction separate from replication

``SpriteUI/NetworkPrediction`` and ``SpriteUI/NetworkInputAuthority`` live in ECSCore and use portable Codable/Sendable state and input. ``SpriteUI/KinematicMovement2D`` lives in Gameplay. ``SpriteUI/NetworkMovementController2D`` and its fixed/presentation systems live in GameplayECS. Engine-only apps can use these through SpriteUICore; Game Center remains an optional transport and session setup layer.

The client predicts a separate unsynchronized visual. The canonical replica continues receiving host state through ``SpriteUI/NetworkSession``. Remote presentation interpolation remains unchanged. Do not add native physics to the predicted visual, publish its pose as host authority, or run a second movement system on the host actor. This initial adapter supports root-level rectangular center bounds, not collision rollback, native SpriteKit prediction, lag-compensated hits, or host migration.

## Sequence intent on the host's clock

The host creates a ``SpriteUI/NetworkPredictionStream`` containing the network entity, transport-authenticated owner, and fresh ownership epoch. Each ``SpriteUI/NetworkInputCommand`` has a positive sequence and narrow input, with no client-supplied time delta. The authority validates admission and queues commands. Only `advance()` consumes at most the next contiguous command on a host-owned fixed tick. Gaps use neutral input without skipping acknowledgment; duplicates cannot replace a queued command or run twice. A burst cannot accelerate simulation.

Each complete ``SpriteUI/NetworkAuthoritativeState`` includes a host revision and the latest actually simulated input. The client discards acknowledged commands, replaces canonical state immediately, and replays the remaining bounded history. Older/equal revisions do nothing. A future/regressing acknowledgment or wrong epoch fails validation. Explicit host corrections increment revision even when no new input was consumed.

This complete value-only exercise models two predicted inputs. Only the first is acknowledged, so reconciliation replays the second. Pure step and validation closures must use value-semantic state and must not publish events, play effects, or grant rewards: replay can execute them again. The generic values do not authenticate their own transport.

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

``SpriteUI/NetworkPredictionConfiguration`` defaults to 60 Hz and 256 pending inputs; construction/decoding bounds duration to 1/240...1/10 second and capacity to 1...512. An overflow refuses the new input rather than deleting unacknowledged history. Decide explicitly whether to stop/rebuild the stream. These are small-session limits, not an unbounded rollback archive.

## Attach one movement controller per owned actor

Both worlds need the same ``SpriteUI/World/fixedStep`` and movement rules. Retain controllers for their session lifetime. The factory installs fixed and presentation systems once; world registrations hold weak controller references. Up to 16 active movement controllers are supported per world, with one controller per network entity. The synchronized source must be root-level, select `transform`, and be owned by the authenticated remote player. Ownership alone never grants component write access.

This host helper runs after the session is connected and the application has attached the owned actor. Keep the returned controller in the match coordinator, not in a temporary local variable. The adapter advances authority; the app should not also move this actor from a command event handler.

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

Create the client controller only after its session has accepted the initial replica baseline. Supply a distinct root-level visual entity with no SynchronizationComponent or native physics; hide the owned canonical replica's artwork if necessary. Replica queries and snapshots remain canonical. The adapter waits for a host-approved stream before predicting, and checks identical movement rules and fixed duration. Input must be a finite vector of magnitude at most one; the shared rule prevents diagonal speed boosts and clamps the actor center to bounds.

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

Sample held input through `setInput(_:)`; one command is captured per client fixed tick. Tie neutral input and cleanup to the consuming app's player-input/session lifecycle. Zero input is a normal ordered command. Do not send another prediction from the presentation loop. This complete helper neutralizes input without ending a healthy controller; a full interruption uses `stop()` and the app's shared session/party interruption flow.

```swift
import SpriteUI

@MainActor
func updateMovementInput(_ direction: SIMD2<Float>, controller: NetworkMovementController2D,
                         gameplayActive: Bool) throws {
    try controller.setInput(gameplayActive ? direction : .zero)
}
```

Host `correct(to:)` applies canonical state immediately and schedules a reliable result. Client reconciliation never smooths the model. ``SpriteUI/NetworkMovementPresentationConfiguration`` smooths only the local visual's error offset; a zero duration or correction at/above snapDistance snaps it. Inspect pendingInputCount, acknowledgedInput, replayedInputCount, correctionDistance, correctionCount, rejectedCommandCount, status, and lastError. A failed controller needs explicit application recovery; it does not silently restart or discard its error.

## Keep packet and lifecycle boundaries

Inputs use reliable `sendCommand(_:)`. Initial stream state and explicit corrections use reliable delivery; normal complete results use unreliable delivery when the full envelope fits 1,000 bytes, falling back to reliable otherwise. A later complete result repairs a dropped result. `sendResponse(_:to:reliably:)` is host-only and requires a recipient's baseline handshake. Responses share `maximumCommandBytes` and `maximumPacketBytes` limits and carry the existing session/join identities. ``SpriteUI/NetworkEvents/ResponseReceived`` is raised only for the authenticated current host; unrelated application streams have no shared result revision filter. Each protocol must validate its own ordering. Responses must be sent outside a NetworkSession update callback to avoid reentrancy.

The adapter namespaces its messages and ignores unrelated protocols. It binds commands to entity, owner, client attempt, and host epoch, rejects invalid movement input, and consumes only one command per host tick. Transport callback queues and pending input remain bounded. This is host-authoritative cooperative game logic, not a trusted server or a general anti-cheat service.

Keep fixed world updates and the session's presentation system advancing exactly once. Pause stops automatic updates. Interruption, owner departure, session teardown, ownership transfer, or fixed-clock mismatch retires the controller; the app must release it and create fresh controllers after the new baseline. Never restore prediction history or smoothing offsets from a checkpoint. The current owner must agree on a fresh host epoch after recovery or rejoin. Stop input, controllers, and the app-owned transport on background/menu exit according to the game's lifecycle policy; foregrounding alone must not revive held input. See <doc:multiplayer-recovery-and-rejoining>.

## Verify the local protocol and live transport separately

The Game Services showcase's Prediction & reconciliation lab and <doc:predicting-multiplayer-movement> use two headless worlds over an account-free byte link. Compare the local visual, host, and latest canonical replica; increase latency, jitter, and unreliable loss, then nudge host authority and stop input. Model convergence and bounded acknowledgment repair are also covered by tests, including total loss of normal results followed by a reliable correction.

The adapter works with an already-connected Game Center session; it does not sign in, match players, transfer ownership, or recover a session automatically. Native signed two-account verification remains pending in this checkout, whose local simulator app has no signed Game Center entitlement. Successful offline tests and builds do not prove live service delivery. Follow <doc:game-center-sessions-and-replication> for native app configuration and test prediction, backgrounding, input cancellation, rejoin, and fresh-epoch rejection on signed devices before release.
