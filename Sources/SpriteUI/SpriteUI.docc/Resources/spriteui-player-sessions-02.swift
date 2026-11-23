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
    @ObservationIgnored private var subscriptions: [InputSubscription] = []

    init() {
        let map = InputActionMap(name: "Play", bindings: [
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
}

@MainActor
struct ContentView: View {
    @State private var model = SharedPlayers()
    @State private var held = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.hub.players) { player in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(player.name): \(model.counts[player.id, default: 0]) presses")
                        Text("Owned: \(player.devices.map(\.name).joined(separator: ", "))")
                        Text("Fire: \(player.input.state(for: SharedPlayers.fire).phase.rawValue)")
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
                Text(model.status).font(.caption)
            }
            .padding()
            .buttonStyle(.bordered)
        }
        .onChange(of: held) { _, value in
            model.hub.submit([(.virtual("fire"), .button(value))], device: model.padA)
        }
        .onDisappear {
            model.hub.cancelAll()
            model.hub.submit([(.virtual("fire"), .button(false))], device: model.padA)
            held = false
        }
    }
}
