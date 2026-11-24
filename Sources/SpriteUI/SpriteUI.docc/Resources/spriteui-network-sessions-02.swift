import Foundation
import SpriteUI
import SwiftUI
import Observation

struct MoveCommand: Codable {
    let target: NetworkEntityID
    let step: Int
}

@MainActor @Observable
final class ReplicationLab {
    let network = InMemoryNetwork(seed: 7)
    let hostWorld = World()
    let clientWorld = World()
    let actor = Entity(name: "Host-owned actor")
    let camera = Entity(name: "Local camera", components: CameraComponent())
    let identity = NetworkEntityID()
    let hostID = NetworkPeerID(rawValue: "offline-host")
    let clientID = NetworkPeerID(rawValue: "offline-client")
    var host: NetworkSession?
    var client: NetworkSession?
    var hostX: Float = 0
    var clientX: Float = 0
    var status = "Not started"
    var cameraSurvived = true
    var ready = false
    var dropsSmallStates = false {
        didSet { network.unreliableLossRate = dropsSmallStates ? 1 : 0 }
    }
    var addsLatency = false {
        didSet { network.latency = addsLatency ? 0.1 : 0 }
    }
    @ObservationIgnored private var hostTransport: InMemoryNetworkTransport?
    @ObservationIgnored private var clientTransport: InMemoryNetworkTransport?
    @ObservationIgnored private var commands: EventSubscription?
    @ObservationIgnored private var commandBudget = 1

    init() { start() }

    func start() {
        guard host == nil else { return }
        do {
            actor.components.set(SynchronizationComponent(id: identity, owner: clientID, components: ["transform"]))
            // The parent is world.root; the camera is local and never synchronized.
            hostWorld.addEntity(actor)
            clientWorld.addEntity(camera)
            let first = try network.connect(NetworkPeer(id: hostID, displayName: "Host"))
            let second = try network.connect(NetworkPeer(id: clientID, displayName: "Client"))
            hostTransport = first
            clientTransport = second
            // This explicit allowlist contains only the built-in finite Transform value.
            let schema = NetworkReplicationSchema()
            let authority = NetworkSession(world: hostWorld, transport: first, role: .host, schema: schema)
            let replica = NetworkSession(world: clientWorld, transport: second,
                                         role: .client(host: hostID), schema: schema)
            host = authority
            client = replica
            commands = hostWorld.subscribe(to: NetworkEvents.CommandReceived.self) { [weak self] event in
                self?.validate(event)
            }
            try authority.start()
            try replica.start()
            // This lab owns the clock. Never also run automatic session updates.
            hostWorld.systems.setEnabled(false, for: NetworkReplicationSystem.self)
            clientWorld.systems.setEnabled(false, for: NetworkReplicationSystem.self)
            pump()
        } catch { status = "Start failed: \(error)" }
    }

    func pump() {
        // Three bounded delivery/update rounds finish the hello + baseline exchange.
        for _ in 0..<3 {
            network.advance(by: 0.1)
            commandBudget = 1
            host?.update(deltaTime: 0.1)
            client?.update(deltaTime: 0.1)
        }
        refresh()
    }

    private func refresh() {
        hostX = actor.position.x
        clientX = client?.entity(withNetworkID: identity)?.position.x ?? 0
        ready = client?.state == .connected
        cameraSurvived = camera.parent === clientWorld.root
        if let error = host?.lastError ?? client?.lastError { status = "Session failed: \(error)" }
        else { status = ready ? "Connected; full selected state received" : "Joining; pump again" }
    }

    func hostMove() {
        actor.position.x = min(100, actor.position.x + 10)
        refresh()
    }

    func command(_ step: Int) {
        do {
            let data = try JSONEncoder().encode(MoveCommand(target: identity, step: step))
            try client?.sendCommand(data)
            status = "Command queued; pump to validate on host"
        } catch { status = "Command failed: \(error)" }
    }

    private func validate(_ event: NetworkEvents.CommandReceived) {
        guard commandBudget > 0, event.data.count <= 256,
              let command = try? JSONDecoder().decode(MoveCommand.self, from: event.data),
              command.step == -1 || command.step == 1,
              let target = host?.entity(withNetworkID: command.target),
              target.components[SynchronizationComponent.self]?.owner == event.sender else { return }
        commandBudget -= 1 // At most one accepted move per explicit host update.
        let next = target.position.x + Float(command.step) * 10
        guard (-100...100).contains(next) else { return }
        target.position.x = next
    }

    func stop() {
        client?.stop()
        host?.stop()
        clientTransport?.disconnect()
        hostTransport?.disconnect()
        commands?.cancel()
        commands = nil
        client = nil
        host = nil
        clientTransport = nil
        hostTransport = nil
        ready = false
        cameraSurvived = camera.parent === clientWorld.root
        status = "Stopped; local camera preserved"
    }
}

@MainActor
struct ContentView: View {
    @State private var lab = ReplicationLab()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Offline replication lab").font(.title2)
                Text("Canonical model positions; no prediction")
                Text("Host x: \(lab.hostX, specifier: "%.0f") · Client x: \(lab.clientX, specifier: "%.0f")")
                HStack {
                    Circle().fill(.orange).frame(width: 20, height: 20)
                        .offset(x: CGFloat(lab.hostX))
                    Spacer().frame(width: 110)
                    Circle().fill(.cyan).frame(width: 20, height: 20)
                        .offset(x: CGFloat(lab.clientX))
                }.frame(height: 40)
                Text("Local client camera preserved: \(lab.cameraSurvived ? "yes" : "no")")
                Button("Host +10") { lab.hostMove() }.disabled(!lab.ready)
                Button("Client +10 command") { lab.command(1) }.disabled(!lab.ready)
                Button("Send invalid +900 command") { lab.command(900) }.disabled(!lab.ready)
                Toggle("Drop all small unreliable states", isOn: Binding(
                    get: { lab.dropsSmallStates },
                    set: { lab.dropsSmallStates = $0 }))
                Toggle("100 ms latency", isOn: Binding(
                    get: { lab.addsLatency },
                    set: { lab.addsLatency = $0 }))
                Button("Pump 0.3 seconds") { lab.pump() }.disabled(lab.host == nil)
                Button("Stop") { lab.stop() }
                Button("Restart / request fresh baseline") { lab.start() }.disabled(lab.host != nil)
                Text(lab.status).font(.caption)

            }
            .padding()
            .buttonStyle(.bordered)
        }
        .onAppear { lab.start() }
        .onDisappear { lab.stop() }

    }
}
