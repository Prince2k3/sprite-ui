import Observation
import SpriteUI
import SwiftUI
import simd

@MainActor
struct FixedStepDemoView: View {
    @State private var model = FixedDemoModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            FixedDemoArena(model: model).frame(height: 320)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Same ticks, different presentation").font(.title2.bold())
                    Text("Orange steps on the upper track. Cyan interpolates on the lower track, one tick behind. Both have identical model motion.")
                        .font(.caption).foregroundStyle(.secondary)
                    FixedDemoControls(model: model)
                    FixedDemoStatistics(model: model)
                    FixedDemoComparison(model: model)
                }
                .padding(12)
            }
        }
        .background(.black).preferredColorScheme(.dark).tint(.cyan)
        .onAppear { model.setVisible(true, sceneActive: scenePhase == .active) }
        .onChange(of: scenePhase) { _, phase in model.setSceneActive(phase == .active) }
        .onChange(of: model.isPaused) { _, _ in model.applyPause() }
        .onChange(of: model.fixedRate) { _, _ in model.applyFixedRate() }
        .onDisappear { model.setVisible(false, sceneActive: scenePhase == .active) }
    }
}

/// Only render preferences and input availability participate in host configuration.
@MainActor
private struct FixedDemoArena: View {
    let model: FixedDemoModel

    var body: some View {
        GeometryReader { proxy in
            GameView(viewports: [.init(id: "main", region: .largestUsable)],
                     rendering: GameRenderConfiguration(preferredFramesPerSecond: model.renderRate)) {
                model.install(in: $0)
            }
            .gameInput(model.runtime.input, isActive: !model.isPaused)
            .onGameSurfaceChange { model.surfaceDidChange($0) }
            .overlay { FixedDemoHUD(model: model, hostSize: proxy.size) }
            .clipped()
            .accessibilityLabel("Orange stepped actor above cyan interpolated actor")
            .accessibilityIdentifier("fixed-step-arena")
        }
    }
}

@MainActor
private struct FixedDemoHUD: View {
    let model: FixedDemoModel
    let hostSize: CGSize
    @State private var hudSize = CGSize.zero

    var body: some View {
        if let surface = model.surface,
           abs(surface.bounds.width - hostSize.width) <= 1 / surface.displayScale,
           abs(surface.bounds.height - hostSize.height) <= 1 / surface.displayScale {
            let region = surface.largestUsableRegion.insetBy(dx: 8, dy: 8)
            if region.width > 0, region.height > 0 {
                FixedDemoClockReadout(model: model)
                    .padding(6)
                    .frame(width: region.width, alignment: .leading)
                    .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { hudSize = $0 }
                    .position(x: region.midX, y: region.minY + hudSize.height / 2)
                    .opacity(hudSize.height > 0 && hudSize.height <= region.height ? 1 : 0)
                    .accessibilityHidden(hudSize.height <= 0 || hudSize.height > region.height)
                    .accessibilityIdentifier("fixed-step-hud")
            }
        }
    }
}

/// Kept separate from the GameView body so per-frame telemetry cannot recreate its configuration.
@MainActor
private struct FixedDemoClockReadout: View {
    let model: FixedDemoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Tick \(model.tick) · Last frame \(model.ticksThisFrame) ticks")
            Text("α \(model.alpha, specifier: "%.3f") · Dropped \(model.droppedTime, specifier: "%.4f")s")
            Text("Render frames \(model.renderFrames) · Installs \(model.installations)")
            Text("World \(model.worldIdentity)").lineLimit(1).minimumScaleFactor(0.6)
        }
        .font(.caption2.monospacedDigit())
        .allowsHitTesting(false)
    }
}

