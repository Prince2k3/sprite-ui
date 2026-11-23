import SpriteUI
import SwiftUI
import Observation

/// Two independent action sessions, with application-owned device assignment.
@MainActor
struct PlayerInputDemoView: View {
    @State private var model = PlayerInputDemoModel()
    @State private var enabled = true

    var body: some View {
        VStack(spacing: 8) {
            GameView { model.install(in: $0) }
                .frame(height: 190)
                .gameInput(model.hub, isActive: enabled)
                .accessibilityLabel("Two-player arena. Focus here for assigned hardware input")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Player input sessions").font(.headline)
                        Spacer()
                        Toggle("Input", isOn: $enabled).toggleStyle(.button)
                    }
                    Text("Cyan is P1; orange is P2. Pads start assigned. Hardware joins unassigned: choose its owner below.")
                    ForEach(model.hub.players) { player in
                        PlayerInputDemoCard(player: player, model: model)
                    }
                    Text("Virtual producers").font(.headline)
                    Text("Tap a direction to hold it; Release pad sends neutral. Transfer a held pad below: release it before moving its new owner.")
                    PlayerInputDemoPad(name: "Pad A", device: model.padA, hub: model.hub)
                    PlayerInputDemoPad(name: "Pad B", device: model.padB, hub: model.hub)
                    Text("Device ownership").font(.headline)
                    ForEach(model.hub.devices, id: \.id) { device in
                        deviceRow(device)
                    }
                    Text(model.status).accessibilityIdentifier("player-input-status")
                    Text("Optional: assign Keyboard, then focus the arena and use WASD / Space. Assign a connected controller to use its stick, d-pad and south button. Keyboard and Pointer are logical sources, not proof of attached hardware.")
                    Text("Feedback targets the last meaningful device. Virtual pads are unsupported; no controller is required to see that result. Accepted means scheduled, not proof of vibration.")
                }
                .padding(12)
            }
        }
        .font(.caption)
        .buttonStyle(.bordered)
        .onChange(of: enabled) { _, value in model.hub.isEnabled = value }
        .onDisappear { model.hub.cancelAll() }
    }

    private func deviceRow(_ device: InputDeviceInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(device.name) → \(model.hub.owner(of: device.id)?.name ?? "Unassigned")")
                .bold()
            Text("Haptics: \(device.supportsHaptics ? "available" : "unsupported") · Remapped: \(device.hasRemappedElements ? "yes" : "no")")
                .foregroundStyle(.secondary)
            HStack {
                ForEach(model.hub.players) { player in
                    Button("Assign \(player.name)") { model.assign(device.id, to: player) }
                        .disabled(model.hub.owner(of: device.id)?.id == player.id)
                        .accessibilityLabel("Assign \(device.name) to \(player.name)")
                }
                Button("Unassign") { model.hub.unassign(device.id) }
                    .disabled(model.hub.owner(of: device.id) == nil)
                    .accessibilityLabel("Unassign \(device.name)")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor
private struct PlayerInputDemoCard: View {
    let player: PlayerInputSession
    let model: PlayerInputDemoModel

    var body: some View {
        let movement = player.input.value(for: PlayerInputDemoModel.move).vector
        VStack(alignment: .leading, spacing: 6) {
            Text("\(player.name) · Fire presses: \(model.fireCounts[player.id, default: 0])")
                .font(.headline)
            Text("Owned: \(player.devices.map(\.name).joined(separator: ", "))")
            Text("Last meaningful device: \(player.activeDevice?.name ?? "None yet")")
                .accessibilityIdentifier("\(player.name)-active-device")
            Text("Move x \(movement.x, specifier: "%.2f"), y \(movement.y, specifier: "%.2f") · Fire \(player.input.state(for: PlayerInputDemoModel.fire).phase.rawValue)")
                .monospacedDigit()
            if let prompt = player.prompt(for: PlayerInputDemoModel.fire) {
                if let symbol = prompt.symbolName {
                    Label("Fire: \(prompt.label)", systemImage: symbol)
                } else {
                    Text("Fire: \(prompt.label)")
                }
            } else {
                Text("Fire: assign a device with a binding")
            }
            HStack {
                Button("Try feedback") { model.feedback(for: player) }
                    .accessibilityLabel("Try feedback for \(player.name)")
                Button("Stop feedback") { player.stopFeedback() }
            }
            Text("Feedback: \(model.feedbackResults[player.id] ?? "not requested")")
                .accessibilityIdentifier("\(player.name)-feedback")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

@MainActor
private struct PlayerInputDemoPad: View {
    let name: String
    let device: InputDevice
    let hub: PlayerInputHub
    @State private var direction = SIMD2<Float>.zero
    @State private var fireHeld = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(name) → \(hub.owner(of: device)?.name ?? "Unassigned")").bold()
            ViewThatFits {
                HStack { directions }
                VStack { directions }
            }
            HStack {
                Toggle("Hold Fire", isOn: $fireHeld).toggleStyle(.button)
                Button("Fire once") {
                    hub.submit([(.virtual("fire"), .button(true))], device: device)
                    hub.submit([(.virtual("fire"), .button(false))], device: device)
                }
                .disabled(fireHeld)
                .accessibilityLabel("Fire once on \(name)")
                Button("Release pad") { direction = .zero; fireHeld = false }
                    .accessibilityLabel("Release \(name)")
            }
            Text("Held x \(direction.x, specifier: "%.0f"), y \(direction.y, specifier: "%.0f") · Fire \(fireHeld ? "held" : "released")")
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        // Input submission belongs to reactions, never view evaluation.
        .onChange(of: direction) { _, value in
            hub.submit([(.virtual("stick"), .axis2D(value))], device: device)
        }
        .onChange(of: fireHeld) { _, value in
            hub.submit([(.virtual("fire"), .button(value))], device: device)
        }
        .onDisappear {
            hub.submit([(.virtual("stick"), .axis2D(.zero)),
                        (.virtual("fire"), .button(false))], device: device)
            direction = .zero
            fireHeld = false
        }
    }

    @ViewBuilder private var directions: some View {
        Button("Left") { direction = [-1, 0] }.accessibilityLabel("Hold left on \(name)")
        Button("Right") { direction = [1, 0] }.accessibilityLabel("Hold right on \(name)")
        Button("Up") { direction = [0, 1] }.accessibilityLabel("Hold up on \(name)")
        Button("Down") { direction = [0, -1] }.accessibilityLabel("Hold down on \(name)")
    }
}

private struct PlayerInputDemoDriver: Component {
    let input: InputController
    @MainActor func cloned() -> Self? { nil }
}

@MainActor
private struct PlayerInputDemoMovement: System {
    private let query = EntityQuery(where: .has(PlayerInputDemoDriver.self))
    init(world: World) {}

    func update(context: UpdateContext) {
        for entity in context.entities(matching: query) {
            guard let driver = entity.components[PlayerInputDemoDriver.self] else { continue }
            entity.position += driver.input.value(for: PlayerInputDemoModel.move).vector
                * 65 * Float(context.deltaTime)
            entity.position.x = min(max(entity.position.x, -130), 130)
            entity.position.y = min(max(entity.position.y, -65), 65)
        }
    }
}

@MainActor @Observable
private final class PlayerInputDemoModel {
    static let move = InputAction("move", kind: .axis2D)
    static let fire = InputAction("fire")
    let hub = PlayerInputHub()
    let padA = InputDevice.virtual("showcase-pad-a")
    let padB = InputDevice.virtual("showcase-pad-b")
    var fireCounts: [UUID: Int] = [:]
    var feedbackResults: [UUID: String] = [:]
    var status = "Virtual pads ready"
    @ObservationIgnored private var subscriptions: [InputSubscription] = []

    init() {
        let map = InputActionMap(name: "Play", bindings: [
            InputBinding(Self.move, control: .virtual("stick")),
            InputBinding(Self.fire, control: .virtual("fire")),
            InputBinding(Self.move, control: .key("a"), scale: [-1, 0]),
            InputBinding(Self.move, control: .key("d"), scale: [1, 0]),
            InputBinding(Self.move, control: .key("w"), scale: [0, 1]),
            InputBinding(Self.move, control: .key("s"), scale: [0, -1]),
            InputBinding(Self.fire, control: .key("space")),
            InputBinding(Self.fire, control: .pointerButton(0)),
            InputBinding(Self.move, control: .gamepadAxis(.leftStick), deadZone: 0.2),
            InputBinding(Self.move, control: .gamepadAxis(.dpad)),
            InputBinding(Self.fire, control: .gamepadButton(.south))
        ])
        let first = hub.addPlayer(named: "P1", contexts: [map])
        let second = hub.addPlayer(named: "P2", contexts: [map])
        for (device, name, player) in [(padA, "Pad A", first), (padB, "Pad B", second)] {
            hub.connect(InputDeviceInfo(id: device, name: name, presentations: [
                .virtual("stick"): InputControlPresentation(label: "Directions", symbolName: "dpad"),
                .virtual("fire"): InputControlPresentation(label: "Fire on \(name)", symbolName: "hand.tap")
            ]))
            assign(device, to: player)
        }
        for player in hub.players {
            let id = player.id
            subscriptions.append(player.input.observe(action: Self.fire) { [weak self] event in
                if event.phase == .pressed { self?.fireCounts[id, default: 0] += 1 }
            })
        }
    }

    func install(in content: GameViewContent) {
        for (index, player) in hub.players.enumerated() {
            let entity = Entity(name: player.name, components:
                SpriteComponent(color: index == 0 ? .cyan : .orange, size: [28, 28]),
                PlayerInputDemoDriver(input: player.input))
            entity.position = [index == 0 ? -65 : 65, 0]
            let label = Entity(components: TextComponent(player.name, font: .system(size: 12), color: .white))
            label.position = [0, 25]
            entity.addChild(label)
            content.add(entity)
        }
        do { try content.world.systems.add(PlayerInputDemoMovement.self) }
        catch { status = "Movement setup failed: \(error)" }
    }

    func assign(_ device: InputDevice, to player: PlayerInputSession) {
        do {
            try hub.assign(device, to: player)
            status = "Assigned to \(player.name). Release held controls before pressing again."
        } catch { status = "Assignment failed: \(error)" }
    }

    func feedback(for player: PlayerInputSession) {
        feedbackResults[player.id] = player.playFeedback(.selection).rawValue
    }
}
