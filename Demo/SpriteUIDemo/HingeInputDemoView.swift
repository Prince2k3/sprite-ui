import Observation
import SpriteUI
import SwiftUI

/// Native posture is telemetry; only the resolved action drives the shield.
@available(iOS 18.0, macOS 15.0, *)
@MainActor
struct HingeInputDemoView: View {
    @State private var model = HingeInputDemoModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Hinge shield").font(.title2.bold())
                Text("Charge the cyan shield to 60% before an orange spark arrives.")
                    .font(.caption)

                // One host, one world. No synthetic surface-region overrides.
                GeometryReader { proxy in
                    GameView(viewports: model.viewports) { model.install(in: $0) }
                        .onGameSurfaceChange { model.surfaceDidChange($0) }
                        .onGameHingeChange { model.hingeDidChange($0) }
                        .gameInput(model.input, hinge: HingeInputConfiguration(
                            neutralAngle: .pi, activationAngle: .pi / 2,
                            deadZone: 0.05, smoothing: 0.08))
                        .overlay { HingeInputSurfaceHUD(model: model, size: proxy.size) }
                        .clipped()
                }
                .frame(height: 340)

                // These controls live outside the game surface, so they remain
                // reachable even when no usable game region can fit a control.
                HingeInputFallback(model: model)
                HingeInputReadings(model: model)
                Text("Fully open to arm, then move toward 90° to charge. Open again after initial connection, reconnect, suspension, focus loss, input configuration changes or Reset. Geometry and viewport changes preserve hinge input. Reaching neutral alone does not charge the shield.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Slider and Space use the same action as the hinge. The strongest input wins; return the slider to zero and release Space to try the hinge alone. Native readings never set layout. System geometry chooses the usable arena region.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .background(.black).preferredColorScheme(.dark).tint(.cyan)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.releaseInput() }
        }
        .onDisappear { model.releaseInput() }
    }
}

/// Only this small overlay observes action changes, not the host configuration.
@MainActor
private struct HingeInputSurfaceHUD: View {
    let model: HingeInputDemoModel
    let size: CGSize
    @State private var measuredSize = CGSize.zero

    var body: some View {
        if let geometry = model.surface,
           abs(geometry.bounds.width - size.width) <= 1 / geometry.displayScale,
           abs(geometry.bounds.height - size.height) <= 1 / geometry.displayScale {
            let placement = measuredSize == .zero ? nil
                : geometry.placement(of: measuredSize, anchor: [0, 0])
            VStack(alignment: .leading, spacing: 3) {
                Text("SHIELD \(Int(model.charge * 100))%")
                    .fontWeight(.bold).foregroundStyle(.cyan)
                Text(model.charge >= 0.6 ? "Guard ready" : "Charge to 60% to block")
                Text("Blocked \(model.blocks) · Passed \(model.misses)")
            }
            .font(.caption2.monospacedDigit())
            .padding(8)
            .frame(width: max(1, min(206, geometry.largestUsableRegion.width)))
            .fixedSize(horizontal: false, vertical: true)
            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { measuredSize = $0 }
            .position(x: placement?.midX ?? 0, y: placement?.midY ?? 0)
            .opacity(placement == nil ? 0 : 1)
            .accessibilityHidden(placement == nil)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .allowsHitTesting(false)
        }
    }
}

@MainActor
private struct HingeInputFallback: View {
    let model: HingeInputDemoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Always available · fallback").font(.headline)
            Slider(value: Binding(get: { model.slider }, set: { model.setSlider($0) }), in: 0...1)
                .accessibilityLabel("Shield charge fallback")
                .accessibilityValue("\(Int(model.slider * 100)) percent")
                .accessibilityHint("Controls the same shield action as the native hinge")
                .accessibilityIdentifier("hinge-charge-slider")
            HStack {
                Text("Slider \(Int(model.slider * 100))% · or hold Space in arena")
                    .font(.caption.monospacedDigit())
                Spacer()
                Button("Reset") { model.reset() }
                    .buttonStyle(.bordered).frame(minHeight: 44)
                    .accessibilityLabel("Reset shield and score")
                    .accessibilityHint("Releases input. Fully open to rearm native hinge input")
                    .accessibilityIdentifier("hinge-reset")
            }
        }
    }
}