@MainActor
private struct FixedDemoControls: View {
    @Bindable var model: FixedDemoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fixed simulation rate").font(.headline)
            Picker("Fixed simulation rate", selection: $model.fixedRate) {
                ForEach([15, 30, 60], id: \.self) { Text("\($0) Hz").tag($0) }
            }.pickerStyle(.segmented)
                .accessibilityIdentifier("fixed-step-rate")
            Text("Target render rate").font(.headline)
            Picker("Target render rate", selection: $model.renderRate) {
                ForEach([30, 60, 120], id: \.self) { Text("\($0) FPS").tag($0) }
            }.pickerStyle(.segmented)
                .accessibilityIdentifier("fixed-step-render-rate")
            Text("Render FPS is a preference. Changing either rate keeps this world and its actors.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Pause simulation (rendering continues)", isOn: $model.isPaused)
                .accessibilityIdentifier("fixed-step-pause")
            Button("Reset positions") { model.resetPositions() }
                .accessibilityIdentifier("fixed-step-reset")
            Text("Reset teleports outside a fixed tick; interpolation history resets automatically. Tick counters continue.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Movement speed", selection: Binding(
                get: { model.speedSelection }, set: { model.setSpeed($0) })) {
                Text("Slow").tag(-1)
                Text("Normal").tag(0)
                Text("Fast").tag(1)
            }.pickerStyle(.segmented).disabled(model.isPaused)
            ViewThatFits(in: .horizontal) {
                HStack { fireButtons }
                VStack(alignment: .leading) { fireButtons }
            }
            .disabled(model.isPaused)
            Text("Focus the arena: A/D adjusts speed; hold Space to fire. A press counts once, even across catch-up ticks. Fire once also preserves a quick press/release between ticks.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder private var fireButtons: some View {
        Button("Fire once") { model.fireOnce() }.disabled(model.virtualFireHeld)
        Button(model.virtualFireHeld ? "Release fire" : "Hold fire") { model.toggleFire() }
        Button("Release all") { model.releaseInput() }
    }
}

@MainActor
private struct FixedDemoStatistics: View {
    let model: FixedDemoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FixedDemoClockReadout(model: model)
            Text("Simulation \(model.simulationTime, specifier: "%.3f")s · Fixed Δt \(model.runtime.lastDelta, specifier: "%.5f")s")
            Text("Context tick \(model.runtime.lastTick) · Context α \(model.runtime.lastAlpha, specifier: "%.3f")")
            Text("Fire presses \(model.runtime.fireCount) · Releases \(model.runtime.releaseCount) · Held \(model.runtime.fireHeld ? "yes" : "no")")
            Text("Buffered events \(model.runtime.eventCount) · Overflow samples \(model.runtime.overflowCount)")
            Text("Orange x \(model.steppedX, specifier: "%.2f") · Cyan model x \(model.interpolatedX, specifier: "%.2f")")
            Text("Dropped total \(model.totalDroppedTime, specifier: "%.4f")s · Constant Δt \(model.runtime.validContext ? "yes" : "FAILED")")
            if !model.status.isEmpty { Text(model.status).foregroundStyle(.orange) }
        }
        .font(.caption.monospacedDigit())
        .accessibilityIdentifier("fixed-step-statistics")
    }
}

@MainActor
private struct FixedDemoComparison: View {
    let model: FixedDemoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Compare two seconds at 30 / 60 / 120 FPS") { model.compareHeadless() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("fixed-step-compare")
            Text(model.comparisonResult).font(.caption.monospacedDigit())
                .accessibilityIdentifier("fixed-step-comparison-result")
            Text("Uses separate headless worlds with the same fixed system, held fire, and two seconds of elapsed time. Also checks a three-tick catch-up and a fresh press after release.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct FixedDemoMover: Component {
    var direction: Float = 1
    var halfWidth: Float = 120
    var speed: Float = 120
}

private struct FixedDemoRuntimeReference: Component {
    let runtime: FixedDemoRuntime
    @MainActor func cloned() -> Self? { nil }
}

@MainActor @Observable
private final class FixedDemoRuntime {
    static let speedAction = InputAction("fixed-demo-speed", kind: .axis)
    static let fireAction = InputAction("fixed-demo-fire")
    let input: InputController
    let buffer: FixedInputBuffer
    var fireCount = 0
    var releaseCount = 0
    var eventCount = 0
    var overflowCount = 0
    var fireHeld = false
    var lastDelta: TimeInterval = 0
    var lastTick: UInt64 = 0
    var lastAlpha = 0.0
    var validContext = true

