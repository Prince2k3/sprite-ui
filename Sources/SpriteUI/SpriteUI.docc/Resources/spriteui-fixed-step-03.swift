import Observation
import SpriteUI
import SwiftUI

// Replace ContentView.swift with this entire file; keep the app entry point.
enum DemoFixedStepActions {
    static let move = InputAction("move", kind: .axis)
    static let burst = InputAction("burst")
    static let map = InputActionMap(name: "Fixed play", bindings: [
        InputBinding(move, control: .virtual("left"), scale: [-1, 0]),
        InputBinding(move, control: .virtual("right"), scale: [1, 0]),
        InputBinding(move, control: .key("a"), scale: [-1, 0]),
        InputBinding(move, control: .key("d"), scale: [1, 0]),
        InputBinding(burst, control: .virtual("burst")),
        InputBinding(burst, control: .key("space"))
    ])
}

@MainActor @Observable
final class DemoFixedStepInput {
    let input: InputController
    let buffer: FixedInputBuffer
    var presses = 0
    var releases = 0
    var lastEventCount = 0
    var overflows = 0
    var clock: FixedStepState?

    init() {
        let controller = InputController(contexts: [DemoFixedStepActions.map])
        input = controller
        buffer = FixedInputBuffer(input: controller, capacity: 256)
    }
}

// Runtime state shared by two systems; it is not saved or cloned.
struct DemoFixedStepDriver: Component {
    let state: DemoFixedStepInput
    @MainActor func cloned() -> Self? { nil }
}

struct DemoFixedStepActor: Component {}

@MainActor
struct DemoFixedStepInputSystem: System {
    static var phase: SystemPhase { .fixedSimulation }
    private let query = EntityQuery(where: .has(DemoFixedStepActor.self))

    init(world: World) {}

    func update(context: UpdateContext) {
        guard let driver = context.world.resources[DemoFixedStepDriver.self] else { return }
        let state = driver.state
        // Consume once for the entire tick, then share the sample with both actors.
        let sample = state.buffer.consume()
        let burst = sample.wasPressed(DemoFixedStepActions.burst)
        if burst { state.presses += 1 }
        if sample.wasReleased(DemoFixedStepActions.burst) { state.releases += 1 }
        state.lastEventCount = sample.events.count
        if sample.didOverflow { state.overflows += 1 }
        let distance = sample.value(for: DemoFixedStepActions.move).scalar
            * 100 * Float(context.deltaTime) + (burst ? Float(24) : 0)
        for entity in context.entities(matching: query) {
            entity.position.x = min(100, max(-100, entity.position.x + distance))
        }
    }
}

@MainActor
struct DemoFixedStepStatusSystem: System {
    static var phase: SystemPhase { .presentation }
    init(world: World) {}

    func update(context: UpdateContext) {
        // Presentation runs after all fixed ticks, so this is the completed frame's state.
        context.world.resources[DemoFixedStepDriver.self]?.state.clock = context.world.fixedStepState
    }
}

@MainActor @Observable
final class DemoFixedStepScene {
    let controls = DemoFixedStepInput()
    var isPaused = false
    var status = "Preparing buffered input"
    @ObservationIgnored private var world: World?
    @ObservationIgnored private var actors: [Entity] = []

    func install(in content: GameViewContent) {
        world = content.world
        content.world.fixedStep = FixedStepConfiguration(stepsPerSecond: 20)
        content.world.isPaused = isPaused
        content.world.resources.set(DemoFixedStepDriver(state: controls))
        let raw = Entity(name: "Canonical actor", components:
            SpriteComponent(color: .orange, size: [32, 32]), DemoFixedStepActor())
        raw.position = [-100, 46]
        let smooth = Entity(name: "Interpolated actor", components:
            SpriteComponent(color: .cyan, size: [32, 32]), DemoFixedStepActor(),
            TransformInterpolationComponent(isEnabled: true))
        smooth.position = [-100, -46]
        actors = [raw, smooth]
        for actor in actors { content.add(actor) }
        do {
            try content.world.systems.add(DemoFixedStepInputSystem.self)
            try content.world.systems.add(DemoFixedStepStatusSystem.self)
            status = "Hold a direction, or send a complete tap between ticks"
        } catch {
            status = "Could not schedule buffered input: \(error)"
        }
    }

