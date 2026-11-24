import Observation
import SpriteUI
import SwiftUI

@MainActor
struct ContentView: View {
    @State private var model = HingePlayers()
    @State private var enabled = true
    @State private var surface = GameSurfaceGeometry(size: .zero)
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GameView { content in
                    model.install(in: content)
                }
                .onGameSurfaceChange { next in
                    if surface.size != next.size || surface.safeBounds != next.safeBounds
                        || surface.usableRegions() != next.usableRegions() {
                        model.releaseSliders()
                    }
                    surface = next
                }
                .gameInput(model.hub, isActive: enabled, hinge: HingeInputConfiguration())
                .frame(height: 260)
                ForEach(model.hub.players) { player in
                    Text("\(player.name) bend: \(player.input.value(for: HingeActions.bend).scalar, specifier: "%.2f")")
                    Slider(value: Binding(
                        get: { model.sliders[player.id, default: 0] },
                        set: { model.setSlider($0, for: player) }
                    ), in: -1...1)
                    .accessibilityLabel("\(player.name) virtual bend action")
                    .disabled(!enabled)
                }
                Button("Center virtual sliders") { model.releaseSliders() }
                if model.hub.devices.contains(where: { $0.id == .hinge }) {
                    Text("Hinge owner: \(model.hub.owner(of: .hinge)?.name ?? "Unassigned")")
                    Button("Transfer hinge to other player") { model.transferHinge() }
                } else {
                    Text("No native hinge device; virtual sliders remain available")
                }
                Toggle("Native input active", isOn: $enabled)
                Text(model.status).font(.caption)
                Text("Transfer cancels held hinge input. Return the sensor to calibrated neutral before the new owner can bend.")
                    .font(.caption)
            }
            .padding()
        }
        .preferredColorScheme(.dark)
        .onAppear { model.releaseSliders() }
        .onChange(of: enabled) { _, active in
            if !active { model.releaseSliders() }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase != .active { model.releaseSliders() }
        }
        .onDisappear { model.releaseSliders() }
    }
}

@MainActor @Observable
private final class HingePlayers {
    let hub = PlayerInputHub()
    var sliders: [UUID: Double] = [:]
    var status = "Virtual pads assigned; waiting for an optional native hinge"
    @ObservationIgnored private var devices: InputDeviceSubscription?
    private var pads: [UUID: InputDevice] = [:]
    private var sprites: [Entity] = []

    init() {
        for (index, name) in ["P1", "P2"].enumerated() {
            let player = hub.addPlayer(named: name, contexts: [HingeActions.map])
            let pad = InputDevice.virtual("hinge-slider-\(index)")
            pads[player.id] = pad
            hub.connect(InputDeviceInfo(id: pad, name: "\(name) slider"))
            assign(pad, to: player)
            let sprite = Entity(name: name, components:
                SpriteComponent(color: index == 0 ? .cyan : .orange, size: [64, 32]))
            sprite.position = [index == 0 ? -80 : 80, 0]
            sprite.components.set(HingeDriver(input: player.input))
            sprites.append(sprite)
        }
        // The backend announces the real device. This app explicitly chooses P1.
        devices = hub.observe { [weak self] event in
            guard let self else { return }
            if case .connected(let info) = event, info.id == .hinge,
               let first = self.hub.players.first {
                self.assign(.hinge, to: first)
            }
            if case .disconnected(let info) = event, info.id == .hinge {
                self.status = "Native hinge disconnected; player sessions retained"
            }
        }
    }

    func install(in content: GameViewContent) {
        for sprite in sprites { content.add(sprite) }
        do { try content.world.systems.add(HingeEffectSystem.self) }
        catch { status = "Effect setup failed: \(error)" }
    }

    func setSlider(_ value: Double, for player: PlayerInputSession) {
        guard let pad = pads[player.id] else { return }
        sliders[player.id] = value
        hub.submit([(.virtual("bend"), .axis(Float(value)))], device: pad)
    }

    func releaseSliders() {
        for player in hub.players { setSlider(0, for: player) }
    }

    func transferHinge() {
        guard hub.players.count == 2 else { return }
        let next = hub.owner(of: .hinge)?.id == hub.players[0].id ? hub.players[1] : hub.players[0]
        assign(.hinge, to: next)
    }

    private func assign(_ device: InputDevice, to player: PlayerInputSession) {
        do {
            try hub.assign(device, to: player)
            status = "Assigned \(device) to \(player.name)"
        } catch { status = "Assignment failed: \(error)" }
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