    init() {
        input = InputController(contexts: [InputActionMap(name: "Fixed step", bindings: [
            InputBinding(Self.speedAction, control: .virtual("speed")),
            InputBinding(Self.speedAction, control: .key("a"), scale: [-1, 0]),
            InputBinding(Self.speedAction, control: .key("d"), scale: [1, 0]),
            InputBinding(Self.fireAction, control: .virtual("fire")),
            InputBinding(Self.fireAction, control: .key("space")),
            InputBinding(Self.fireAction, control: .gamepadButton(.south))
        ])])
        buffer = FixedInputBuffer(input: input, capacity: 256)
    }
}

/// Both actors are kinematic sprites. Only the cyan actor opts into presentation interpolation.
@MainActor
private struct FixedDemoSystem: System {
    static var phase: SystemPhase { .fixedSimulation }
    private let movers = EntityQuery(where: .has(FixedDemoMover.self))
    init(world: World) {}

    func update(context: UpdateContext) {
        guard let runtime = context.world.resources[FixedDemoRuntimeReference.self]?.runtime else { return }
        let sample = runtime.buffer.consume() // Once per tick, never once per actor.
        if sample.wasPressed(FixedDemoRuntime.fireAction) { runtime.fireCount += 1 }
        if sample.wasReleased(FixedDemoRuntime.fireAction) { runtime.releaseCount += 1 }
        runtime.fireHeld = sample.value(for: FixedDemoRuntime.fireAction).isPressed
        runtime.eventCount += sample.events.count
        if sample.didOverflow { runtime.overflowCount += 1 }
        runtime.lastDelta = context.deltaTime
        runtime.lastTick = context.fixedTick ?? 0
        runtime.lastAlpha = context.interpolationAlpha
        let expected = context.world.fixedStep.map { 1 / $0.stepsPerSecond } ?? 0
        runtime.validContext = runtime.validContext && context.fixedTick != nil
            && context.deltaTime.isFinite && abs(context.deltaTime - expected) < 1e-9
        let speedScale = 1 + Double(sample.value(for: FixedDemoRuntime.speedAction).scalar) * 0.65
        for entity in context.entities(matching: movers) {
            guard var mover = entity.components[FixedDemoMover.self] else { continue }
            let width = Double(mover.halfWidth * 2)
            guard width > 0 else { continue }
            let offset = Double(entity.position.x + mover.halfWidth)
            let unfolded = mover.direction > 0 ? offset : 2 * width - offset
            let distance = unfolded + Double(mover.speed) * speedScale * context.deltaTime
            let folded = distance.truncatingRemainder(dividingBy: 2 * width)
            // A triangular wave reflects any overshoot, including multiple bounces, into the track.
            entity.position.x = Float(folded <= width ? folded : 2 * width - folded) - mover.halfWidth
            mover.direction = folded < width ? 1 : -1
            entity.components.set(mover)
        }
    }
}

@MainActor @Observable
private final class FixedDemoModel {
    let runtime = FixedDemoRuntime()
    var fixedRate = 15
    var renderRate = 60
    var isPaused = false
    private(set) var speedSelection = 0
    private(set) var virtualFireHeld = false
    private(set) var surface: GameSurfaceGeometry?
    private(set) var tick: UInt64 = 0
    private(set) var ticksThisFrame = 0
    private(set) var alpha = 0.0
    private(set) var droppedTime: TimeInterval = 0
    private(set) var totalDroppedTime: TimeInterval = 0
    private(set) var simulationTime: TimeInterval = 0
    private(set) var renderFrames = 0
    private(set) var installations = 0
    private(set) var worldIdentity = "pending"
    private(set) var steppedX: Float = 0
    private(set) var interpolatedX: Float = 0
    private(set) var status = ""
    private(set) var comparisonResult = "Ready to compare. The live world continues unchanged."
    @ObservationIgnored private var world: World?
    @ObservationIgnored private var actors: [Entity] = []
    @ObservationIgnored private var tracks: [Entity] = []
    @ObservationIgnored private var subscriptions: [EventSubscription] = []
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var sceneActive = true

    private static let speedDevice = InputDevice.virtual("fixed-demo-speed")
    private static let fireDevice = InputDevice.virtual("fixed-demo-fire")

