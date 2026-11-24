import Foundation
import Observation
import SpriteUI
import SwiftUI

// Replace ContentView.swift with this entire file; keep the app entry point.
enum ReplayActions {
    static let move = InputAction("move", kind: .axis)
    static let burst = InputAction("burst")
    static let map = InputActionMap(name: "Replay controls", bindings: [
        InputBinding(move, control: .virtual("left"), scale: [-1, 0]),
        InputBinding(move, control: .virtual("right"), scale: [1, 0]),
        InputBinding(move, control: .key("a"), scale: [-1, 0]),
        InputBinding(move, control: .key("d"), scale: [1, 0]),
        InputBinding(burst, control: .virtual("burst")),
        InputBinding(burst, control: .key("space"))
    ])
}

// Authoritative model state is saved on the entity, not in a system or UI owner.
struct ReplayActor: Component, Codable {
    var x: Float = -100
    var presses = 0
    var releases = 0
}

// Runtime services survive entity restore and never enter snapshots or clones.
struct ReplayRuntime: Component {
    let scene: ReplayScene
    @MainActor func cloned() -> Self? { nil }
}

// Stable bytes include the complete generator state, not only its original seed.
struct ReplayCheck: Codable {
    let actor: ReplayActor
    let random: SeededGenerator
}

enum ReplayExampleError: Error { case missingWorld, missingActor }

@MainActor
struct ReplayRules: System {
    static var phase: SystemPhase { .fixedSimulation }
    private let query = EntityQuery(where: .has(ReplayActor.self))
    init(world: World) {}

    func update(context: UpdateContext) {
        guard let scene = context.world.resources[ReplayRuntime.self]?.scene,
              let replay = scene.replay else { return }
        do {
            // One owner samples before ALL rules. Do not poll live input here.
            let sample = try replay.sample(for: context)
            for entity in context.entities(matching: query) {
                guard var actor = entity.components[ReplayActor.self] else { continue }
                actor.x += sample.value(for: ReplayActions.move).scalar
                    * 80 * Float(context.deltaTime)
                // Preserve event order, including a complete tap between ticks.
                for event in sample.events where event.action == ReplayActions.burst {
                    switch event.phase {
                    case .pressed:
                        actor.presses += 1
                        actor.x += 16 + Float(context.world.random.nextUnit()) * 8
                    case .released: actor.releases += 1
                    default: break // Cancellation is not a release.
                    }
                }
                actor.x = min(120, max(-120, actor.x))
                entity.components.set(actor)
                entity.position.x = actor.x
                scene.position = actor.x
                scene.presses = actor.presses
                scene.releases = actor.releases
            }
            scene.lastLifetimeTick = context.fixedTick ?? 0
            // Marks ready. Commit/checksum/EOF happen after ALL fixed systems
            // and transform capture at the core fixed-tick completion boundary.
            try replay.finishTick(context)
        } catch {
            scene.status = "Fixed tick failed: \(error)"
            context.world.isPaused = true
            // Do not execute more rules or commit a partially executed tick.
        }
    }
}

@MainActor @Observable
final class ReplayScene {
    let input = InputController(contexts: [ReplayActions.map])
    var replay: InputReplayController?
    var saved: InputRecording?
    var status = "Ready to record"
    var position: Float = -100
    var presses = 0
    var releases = 0
    var lastLifetimeTick: UInt64 = 0
    var isSuspended = false
    @ObservationIgnored private weak var world: World?

    var acceptsControls: Bool {
        guard !isSuspended, let replay else { return false }
        switch replay.state {
        case .live, .recording: return true
        default: return false
        }
    }

