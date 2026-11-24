import Foundation
import Observation
import SpriteUI
import SwiftUI

/// Host-issued historical views, bounded ray/proximity actions, and once-only confirmations.
@MainActor struct InteractionDemoView: View {
    @State private var model = InteractionPractice()
    @Environment(\.scenePhase) private var phase
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("INTERACTION LAB", systemImage: "scope").font(.caption.bold()).foregroundStyle(.mint)
                    Text("Aim at what\nyou saw.").font(.largeTitle.bold())
                    Text("Cyan is the exact host-issued view used for aiming. Orange is the live host target. A shot queries the retained view without moving the live world.").foregroundStyle(.secondary)
                    Text(model.message).font(.footnote).accessibilityIdentifier("interaction-status")
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.mint.opacity(0.1), in: .rect(cornerRadius: 22))
                Button("Start local arena") { model.start() }.disabled(model.connected)
                arena
                HStack {
                    Button("Fire at viewed target") { model.fire() }
                    Button("Three-shot burst") { model.burst() }
                }.disabled(!model.ready)
                Button("Interact with nearby beacon") { model.interact() }.disabled(!model.ready)
                Text(model.result).font(.headline).accessibilityIdentifier("interaction-result")
                Text("Predicted feedback: \(model.predictions) · Final receipts: \(model.confirmations) · Pending: \(model.pending)")
                    .font(.caption.monospaced()).accessibilityIdentifier("interaction-receipts")
                Text("Host hits: \(model.hits) · Without rewind: \(model.naiveHits) · Interactions: \(model.interactions)")
                    .font(.caption.monospaced()).accessibilityIdentifier("interaction-score")
                Toggle("Block the line of sight", isOn: $model.wall)
                Toggle("Respawn target on next shot", isOn: $model.respawn)
                Toggle("Vary latency to add jitter", isOn: $model.jitter)
                VStack(alignment: .leading) {
                    Text("One-way latency: \(Int(model.latency * 1000)) ms")
                    Slider(value: $model.latency, in: 0...0.35, step: 0.05).accessibilityLabel("Interaction latency")
                    Text("Replica pose loss: \(Int(model.loss * 100))%")
                    Slider(value: $model.loss, in: 0...0.8, step: 0.1).accessibilityLabel("Replica pose loss")
                }
                Text("600 ms maximum view age · 250 ms host cooldown. Views, actions, and final receipts are reliable. Replica pose loss affects ordinary replication only. Excessively old views are refused.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Disconnect arena") { model.stop() }
                Text("Local byte link only: no account, Game Center request, or reward reporting. Hit counts are applied by this app on new host receipts, never from predicted feedback.")
                    .font(.caption).foregroundStyle(.secondary)
            }.buttonStyle(.bordered).tint(.mint).padding().frame(maxWidth: 740, alignment: .leading).frame(maxWidth: .infinity)
        }.navigationTitle("Interactions & lag compensation")
        .task {
            var last = Date()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                let now = Date(); model.tick(min(0.1, max(0, now.timeIntervalSince(last)))); last = now
            }
        }
        .onChange(of: phase) { _, phase in if phase != .active { model.stop() } }
        .onDisappear { model.stop() }
    }
    private var arena: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Exact received view / live host").font(.caption.bold())
            Canvas { context, size in
                func point(_ p: SIMD2<Float>) -> CGPoint { .init(x: CGFloat((p.x + 160) / 320) * size.width, y: CGFloat((100 - p.y) / 200) * size.height) }
                func disc(_ p: SIMD2<Float>, _ radius: CGFloat, _ color: Color) {
                    let p = point(p); context.fill(Path(ellipseIn: .init(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)), with: .color(color))
                }
                if model.wall {
                    context.fill(Path(CGRect(x: size.width / 2 - 4, y: 8, width: 8, height: size.height - 16)), with: .color(.gray.opacity(0.5)))
                }
                var beam = Path(); beam.move(to: point([-120, 0])); beam.addLine(to: point(model.viewedTarget))
                context.stroke(beam, with: .color(.cyan.opacity(0.35)), style: .init(lineWidth: 1, dash: [5, 5]))
                disc([-120, 0], 8, .white); disc([-75, 0], 5, .green)
                disc(model.liveTarget, 9, .orange); disc(model.viewedTarget, 6, .cyan)
            }.frame(height: 190).background(.black.opacity(0.25), in: .rect(cornerRadius: 14))
        }
    }
}