@MainActor
private struct HingeInputReadings: View {
    let model: HingeInputDemoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Native hinge · \(model.nativeStatus)").fontWeight(.bold)
            if let state = model.hinge {
                Text("Angle \(state.angle, specifier: "%.3f") rad · \(state.angle * 180 / .pi, specifier: "%.1f")°")
                Text("Native openness \(state.openness * 100, specifier: "%.1f")%")
            } else {
                Text("Angle / openness unavailable · use the slider or Space")
            }
            Text("Calibrated action \(model.charge, specifier: "%.2f") · \(model.phase)")
            Text("Calibration: 180° neutral → 90° full · dead zone 5% · smoothing 0.08s")
            Text("World installs \(model.installations) · Player installs \(model.playerInstallations) · Shield installs \(model.shieldInstallations)")
            Text("Geometry changes \(model.geometryChanges) · Native changes \(model.hingeChanges) · Action events \(model.actionChanges)")
            Text("Blocked \(model.blocks) · Passed \(model.misses)")
            Text("Arm guidance: fully open, then move. Arm state is not exposed by the input API.")
        }
        .font(.caption.monospacedDigit())
        .accessibilityIdentifier("hinge-readings")
    }
}

@MainActor @Observable
private final class HingeInputDemoModel {
    private static let shieldAction = InputAction("hinge-shield-charge", kind: .axis)
    private static let sliderControl = InputControl.virtual("hinge-shield-slider")
    private static let sliderDevice = InputDevice.virtual("hinge-shield-slider")

    let input: InputController
    private(set) var hinge: GameHingeState?
    private(set) var surface: GameSurfaceGeometry?
    private(set) var slider = 0.0
    private(set) var charge: Float = 0
    private(set) var phase = "idle"
    private(set) var blocks = 0
    private(set) var misses = 0
    private(set) var installations = 0
    private(set) var playerInstallations = 0
    private(set) var shieldInstallations = 0
    private(set) var geometryChanges = 0
    private(set) var hingeChanges = 0
    private(set) var actionChanges = 0

    @ObservationIgnored private let player = Entity(name: "Hinge pilot", components:
        SpriteComponent(color: .cyan, size: [24, 24]))
    @ObservationIgnored private let shield = Entity(name: "Action shield", components:
        SpriteComponent(color: .cyan, size: [8, 100]))
    @ObservationIgnored private let spark = Entity(name: "Incoming spark", components:
        SpriteComponent(color: .orange, size: [12, 12]))
    @ObservationIgnored private let camera = Entity(name: "Hinge camera", components:
        CameraComponent(smoothing: 0))
    @ObservationIgnored private var subscriptions: [EventSubscription] = []
    @ObservationIgnored private var actionSubscription: InputSubscription?
    @ObservationIgnored private var sparkX: Float = 175
    @ObservationIgnored private var sparkResolved = false
    @ObservationIgnored private var time: TimeInterval = 0

    var viewports: [GameViewport] {
        [GameViewport(id: "hinge-play", camera: camera.id, region: .largestUsable)]
    }

    var nativeStatus: String {
        guard let hinge else { return "unavailable" }
        switch hinge.status {
        case .unknown: return "unknown"
        case .closed: return "closed"
        case .partiallyOpen: return "partially open"
        case .fullyOpen: return "fully open"
        @unknown default: return "unknown"
        }
    }