    func install(in content: GameViewContent) {
        guard world !== content.world else { return }
        world = content.world
        installations += 1
        worldIdentity = String(describing: ObjectIdentifier(content.world))
        content.renderer.backgroundColor = .black
        content.world.fixedStep = FixedStepConfiguration(stepsPerSecond: Double(fixedRate),
                                                        maximumCatchUpSteps: 8, maximumFrameDeltaTime: 0.25)
        content.world.resources.set(FixedDemoRuntimeReference(runtime: runtime))
        actors = Self.makeActors(in: content.world)
        tracks = [Color.orange, .cyan].map { color in
            let track = Entity(components: SpriteComponent(color: color.opacity(0.3), size: [260, 2]))
            track.zPosition = -1
            content.add(track)
            return track
        }
        do { try content.world.systems.add(FixedDemoSystem.self) }
        catch { status = "Fixed system setup failed: \(error)" }
        subscriptions = [content.subscribe(to: RenderingEvents.DidUpdate.self) { [weak self] event in
            self?.recordFrame(from: event.scene)
        }]
        surfaceDidChange(content.surfaceGeometry)
        applyPause()
    }

    private static func makeActors(in world: World) -> [Entity] {
        [Color.orange, .cyan].enumerated().map { index, color in
            let actor = Entity(name: index == 0 ? "Stepped" : "Interpolated", components:
                SpriteComponent(color: color, size: [22, 22]), FixedDemoMover())
            if index == 1 { actor.components.set(TransformInterpolationComponent()) }
            actor.position = [-90, index == 0 ? 0 : -80]
            world.addEntity(actor)
            return actor
        }
    }

    func surfaceDidChange(_ geometry: GameSurfaceGeometry) {
        surface = geometry
        let size = geometry.largestUsableRegion.size
        guard size.width > 0, size.height > 0 else { return }
        let halfWidth = max(0, Float(size.width / 2) - 22)
        let header = min(128, size.height * 0.45)
        let space = max(0, size.height - header)
        for (index, actor) in actors.enumerated() {
            actor.components[FixedDemoMover.self]?.halfWidth = halfWidth
            actor.position.x = min(halfWidth, max(-halfWidth, actor.position.x))
            actor.position.y = Float(size.height / 2 - header - space * (index == 0 ? 0.25 : 0.75))
            tracks[index].position = [0, actor.position.y]
            tracks[index].components[SpriteComponent.self]?.size = [halfWidth * 2 + 22, 2]
        }
    }

    func applyFixedRate() {
        world?.fixedStep = FixedStepConfiguration(stepsPerSecond: Double(fixedRate),
                                                  maximumCatchUpSteps: 8, maximumFrameDeltaTime: 0.25)
    }

    func applyPause() {
        releaseInput()
        world?.isPaused = isPaused
        refreshInputAvailability()
    }

    func setVisible(_ visible: Bool, sceneActive: Bool) {
        isVisible = visible
        self.sceneActive = sceneActive
        releaseInput()
        refreshInputAvailability()
    }

    func setSceneActive(_ active: Bool) {
        sceneActive = active
        releaseInput()
        refreshInputAvailability()
    }

    private func refreshInputAvailability() {
        runtime.input.isEnabled = isVisible && sceneActive && !isPaused
    }

    func releaseInput() {
        runtime.input.setValue(.axis(0), for: .virtual("speed"), device: Self.speedDevice)
        runtime.input.setValue(.button(false), for: .virtual("fire"), device: Self.fireDevice)
        runtime.input.cancelAll()
        runtime.buffer.reset() // The buffer has no binding to World.isPaused.
        runtime.fireHeld = false
        virtualFireHeld = false
        speedSelection = 0
    }

    func setSpeed(_ speed: Int) {
        guard runtime.input.isEnabled else { return }
        speedSelection = speed
        runtime.input.setValue(.axis(Float(speed)), for: .virtual("speed"), device: Self.speedDevice)
    }

    func fireOnce() {
        guard runtime.input.isEnabled, !virtualFireHeld else { return }
        runtime.input.setValue(.button(true), for: .virtual("fire"), device: Self.fireDevice)
        runtime.input.setValue(.button(false), for: .virtual("fire"), device: Self.fireDevice)
    }