@MainActor @Observable private final class InteractionPractice {
    var connected = false
    var ready = false
    var latency = 0.15
    var loss = 0.2
    var jitter = false
    var wall = false
    var respawn = false
    var liveTarget = SIMD2<Float>(100, 0)
    var viewedTarget = SIMD2<Float>(100, 0)
    var message = "Start the arena, then fire at the cyan target."
    var result = "No confirmed action yet"
    var predictions = 0
    var confirmations = 0
    var hits = 0
    var naiveHits = 0
    var interactions = 0
    var pending = 0
    @ObservationIgnored private var network: InMemoryNetwork?
    @ObservationIgnored private var hostWorld: World?
    @ObservationIgnored private var clientWorld: World?
    @ObservationIgnored private var ht: InMemoryNetworkTransport?
    @ObservationIgnored private var ct: InMemoryNetworkTransport?
    @ObservationIgnored private var hs: NetworkSession?
    @ObservationIgnored private var cs: NetworkSession?
    @ObservationIgnored private var host: NetworkInteractionController2D?
    @ObservationIgnored private var client: NetworkInteractionController2D?
    @ObservationIgnored private var shooter: Entity?
    @ObservationIgnored private var target: Entity?
    @ObservationIgnored private var beacon: Entity?
    @ObservationIgnored private var blocker: Entity?
    @ObservationIgnored private var tokens: [EventSubscription] = []
    @ObservationIgnored private var aims: [UInt64: SIMD2<Float>] = [:]
    @ObservationIgnored private var time: TimeInterval = 0
    @ObservationIgnored private var frames = 0
    private let owner = NetworkPeer(id: .init(rawValue: "interaction-owner"), displayName: "Owner")
    private let configuration = NetworkInteractionConfiguration(maximumRewind: 0.6, cooldown: 0.25)
    func start() {
        stop()
        do {
            let network = InMemoryNetwork(latency: latency, unreliableLossRate: loss, seed: 42); self.network = network
            let h = try network.connect(.init(id: .init(rawValue: "interaction-host"), displayName: "Host")), c = try network.connect(owner); ht = h; ct = c
            let hw = World(), cw = World(); hostWorld = hw; clientWorld = cw
            let shooter = Entity(name: "shooter", components: SynchronizationComponent(owner: owner.id), NetworkInteractionBodyComponent(shape: .circle(radius: 3), isTarget: false))
            shooter.position = [-120, 0]; hw.addEntity(shooter); self.shooter = shooter
            let target = Entity(name: "target", components: SynchronizationComponent(), NetworkInteractionBodyComponent(shape: .circle(radius: 7)))
            target.position = [100, 0]; hw.addEntity(target); self.target = target
            let beacon = Entity(name: "beacon", components: SynchronizationComponent(), NetworkInteractionBodyComponent(shape: .circle(radius: 5), isTarget: false, blocksRays: false, canInteract: true))
            beacon.position = [-75, 0]; hw.addEntity(beacon); self.beacon = beacon
            let blocker = Entity(name: "wall", components: SynchronizationComponent()); blocker.position = .zero; hw.addEntity(blocker); self.blocker = blocker
            let hs = NetworkSession(world: hw, transport: h, role: .host), cs = NetworkSession(world: cw, transport: c, role: .client(host: h.localPeer.id))
            self.hs = hs; self.cs = cs; try hs.start(); try cs.start()
            host = try .host(in: hw, session: hs, entity: shooter, configuration: configuration)
            tokens = [cw.subscribe(to: NetworkInteractionEvents.Predicted.self) { [weak self] _ in self?.predictions += 1 },
                hw.subscribe(to: NetworkInteractionEvents.Resolved.self) { [weak self] in self?.applyHost($0) },
                cw.subscribe(to: NetworkInteractionEvents.Resolved.self) { [weak self] in self?.confirm($0) }]
            predictions = 0; confirmations = 0; hits = 0; naiveHits = 0; interactions = 0; time = 0
            result = "Waiting for an issued view"; connected = true; message = "Joining the baseline, then requesting a fresh interaction epoch."
        } catch { stop(); message = String(describing: error) }
    }
    func fire() {
        guard let view = client?.latestView, let sourceID = shooter?.components[SynchronizationComponent.self]?.id,
              let origin = view.state.bodies.first(where: { $0.id == sourceID })?.position else { return }
        let delta = viewedTarget - origin, length = sqrt(delta.x * delta.x + delta.y * delta.y)
        guard length > 0 else { return }
        do {
            let direction = delta / length
            if let sequence = try client?.perform(.ray(direction: direction)) { aims[sequence] = direction }
            if respawn { target?.components.set(NetworkInteractionBodyComponent(shape: .circle(radius: 7))); respawn = false }
            result = "Predicted shot feedback · waiting for host"
        } catch { result = String(describing: error) }
    }
    func burst() { for _ in 0..<3 { fire() } }
    func interact() {
        guard let id = beacon?.components[SynchronizationComponent.self]?.id else { return }
        do { try client?.perform(.interact(with: id)); result = "Predicted interaction · waiting for host" } catch { result = String(describing: error) }
    }
    func tick(_ delta: TimeInterval) {
        guard connected, let network, let hw = hostWorld, let cw = clientWorld, let hs, let cs, let shooter else { return }
        time += delta; frames += 1; liveTarget = [100, Float(sin(time * 3.5)) * 72]; target?.position = liveTarget
        if wall, blocker?.components.has(NetworkInteractionBodyComponent.self) == false {
            blocker?.components.set(NetworkInteractionBodyComponent(shape: .rectangle(size: [8, 200]), isTarget: false))
        } else if !wall { blocker?.components.remove(NetworkInteractionBodyComponent.self) }
        network.latency = jitter ? max(0, latency + (frames.isMultiple(of: 2) ? 0.06 : -0.06)) : latency
        network.unreliableLossRate = loss; network.advance(by: delta); hw.update(deltaTime: delta); cw.update(deltaTime: delta)
        do {
            if client == nil, cs.state == .connected { client = try .client(in: cw, session: cs, entityID: shooter.components[SynchronizationComponent.self]!.id, configuration: configuration) }
        } catch { stop(); message = String(describing: error); return }
        if let error = client?.lastError ?? host?.lastError { stop(); message = error; return }
        ready = client?.status == .running; pending = client?.pendingActionCount ?? 0
        if let id = target?.components[SynchronizationComponent.self]?.id,
           let point = client?.latestView?.state.bodies.first(where: { $0.id == id })?.position { viewedTarget = point }
        if ready { message = "Ready · aim uses a host-issued view, not a client timestamp." }
        if hs.state != .connected || cs.state == .stopped || cs.state == .failed { stop() }
    }
    private func applyHost(_ event: NetworkInteractionEvents.Resolved) {
        guard event.isAuthority else { return }
        let direction = aims.removeValue(forKey: event.result.sequence)
        guard case .accepted(let outcome) = event.result.resolution else { return }
        if outcome.kind == .hit {
            hits += 1
            if let direction, let target {
                let current = CollisionGeometry.Shape(.circle(radius: 7), position: target.position)
                if CollisionGeometry.raycast(from: outcome.origin, to: outcome.origin + direction * 1_000, against: current) != nil { naiveHits += 1 }
            }
        } else if outcome.kind == .interacted { interactions += 1 }
    }
    private func confirm(_ event: NetworkInteractionEvents.Resolved) {
        guard !event.isAuthority else { return }; confirmations += 1
        switch event.result.resolution {
        case .accepted(let outcome): result = "Confirmed: \(outcome.kind.rawValue) · action \(event.result.sequence)"
        case .rejected(let reason): result = "Refused: \(reason.rawValue) · action \(event.result.sequence)"
        }
    }
    func stop() {
        let wasConnected = connected
        host?.stop(); client?.stop(); host = nil; client = nil
        for token in tokens { token.cancel() }; tokens = []; aims = [:]
        hs?.stop(); cs?.stop(); ht?.disconnect(); ct?.disconnect()
        hs = nil; cs = nil; ht = nil; ct = nil; network = nil; hostWorld = nil; clientWorld = nil
        shooter = nil; target = nil; beacon = nil; blocker = nil; ready = false; connected = false; pending = 0
        if wasConnected { message = "Arena stopped. Start explicitly with a fresh view history." }
    }
}
