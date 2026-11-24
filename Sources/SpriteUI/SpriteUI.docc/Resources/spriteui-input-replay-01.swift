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
        replay = InputReplayController(world: world, input: input, maximumFrames: 900)
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

    func suspendHost() {
        // Early stages finalize on inactivity; stage three retains paused playback.
        input.isEnabled = false
        neutralizeControls()
        stop()
        isSuspended = true
        world?.isPaused = true
    }

    func resumeHost() {
        neutralizeControls()
        isSuspended = false
        input.isEnabled = true
        world?.isPaused = false
    }

    func leave() { suspendHost() }

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

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("Input replay · stage 1").font(.headline)
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

                }

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