    func install(in content: GameViewContent) {
        let world = content.world
        self.world = world
        ReplayActor.registerComponent(named: "tutorial.replay-actor.v1")
        SpriteRenderer.registerComponents()
        world.fixedStep = FixedStepConfiguration(stepsPerSecond: 30)
        world.random = SeededGenerator(seed: 42)
        let actor = Entity(name: "replay-player", components:
            SpriteComponent(color: .cyan, size: [32, 32]), ReplayActor())
        actor.position = [-100, 0]
        content.add(actor)
        world.resources.set(ReplayRuntime(scene: self))
        // The controller lives on this world's root: never capture world strongly.
        replay = InputReplayController(world: world, input: input, maximumFrames: 900,
            checksum: { [weak world] in
                guard let world else { throw ReplayExampleError.missingWorld }
                let query = EntityQuery(where: .has(ReplayActor.self))
                guard let entity = world.performQuery(query).first,
                      let actor = entity.components[ReplayActor.self] else {
                    throw ReplayExampleError.missingActor
                }
                // Selected application state only: no entity IDs, pixels or clocks.
                let state = ReplayCheck(actor: actor, random: world.random)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                return try encoder.encode(state)
            })
        do {
            try world.systems.add(ReplayRules.self)
            world.isPaused = isSuspended
        } catch {
            status = "Could not install replay rules: \(error)"
            world.isPaused = true
        }
    }

    func perform(_ operation: () throws -> Void) {
        do { try operation() }
        catch { status = "Replay control failed: \(error)" }
    }

    func neutralizeControls() {
        input.cancelAll()
        for name in ["left", "right", "burst"] {
            input.setValue(.button(false), for: .virtual(name), device: .virtual("replay-pad"))
        }
    }

    func record() {
        guard let replay, !isSuspended else { return }
        perform {
            try replay.stop()
            neutralizeControls()
            world?.isPaused = false
            try replay.startRecording()
            status = "Recording at 30 Hz; tap or hold a direction"
        }
    }

    func stop() {
        guard let replay else { return }
        perform {
            try replay.stop()
            neutralizeControls()
            // Keep a validated value independent of future recording sessions.
            saved = replay.recording
            if isSuspended { world?.isPaused = true }
            status = "Stopped; \(saved?.frames.count ?? 0) completed frames saved"
        }
    }

    func tapBurst() {
        guard acceptsControls else { return }
        input.setValue(.button(true), for: .virtual("burst"), device: .virtual("replay-pad"))
        input.setValue(.button(false), for: .virtual("burst"), device: .virtual("replay-pad"))
    }

    func refreshModelReadout() {
        guard let world else { return }
        let query = EntityQuery(where: .has(ReplayActor.self))
        guard let entity = world.performQuery(query).first,
              let actor = entity.components[ReplayActor.self] else { return }
        position = actor.x
        presses = actor.presses
        releases = actor.releases
    }

    func playback(paused: Bool = false) {
        guard let replay, let saved, !isSuspended else { return }
        perform {
            try replay.stop()
            neutralizeControls()
            // This exercises version/frame validation without requiring a file.
            let loaded = try InputRecording(data: saved.jsonData())
            try replay.startPlayback(loaded, paused: paused)
            refreshModelReadout()
            status = "Playing the restored initial state with selected-state checksums"
        }
    }

    func play() {
        guard let replay, !isSuspended else { return }
        perform { try replay.play() }
    }

    func pause() {
        guard let replay else { return }
        perform { try replay.pause() }
        neutralizeControls()
    }

    func step() {
        guard let replay, !isSuspended else { return }
        perform { try replay.step() }
    }

    func setSpeed(_ speed: Double) {
        guard let replay else { return }
        perform { try replay.setPlaybackSpeed(speed) }
    }

    func alterSelectedState() {
        guard replay?.state == .paused, let world else { return }
        let query = EntityQuery(where: .has(ReplayActor.self))
        guard let entity = world.performQuery(query).first,
              var actor = entity.components[ReplayActor.self] else { return }
        actor.x += 1
        actor.presses += 1 // Remains different even if the next movement clamps x.
        entity.components.set(actor)
        entity.position.x = actor.x
        position = actor.x
        presses = actor.presses
        status = "Selected state changed; step a remaining frame to see divergence"
    }

    func suspendHost() {
        guard !isSuspended else { return }
        input.isEnabled = false
        neutralizeControls()
        if let replay {
            perform {
                switch replay.state {
                case .recording:
                    try replay.stop()
                    saved = replay.recording
                case .playing:
                    try replay.pause()
                default: break
                }
            }
        }
        // Paused/finished/diverged playback retains its input suppression lease.
        isSuspended = true
        world?.isPaused = true
        status = "Inactive; input cancelled. Resume scene, then Play if needed"
    }

