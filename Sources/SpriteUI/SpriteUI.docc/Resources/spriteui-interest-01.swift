import Foundation
import Observation
import SpriteUI
import SwiftUI

/// Two separate recipient scopes share one authoritative world and independent replication credits.
@MainActor struct ContentView: View {
    @State private var model = InterestPractice()
    @Environment(\.scenePhase) private var phase
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Send what each player needs.").font(.largeTitle.bold())
                Text("One host, two client worlds. Relevance changes use reliable membership; small prioritized pose updates consume each player's own credits.").foregroundStyle(.secondary)
                Text(model.message).font(.footnote).accessibilityIdentifier("interest-status")
                Button("Connect two local players") { model.connect() }.disabled(model.connected)
                HStack { Button("Alice left") { model.alice = -250 }; Button("Alice right") { model.alice = 250 } }.disabled(!model.connected)
                HStack { Button("Bob left") { model.bob = -250 }; Button("Bob right") { model.bob = 250 } }.disabled(!model.connected)
                Toggle("Alice joins red group", isOn: $model.red)
                Text("Alice: \(model.aliceCount) replicas · Bob: \(model.bobCount) replicas").font(.headline).accessibilityIdentifier("interest-scopes")
                Text("Each player retains their owned actor even when the observer moves away. Required parents accompany their visible children.").font(.caption)
                ForEach(model.metrics, id: \.peerID) { metric in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(metric.peerID.rawValue).font(.headline)
                        Text("Scope \(metric.relevantEntities)/\(metric.availableEntities) · replication \(metric.replicationBytesSent) B · packets \(metric.replicationPacketsSent)")
                        Text("Deferred publications \(metric.deferredPublications) · pending poses \(metric.deferredPoseUpdates) · credits \(Int(metric.availableReplicationBytes ?? 0)) B")
                    }.font(.caption.monospaced()).padding().frame(maxWidth: .infinity, alignment: .leading).background(.mint.opacity(0.1), in: .rect(cornerRadius: 14))
                }
                Text("Budget after reconnect: \(Int(model.rate)) B/s per player")
                Slider(value: $model.rate, in: 800...12_000, step: 400).accessibilityLabel("Replication rate")
                Text("Initial burst: 8,000 B · maximum pose packet: 700 B · application/control messages are outside this entity budget.").font(.caption).foregroundStyle(.secondary)
                Text("Unreliable pose loss: \(Int(model.loss * 100))%")
                Slider(value: $model.loss, in: 0...1, step: 0.1).accessibilityLabel("Interest pose loss")
                Button("Stop local preview") { model.stop() }
                Text("New SDKs are required on both ends for budgeted pose frames. No account or Game Center operation runs in this preview.").font(.caption).foregroundStyle(.secondary)
            }.buttonStyle(.bordered).tint(.mint).padding().frame(maxWidth: 740, alignment: .leading).frame(maxWidth: .infinity)
        }.navigationTitle("Relevance & traffic")
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                model.tick()
            }
        }
        .onChange(of: phase) { _, phase in if phase != .active { model.stop() } }
        .onDisappear { model.stop() }
    }
}
@MainActor @Observable private final class InterestPractice {
    var connected = false
    var alice: Float = -250
    var bob: Float = 250
    var red = false
    var rate = 1_200.0
    var loss = 0.3
    var aliceCount = 0
    var bobCount = 0
    var metrics: [NetworkPeerReplicationStatistics] = []
    var message = "Connect explicitly, then move Alice and Bob independently."
    @ObservationIgnored private var hub: InMemoryNetwork?
    @ObservationIgnored private var worlds: [World] = []
    @ObservationIgnored private var sessions: [NetworkSession] = []
    @ObservationIgnored private var links: [InMemoryNetworkTransport] = []
    @ObservationIgnored private var interest: NetworkSpatialInterest?
    @ObservationIgnored private var actors: [Entity] = []
    @ObservationIgnored private var time: Float = 0
    private let a = NetworkPeer(id: .init(rawValue: "Alice"), displayName: "Alice")
    private let b = NetworkPeer(id: .init(rawValue: "Bob"), displayName: "Bob")
    func connect() {
        stop()
        do {
            let hub = InMemoryNetwork(latency: 0.05, unreliableLossRate: loss, seed: 12); self.hub = hub
            let h = try hub.connect(.init(id: .init(rawValue: "host"), displayName: "Host")), a = try hub.connect(a), b = try hub.connect(b); links = [h, a, b]
            worlds = [World(), World(), World()]; let world = worlds[0]
            let interest = try NetworkSpatialInterest(world: world, radius: 170, exitMargin: 30); self.interest = interest
            try interest.setObserver(at: [alice, 0], for: self.a.id); try interest.setObserver(at: [bob, 0], for: self.b.id)
            for index in 0..<10 {
                let actor = Entity(name: "Bot \(index)", components: SynchronizationComponent(), NetworkInterestComponent(groups: index == 0 ? ["red"] : [], priority: index.isMultiple(of: 2) ? .high : .background))
                actor.position = [index < 5 ? -250 : 250, Float(index % 5) * 18]; world.addEntity(actor); actors.append(actor)
            }
            for (peer, x) in [(self.a.id, Float(-250)), (self.b.id, Float(250))] {
                let player = Entity(name: peer.rawValue, components: SynchronizationComponent(owner: peer)); player.position = [x, -20]; world.addEntity(player)
            }
            let config = NetworkSessionConfiguration(updatesPerSecond: 10)
            sessions = [NetworkSession(world: world, transport: h, role: .host, configuration: config,
                replicationPolicy: interest.policy, replicationBudget: .init(bytesPerSecond: rate, burstBytes: 8_000, maximumPosePacketBytes: 700)),
                NetworkSession(world: worlds[1], transport: a, role: .client(host: h.localPeer.id)),
                NetworkSession(world: worlds[2], transport: b, role: .client(host: h.localPeer.id))]
            for session in sessions { try session.start() }
            connected = true; message = "Joining two independent recipient scopes."
        } catch { stop(); message = String(describing: error) }
    }
    func tick() {
        guard connected, let hub, worlds.count == 3 else { return }
        do {
            try interest?.setObserver(at: [alice, 0], groups: red ? ["red"] : [], for: a.id)
            try interest?.setObserver(at: [bob, 0], for: b.id)
            time += 0.1
            for (index, actor) in actors.enumerated() { actor.position.y = Float(index % 5) * 18 + sin(time * 2 + Float(index)) * 15 }
            hub.unreliableLossRate = loss; hub.advance(by: 0.1); for world in worlds { world.update(deltaTime: 0.1) }
            if let error = sessions.compactMap(\.lastError).first { stop(); message = error.localizedDescription; return }
            aliceCount = worlds[1].entities.count; bobCount = worlds[2].entities.count; metrics = sessions[0].replicationStatistics
            message = sessions.allSatisfy { $0.state == .connected } ? "Connected · scopes and credits are independent." : "Waiting for initial membership credits."
        } catch { stop(); message = String(describing: error) }
    }
    func stop() {
        for session in sessions { session.stop() }; for link in links { link.disconnect() }
        interest?.removeAllObservers(); interest = nil; sessions = []; links = []; worlds = []; actors = []; hub = nil; connected = false
        message = "Preview stopped. Reconnect explicitly."
    }
}