    init() {
        input = InputController(contexts: [InputActionMap(name: "Shield", bindings: [
            InputBinding(Self.shieldAction, control: .hinge),
            InputBinding(Self.shieldAction, control: Self.sliderControl),
            InputBinding(Self.shieldAction, control: .key("space"))
        ])])
        actionSubscription = input.observe(action: Self.shieldAction) { [weak self] event in
            guard let self else { return }
            // Gameplay consumes typed action transitions from every producer.
            self.charge = max(0, min(1, event.value.scalar))
            self.phase = event.phase.rawValue
            self.actionChanges += 1
            if event.phase == .cancelled {
                self.slider = 0
                // Clear our virtual sample so the next slider adjustment works
                // after host cancellation without a hidden stale neutral gate.
                self.input.setValue(.axis(0), for: Self.sliderControl, device: Self.sliderDevice)
            }
        }
    }

    func install(in content: GameViewContent) {
        installations += 1
        content.renderer.backgroundColor = .black
        hinge = content.hingeState
        surface = content.surfaceGeometry

        let floor = Entity(components: SpriteComponent(color: .white.opacity(0.2), size: [360, 2]))
        floor.position = [0, -82]
        content.add(floor)
        let label = Entity(components: TextComponent("PILOT   /   SHIELD   ←   SPARKS",
            font: .system(size: 10), color: .white))
        label.position = [0, -110]
        content.add(label)
        player.position = [-70, -40]
        shield.position = [-40, -40]
        shield.scale = [1, 0.08]
        spark.position = [sparkX, -40]
        content.add(player)
        playerInstallations += 1
        content.add(shield)
        shieldInstallations += 1
        content.add(spark)
        content.add(camera)
        fitCamera()
        subscriptions = [content.subscribe(to: WorldEvents.Update.self) { [weak self] event in
            self?.step(deltaTime: event.deltaTime)
        }]
    }

    func hingeDidChange(_ state: GameHingeState?) {
        hinge = state
        hingeChanges += 1
    }

    func surfaceDidChange(_ geometry: GameSurfaceGeometry) {
        guard surface != geometry else { return }
        if let previous = surface,
           previous.size != geometry.size || previous.safeBounds != geometry.safeBounds
            || previous.usableRegions() != geometry.usableRegions() {
            // Release this app-owned producer independently. The shared action
            // can remain pressed by the native hinge, so no cancelled event is guaranteed.
            setSlider(0)
        }
        surface = geometry
        geometryChanges += 1
        fitCamera()
    }

    func setSlider(_ value: Double) {
        slider = min(1, max(0, value))
        input.setValue(.axis(Float(slider)), for: Self.sliderControl, device: Self.sliderDevice)
    }

    func releaseInput() {
        input.cancelAll()
        setSlider(0)
    }

    func reset() {
        releaseInput()
        blocks = 0
        misses = 0
        sparkX = 175
        sparkResolved = false
        time = 0
        spark.position = [sparkX, -40]
        spark.isEnabled = true
        player.scale = [1, 1]
        shield.scale = [1, 0.08]
        // Keep native telemetry and installation counters intact.
    }

    private func fitCamera() {
        guard let rect = surface?.largestUsableRegion, rect.width > 0, rect.height > 0 else { return }
        camera.components[CameraComponent.self]?.zoom = Float(min(rect.width / 380, rect.height / 300))
    }

    private func step(deltaTime: TimeInterval) {
        let dt = Float(min(max(deltaTime, 0), 0.05))
        time += Double(dt)
        shield.scale = [1 + charge * 0.5, 0.08 + charge * 0.92]
        let pulse = 1 + sin(Float(time) * 4) * charge * 0.04
        player.scale = [pulse, pulse]
        sparkX -= 110 * dt
        if !sparkResolved, sparkX <= -30 {
            sparkResolved = true
            if charge >= 0.6 {
                blocks += 1
                spark.isEnabled = false
            } else {
                misses += 1
            }
        }
        if sparkX < -175 {
            sparkX = 175
            sparkResolved = false
            spark.isEnabled = true
        }
        spark.position = [sparkX, -40]
        spark.rotation += dt * 3
    }
}