    func setPaused(_ paused: Bool) {
        // The world does not own this buffer. Gate late samples and discard pending edges.
        controls.input.isEnabled = false
        controls.input.cancelAll()
        controls.buffer.reset()
        for name in ["left", "right", "burst"] {
            controls.input.setValue(.button(false), for: .virtual(name), device: .virtual("fixed-pad"))
        }
        isPaused = paused
        world?.isPaused = paused
        controls.input.isEnabled = !paused
        controls.clock = world?.fixedStepState
    }

    func tapBurst() {
        let input = controls.input
        input.setValue(.button(true), for: .virtual("burst"), device: .virtual("fixed-pad"))
        input.setValue(.button(false), for: .virtual("burst"), device: .virtual("fixed-pad"))
    }

    func resetPositions() {
        // These writes happen outside a fixed tick and automatically snap presentation.
        for actor in actors { actor.position.x = -100 }
    }
}

@MainActor
struct DemoFixedStepHoldStyle: ButtonStyle {
    let input: InputController
    let control: String

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(12)
            .background(configuration.isPressed ? Color.cyan : Color.gray.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onChange(of: configuration.isPressed) { _, pressed in
                input.setValue(.button(pressed), for: .virtual(control), device: .virtual("fixed-pad"))
            }
            .onDisappear {
                input.setValue(.button(false), for: .virtual(control), device: .virtual("fixed-pad"))
            }
    }
}

@MainActor
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var scene = DemoFixedStepScene()
    @State private var fps = 60

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("Buffered fixed input · stage 3").font(.headline)
                Picker("Preferred FPS", selection: $fps) {
                    Text("30").tag(30)
                    Text("60").tag(60)
                    Text("120").tag(120)
                }.pickerStyle(.segmented)
                GameView(rendering: GameRenderConfiguration(preferredFramesPerSecond: fps)) {
                    scene.install(in: $0)
                }
                .frame(height: 240)
                .gameInput(scene.controls.input, isActive: !scene.isPaused)
                Text("Orange: canonical · Cyan: interpolated · Both models share input")
                    .font(.caption)
                HStack {
                    Button("Hold left") {}
                        .buttonStyle(DemoFixedStepHoldStyle(input: scene.controls.input, control: "left"))
                    Button("Hold right") {}
                        .buttonStyle(DemoFixedStepHoldStyle(input: scene.controls.input, control: "right"))
                }
                .disabled(scene.isPaused)
                Button("Tap between ticks (+24 points)") { scene.tapBurst() }
                    .disabled(scene.isPaused)
                HStack {
                    Button(scene.isPaused ? "Resume" : "Pause") { scene.setPaused(!scene.isPaused) }
                    Button("Reset positions") { scene.resetPositions() }
                }
                Text(scene.isPaused ? "Paused · pending input discarded" : scene.status)
                    .font(.caption)
                Text("Burst presses \(scene.controls.presses) · Releases \(scene.controls.releases)")
                Text("Last tick events \(scene.controls.lastEventCount) · Overflows \(scene.controls.overflows)")
                    .font(.caption.monospacedDigit())
                if let clock = scene.controls.clock {
                    Text("Tick \(clock.tick) · Ticks/frame \(clock.ticksThisFrame) · Alpha \(clock.interpolationAlpha, specifier: "%.2f")")
                    Text("Simulation \(clock.simulationTime, specifier: "%.2f")s · Dropped this frame \(clock.droppedTime, specifier: "%.3f")s")
                }
                Text("Optional: focus the game, hold A/D, or tap Space. Resume after returning to the app.")
                    .font(.caption)
            }
            .padding()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { scene.setPaused(true) }
        }
        .onDisappear { scene.setPaused(true) }
    }
}