    func toggleFire() {
        guard runtime.input.isEnabled else { return }
        virtualFireHeld.toggle()
        runtime.input.setValue(.button(virtualFireHeld), for: .virtual("fire"), device: Self.fireDevice)
    }

    func resetPositions() {
        releaseInput()
        for actor in actors {
            let halfWidth = actor.components[FixedDemoMover.self]?.halfWidth ?? 120
            actor.position.x = -halfWidth * 0.75
            actor.components[FixedDemoMover.self]?.direction = 1
        }
    }

    private func recordFrame(from world: World) {
        let state = world.fixedStepState
        renderFrames += 1
        tick = state.tick
        ticksThisFrame = state.ticksThisFrame
        alpha = state.interpolationAlpha
        droppedTime = state.droppedTime
        totalDroppedTime += state.droppedTime
        simulationTime = state.simulationTime
        steppedX = actors.first?.position.x ?? 0
        interpolatedX = actors.last?.position.x ?? 0
    }

    func compareHeadless() {
        var lines: [String] = []
        var baseline: Float?
        var passed = true
        do {
            for fps in [30, 60, 120] {
                let (world, runtime, actors) = try makeComparisonWorld()
                runtime.input.setValue(.button(true), for: .virtual("fire"), device: Self.fireDevice)
                // Every schedule represents the same two-second wall-clock interval.
                for _ in 0..<(fps * 2) { world.update(deltaTime: 1 / Double(fps)) }
                let state = world.fixedStepState
                let x = actors[0].position.x
                let matches = x.isFinite && actors[1].position.x.isFinite
                    && abs(x - actors[1].position.x) < 0.001
                    && abs(x - (baseline ?? x)) < 0.001
                    && abs(x - 90) < 0.001 // -90 + 240 points, reflected at +120.
                    && state.tick == UInt64(fixedRate * 2) && runtime.lastTick == state.tick
                    && state.simulationTime.isFinite && abs(state.simulationTime - 2) < 1e-8
                    && state.interpolationAlpha.isFinite && state.interpolationAlpha >= 0
                    && state.interpolationAlpha < 1 && state.droppedTime == 0
                    && runtime.fireCount == 1 && runtime.validContext
                passed = passed && matches
                baseline = baseline ?? x
                lines.append("\(fps) FPS: \(state.tick) ticks, x \(x), fire \(runtime.fireCount), \(matches ? "PASS" : "FAIL")")
            }
            let (world, runtime, _) = try makeComparisonWorld()
            runtime.input.setValue(.button(true), for: .virtual("fire"), device: Self.fireDevice)
            let step = 1 / Double(fixedRate)
            world.update(deltaTime: step * 3)
            let caughtUp = world.fixedStepState.ticksThisFrame == 3 && runtime.fireCount == 1 && runtime.fireHeld
            runtime.input.setValue(.button(false), for: .virtual("fire"), device: Self.fireDevice)
            world.update(deltaTime: step)
            runtime.input.setValue(.button(true), for: .virtual("fire"), device: Self.fireDevice)
            runtime.input.setValue(.button(false), for: .virtual("fire"), device: Self.fireDevice)
            world.update(deltaTime: step)
            let edgesOnce = caughtUp && runtime.fireCount == 2 && runtime.releaseCount == 2 && !runtime.fireHeld
            passed = passed && edgesOnce
            lines.append("Three catch-up ticks + quick tap: \(edgesOnce ? "PASS" : "FAIL")")
            comparisonResult = ([passed ? "PASS · \(fixedRate) Hz, all schedules agree" : "FAIL · inspect the schedules below"] + lines)
                .joined(separator: "\n")
        } catch { comparisonResult = "Comparison failed: \(error)" }
    }

    private func makeComparisonWorld() throws -> (World, FixedDemoRuntime, [Entity]) {
        let world = World()
        let runtime = FixedDemoRuntime()
        world.fixedStep = FixedStepConfiguration(stepsPerSecond: Double(fixedRate),
                                                 maximumCatchUpSteps: 8, maximumFrameDeltaTime: 0.25)
        world.resources.set(FixedDemoRuntimeReference(runtime: runtime))
        let actors = Self.makeActors(in: world)
        try world.systems.add(FixedDemoSystem.self)
        return (world, runtime, actors)
    }
}
