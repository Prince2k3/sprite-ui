import Observation
import SpriteUI
import SwiftUI

@MainActor
struct ContentView: View {
    @State private var model = HingeActionScene()
    @State private var slider: Double = 0
    @State private var enabled = true
    @State private var surface = GameSurfaceGeometry(size: .zero)
    @State private var fastResponse = false
    @State private var hinge: GameHingeState?
    @Environment(\.scenePhase) private var scenePhase

    private var configuration: HingeInputConfiguration {
        HingeInputConfiguration(neutralAngle: .pi, activationAngle: .pi / 2,
                                deadZone: 0.05, smoothing: fastResponse ? 0 : 0.08)
    }

    var body: some View {
        VStack(spacing: 12) {
            GameView { content in
                model.install(in: content)
            }
            .onGameHingeChange { hinge = $0 }
            .onGameSurfaceChange { next in
                if surface.size != next.size || surface.safeBounds != next.safeBounds
                    || surface.usableRegions() != next.usableRegions() {
                    release()
                }
                surface = next
            }
            .gameInput(model.input, isActive: enabled, hinge: configuration)
            .frame(height: 260)
            Text(hinge == nil ? "Live hinge unavailable; use the slider" : "Last hinge sample retained; actions need current data")
            Text("Bend: \(model.input.value(for: HingeActions.bend).scalar, specifier: "%.2f")")
            Slider(value: $slider, in: -1...1)
                .accessibilityLabel("Virtual bend action")
                .disabled(!enabled)
                .onChange(of: slider) { _, value in
                    model.input.setValue(.axis(Float(value)), for: .virtual("bend"), device: model.pad)
                }
            Button("Center virtual slider") { release() }
            Toggle("Native input active", isOn: $enabled)
            Toggle("Disable native smoothing", isOn: $fastResponse)
            Text("Optional focused keyboard: A / D. After enabling or changing configuration, return the live hinge to neutral before bending again.")
                .font(.caption)
            Text(model.status).font(.caption)
        }
        .padding().preferredColorScheme(.dark)
        .onAppear { release() }
        .onChange(of: enabled) { _, active in
            if !active { release() }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase != .active { release() }
        }
        .onDisappear { release() }
    }

    private func release() {
        slider = 0
        model.input.setValue(.axis(0), for: .virtual("bend"), device: model.pad)
    }
}

@MainActor @Observable
private final class HingeActionScene {
    let input = InputController(contexts: [HingeActions.map])
    let pad = InputDevice.virtual("hinge-tutorial-slider")
    let sprite = Entity(components: SpriteComponent(color: .cyan, size: [64, 32]))
    var status = "One axis drives the sprite's rotation"

    func install(in content: GameViewContent) {
        sprite.components.set(HingeDriver(input: input))
        content.add(sprite)
        do { try content.world.systems.add(HingeEffectSystem.self) }
        catch { status = "Effect setup failed: \(error)" }
    }
}

private enum HingeActions {
    static let bend = InputAction("bend", kind: .axis)
    static let map = InputActionMap(name: "Play", bindings: [
        InputBinding(bend, control: .hinge),
        InputBinding(bend, control: .virtual("bend")),
        InputBinding(bend, control: .key("a"), scale: [-1, 0]),
        InputBinding(bend, control: .key("d"), scale: [1, 0])
    ])
}

private struct HingeDriver: Component {
    let input: InputController
    @MainActor func cloned() -> Self? { nil }
}

@MainActor
private struct HingeEffectSystem: System {
    private let query = EntityQuery(where: .has(HingeDriver.self))
    init(world: World) {}

    func update(context: UpdateContext) {
        for entity in context.entities(matching: query) {
            guard let driver = entity.components[HingeDriver.self] else { continue }
            let value = driver.input.value(for: HingeActions.bend).scalar
            entity.rotation = value * .pi / 4
        }
    }
}