    func resumeHost() {
        neutralizeControls()
        isSuspended = false
        input.isEnabled = true
        // Playback waits for an explicit Play. The lease still suppresses input.
        if replay?.state == .live { world?.isPaused = false }
    }

    func leave() {
        input.isEnabled = false
        neutralizeControls()
        // Release playback suppression and restore prior clock preferences.
        stop()
        isSuspended = true
        world?.isPaused = true
    }

}

@MainActor
struct ReplayHoldStyle: ButtonStyle {
    let scene: ReplayScene
    let control: String
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(12)
            .background(configuration.isPressed ? Color.cyan : Color.gray.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onChange(of: configuration.isPressed) { _, pressed in
                guard !pressed || scene.acceptsControls else { return }
                scene.input.setValue(.button(pressed), for: .virtual(control), device: .virtual("replay-pad"))
            }
            .onDisappear {
                scene.input.setValue(.button(false), for: .virtual(control), device: .virtual("replay-pad"))
            }
    }
}

@MainActor
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var scene = ReplayScene()
    @State private var speed = 1.0

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("Input replay · stage 3").font(.headline)
                GameView { scene.install(in: $0) }
                    .frame(height: 240)
                    .gameInput(scene.input, isActive: !scene.isSuspended)
                HStack {
                    Button("Hold left") {}
                        .buttonStyle(ReplayHoldStyle(scene: scene, control: "left"))
                    Button("Hold right") {}
                        .buttonStyle(ReplayHoldStyle(scene: scene, control: "right"))
                }.disabled(!scene.acceptsControls)
                Button("Tap burst between ticks") { scene.tapBurst() }
                    .disabled(!scene.acceptsControls)
                HStack {
                    Button("Record") { scene.record() }.disabled(scene.isSuspended)
                    Button("Stop / save") { scene.stop() }
                    Button("Replay from start") { scene.playback() }
                        .disabled(scene.saved == nil || scene.isSuspended)
                }
                HStack {
                    Button("Load paused") { scene.playback(paused: true) }
                        .disabled(scene.saved == nil || scene.isSuspended)
                    Button("Play") { scene.play() }
                        .disabled(scene.replay?.state != .paused || scene.isSuspended)
                    Button("Pause") { scene.pause() }
                        .disabled(scene.replay?.state != .playing)
                    Button("Step") { scene.step() }
                        .disabled(scene.replay?.state != .paused || scene.isSuspended)
                }
                Picker("Playback speed", selection: $speed) {
                    Text("0.5×").tag(0.5)
                    Text("1×").tag(1.0)
                    Text("2×").tag(2.0)
                    Text("4×").tag(4.0)
                }.pickerStyle(.segmented)
                    .onChange(of: speed) { _, value in scene.setSpeed(value) }
                Button("Alter state to diagnose divergence") { scene.alterSelectedState() }
                    .disabled(scene.replay?.state != .paused || scene.isSuspended)
                if scene.isSuspended {
                    Button("Resume scene") { scene.resumeHost() }
                }
                Text(scene.status).font(.caption)
                Text("x \(scene.position, specifier: "%.1f") · Presses \(scene.presses) · Releases \(scene.releases)")
                    .font(.caption.monospacedDigit())
                Text("Last sampled lifetime tick \(scene.lastLifetimeTick) · Archive frames \(scene.saved?.frames.count ?? 0)")
                    .font(.caption.monospacedDigit())
                if let replay = scene.replay {
                    Text("Mode: \(String(describing: replay.state)) · Archive frame count \(replay.recording?.frames.count ?? 0)")
                        .font(.caption)
                    if let error = replay.lastError {
                        Text("Replay error: \(String(describing: error))").font(.caption)
                    }
                    if let divergence = replay.divergence {
                        Text("Diverged at relative tick \(divergence.tick)")
                        Text("Expected \(divergence.expected.description) · Actual \(divergence.actual.description)")
                            .font(.caption.monospaced())
                    }
                }
                Text("No assets or hardware required. Optional: focus the game and use A/D or Space.")
                    .font(.caption)
            }.padding()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { scene.suspendHost() }
        }
        .onDisappear { scene.leave() }
    }
}
