import SpriteUI
import SwiftUI
import Observation

@MainActor @Observable
final class SharedPlayers {
    static let fire = InputAction("fire")
    let hub = PlayerInputHub()
    let padA = InputDevice.virtual("pad-a")
    let padB = InputDevice.virtual("pad-b")
    var counts: [UUID: Int] = [:]
    var status = "Pads assigned; hardware is optional"
    var feedback: [UUID: String] = [:]
    @ObservationIgnored private var subscriptions: [InputSubscription] = []

    init() {
        let map = InputActionMap(name: "Play", bindings: [
            InputBinding(Self.fire, control: .key("space")),
            InputBinding(Self.fire, control: .pointerButton(0)),
            InputBinding(Self.fire, control: .gamepadButton(.south)),
            InputBinding(Self.fire, control: .virtual("fire"))
        ])
        let first = hub.addPlayer(named: "P1", contexts: [map])
        let second = hub.addPlayer(named: "P2", contexts: [map])
        for (device, name, player) in [(padA, "Pad A", first), (padB, "Pad B", second)] {
            hub.connect(InputDeviceInfo(id: device, name: name, presentations: [
                .virtual("fire"): InputControlPresentation(label: "Fire on \(name)", symbolName: "hand.tap")
            ]))
            assign(device, to: player)
        }
        for player in hub.players {
            let id = player.id
            subscriptions.append(player.input.observe(action: Self.fire) { [weak self] event in
                if event.phase == .pressed { self?.counts[id, default: 0] += 1 }
            })
        }
    }

    func assign(_ device: InputDevice, to player: PlayerInputSession) {
        do { try hub.assign(device, to: player) }
        catch { status = "Assignment failed: \(error)" }
    }

    func fireOnce(_ device: InputDevice) {
        hub.submit([(.virtual("fire"), .button(true))], device: device)
        hub.submit([(.virtual("fire"), .button(false))], device: device)
    }

    func transferPadA() {
        let players = hub.players
        let next = hub.owner(of: padA)?.id == players[0].id ? players[1] : players[0]
        do { try hub.assign(padA, to: next) }
        catch { status = "Transfer failed: \(error)" }
    }

    func requestFeedback(_ player: PlayerInputSession) {
        feedback[player.id] = player.playFeedback(.selection).rawValue
    }
}

@MainActor
struct ContentView: View {
    @State private var model = SharedPlayers()
    @State private var held = false
    @State private var enabled = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.hub.players) { player in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(player.name): \(model.counts[player.id, default: 0]) presses")
                        Text("Owned: \(player.devices.map(\.name).joined(separator: ", "))")
                        Text("Fire: \(player.input.state(for: SharedPlayers.fire).phase.rawValue)")

                        Text("Last meaningful: \(player.activeDevice?.name ?? "None yet")")
                        if let prompt = player.prompt(for: SharedPlayers.fire) {
                            if let symbol = prompt.symbolName {
                                Label("Fire: \(prompt.label)", systemImage: symbol)
                            } else { Text("Fire: \(prompt.label)") }
                        } else { Text("Fire: assign a device") }
                        Button("Try feedback for \(player.name)") { model.requestFeedback(player) }
                        Text("Feedback: \(model.feedback[player.id] ?? "not requested")")
                    }
                }
                ForEach([model.padA, model.padB], id: \.self) { device in
                    Button("Fire \(device == model.padA ? "Pad A" : "Pad B")") {
                        model.fireOnce(device)
                    }
                        .disabled(device == model.padA && held)
                }

                Toggle("Hold Fire on Pad A", isOn: $held)
                Button("Transfer Pad A") { model.transferPadA() }
                Text("After transfer, release Hold Fire, then press again.")
                    .font(.caption)

                Text("Focus this surface for assigned Space / primary click / south button")
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .background(.quaternary)
                    .gameInput(model.hub, isActive: enabled)
                ForEach(model.hub.devices, id: \.id) { device in
                    VStack(alignment: .leading) {
                        Text("\(device.name) → \(model.hub.owner(of: device.id)?.name ?? "Unassigned")")
                        Text("Haptics: \(device.supportsHaptics ? "available" : "unsupported")")
                        HStack {
                            ForEach(model.hub.players) { player in
                                Button("Assign \(player.name)") { model.assign(device.id, to: player) }
                            }
                            Button("Unassign") { model.hub.unassign(device.id) }
                        }
                    }
                }
                Toggle("Input enabled", isOn: $enabled)
                Text(model.status).font(.caption)
            }
            .padding()
            .buttonStyle(.bordered)
        }
        .onChange(of: held) { _, value in
            model.hub.submit([(.virtual("fire"), .button(value))], device: model.padA)
        }
        .onChange(of: enabled) { _, value in model.hub.isEnabled = value }
        .onDisappear {
            model.hub.cancelAll()
            model.hub.submit([(.virtual("fire"), .button(false))], device: model.padA)
            held = false
        }
    }
}
