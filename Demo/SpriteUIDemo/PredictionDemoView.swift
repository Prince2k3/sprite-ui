import Foundation
import Observation
import SpriteUI
import SwiftUI

/// Fixed-step prediction and reconciliation over one account-free byte link.
@MainActor struct PredictionDemoView: View {
    @State private var model = PredictionPractice()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("PREDICTION LAB", systemImage: "bolt.horizontal.circle").font(.caption.bold()).foregroundStyle(.cyan)
                    Text("Move now.\nAgree with the host.").font(.largeTitle.bold())
                    Text("The cyan local visual responds immediately. Orange is host authority; gray is the client's latest replicated pose. Host corrections replay pending inputs and smooth only the visual.")
                        .foregroundStyle(.secondary)
                    Text(model.message).font(.footnote).accessibilityIdentifier("prediction-lab-status")
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.cyan.opacity(0.1), in: .rect(cornerRadius: 22))
                Button("Connect local preview") { model.connect() }.disabled(model.connected)
                HStack {
                    Button("Move left") { model.move(-1) }
                    Button("Stop movement") { model.move(0) }
                    Button("Move right") { model.move(1) }
                }.disabled(!model.ready)
                track("Local predicted visual", position: model.visualX, color: .cyan)
                track("Host authority", position: model.hostX, color: .orange)
                track("Latest replica · no local prediction", position: model.replicaX, color: .gray)
                Text("Predicted x: \(Int(model.visualX)) · Host x: \(Int(model.hostX)) · Replica x: \(Int(model.replicaX))")
                    .font(.caption.monospaced()).accessibilityIdentifier("prediction-positions")
                Text("Pending: \(model.pending) · Ack: \(model.acknowledged) · Replayed: \(model.replayed)").font(.caption.monospaced())
                Text("Corrections: \(model.corrections) · Last model error: \(model.errorDistance, format: .number.precision(.fractionLength(1)))")
                    .font(.caption).accessibilityIdentifier("prediction-corrections")
                Button("Nudge host left") { model.nudge() }.disabled(!model.ready)
                VStack(alignment: .leading, spacing: 10) {
                    Text("One-way latency: \(Int(model.latency * 1000)) ms")
                    Slider(value: $model.latency, in: 0...0.3, step: 0.05).accessibilityLabel("One-way latency")
                    Text("Unreliable packet loss: \(Int(model.loss * 100))%")
                    Slider(value: $model.loss, in: 0...0.8, step: 0.1).accessibilityLabel("Unreliable packet loss")
                    Toggle("Vary latency to add jitter", isOn: $model.jitter)
                }
                Text("60 fixed steps/s · 10 host results/s · bounded rectangular movement. Inputs and initial/correction results are reliable; normal complete results may be lost or reordered.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Disconnect preview") { model.stop() }
                Text("The replica is never moved by client prediction. This exercise uses kinematic value rules; native SpriteKit physics remains host-authoritative.")
                    .font(.caption).foregroundStyle(.secondary)
            }.buttonStyle(.bordered).tint(.cyan).padding().frame(maxWidth: 740, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle("Prediction & reconciliation")
        .task {
            var last = Date()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                let now = Date(); model.tick(min(0.1, max(0, now.timeIntervalSince(last)))); last = now
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.stop() } }
        .onDisappear { model.stop() }
    }
    private func track(_ title: String, position: Float, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold()).foregroundStyle(color)
            Canvas { context, size in
                let x = size.width * CGFloat((position + 150) / 300)
                let line = CGRect(x: 0, y: size.height / 2, width: size.width, height: 1)
                context.fill(Path(line), with: .color(.secondary.opacity(0.3)))
                context.fill(Path(ellipseIn: CGRect(x: x - 7, y: size.height / 2 - 7, width: 14, height: 14)), with: .color(color))
            }.frame(height: 44).background(.black.opacity(0.25), in: .rect(cornerRadius: 10))
        }
    }
}

@MainActor @Observable private final class PredictionPractice {
    var latency = 0.15
    var loss = 0.2
    var jitter = false
    var message = "Connect, move right, then stop. Nudge the host to see a correction."
    var connected = false
    var ready = false
    var visualX: Float = 0
    var hostX: Float = 0
    var replicaX: Float = 0
    var pending = 0
    var acknowledged: UInt64 = 0
    var replayed = 0
    var corrections: UInt64 = 0
    var errorDistance: Float = 0
    @ObservationIgnored private var network: InMemoryNetwork?
    @ObservationIgnored private var hostWorld: World?
    @ObservationIgnored private var clientWorld: World?
    @ObservationIgnored private var hostSession: NetworkSession?
    @ObservationIgnored private var clientSession: NetworkSession?
    @ObservationIgnored private var hostTransport: InMemoryNetworkTransport?
    @ObservationIgnored private var clientTransport: InMemoryNetworkTransport?
    @ObservationIgnored private var hostController: NetworkMovementController2D?
    @ObservationIgnored private var clientController: NetworkMovementController2D?
    @ObservationIgnored private var actor: Entity?
    @ObservationIgnored private var visual: Entity?
    @ObservationIgnored private var frames = 0
    private let player = NetworkPeer(id: .init(rawValue: "prediction-client"), displayName: "Client")
    private let rules = KinematicMovement2D(maximumSpeed: 90, bounds: .init(center: .zero, size: [280, 100]))
    func connect() {
        stop()
        do {
            let network = InMemoryNetwork(latency: latency, unreliableLossRate: loss, seed: 42)
            self.network = network
            let h = try network.connect(.init(id: .init(rawValue: "prediction-host"), displayName: "Host")), c = try network.connect(player)
            hostTransport = h; clientTransport = c
            let host = World(), client = World(); host.fixedStep = .init(); client.fixedStep = .init(); hostWorld = host; clientWorld = client
            let actor = Entity(name: "owned-player", components: SynchronizationComponent(owner: player.id)); host.addEntity(actor); self.actor = actor
            let visual = Entity(name: "local-visual"); client.addEntity(visual); self.visual = visual
            let hs = NetworkSession(world: host, transport: h, role: .host), cs = NetworkSession(world: client, transport: c, role: .client(host: h.localPeer.id))
            hostSession = hs; clientSession = cs; try hs.start(); try cs.start()
            hostController = try .host(in: host, session: hs, entity: actor, rules: rules)
            connected = true; message = "Connecting the baseline, then requesting a fresh host ownership epoch."
        } catch { stop(); message = String(describing: error) }
    }
    func move(_ direction: Float) {
        do { try clientController?.setInput([direction, 0]); message = direction == 0 ? "Neutral input queued. The host still consumes each command on its own fixed clock." : "Local input predicts now; authority and the replica follow through the link." }
        catch { message = String(describing: error) }
    }
    func nudge() {
        do { if let actor { try hostController?.correct(to: [max(-140, actor.position.x - 40), 0]); message = "Host correction queued reliably. Pending input will be replayed; only the cyan visual is smoothed." } }
        catch { message = String(describing: error) }
    }
    func tick(_ duration: TimeInterval) {
        guard connected, let network, let hostWorld, let clientWorld, let hostSession, let clientSession else { return }
        frames += 1; network.latency = jitter ? max(0, latency + (frames.isMultiple(of: 2) ? 0.09 : -0.09)) : latency
        network.unreliableLossRate = loss; network.advance(by: duration)
        hostWorld.update(deltaTime: duration); clientWorld.update(deltaTime: duration)
        do {
            if clientController == nil, clientSession.state == .connected, let actor, let visual {
                clientController = try .client(in: clientWorld, session: clientSession,
                    entityID: actor.components[SynchronizationComponent.self]!.id, visual: visual, rules: rules)
            }
        } catch { stop(); message = String(describing: error); return }
        if let error = clientController?.lastError ?? hostController?.lastError { stop(); message = error; return }
        let isReady = clientController?.status == .running
        if ready != isReady { ready = isReady; if isReady { message = "Ready. The client predicts its own separate visual, while host authority stays canonical." } }
        visualX = visual?.position.x ?? 0; hostX = actor?.position.x ?? 0
        if let id = actor?.components[SynchronizationComponent.self]?.id { replicaX = clientSession.entity(withNetworkID: id)?.position.x ?? 0 }
        pending = clientController?.pendingInputCount ?? 0; acknowledged = clientController?.acknowledgedInput ?? 0
        replayed = clientController?.replayedInputCount ?? 0; corrections = clientController?.correctionCount ?? 0; errorDistance = clientController?.correctionDistance ?? 0
        if hostSession.state != .connected || clientSession.state == .stopped || clientSession.state == .failed { stop(); message = "Session ended. Reconnect explicitly with a fresh prediction stream." }
    }
    func stop() {
        let wasConnected = connected
        hostController?.stop(); clientController?.stop(); hostController = nil; clientController = nil
        hostSession?.stop(); clientSession?.stop(); hostTransport?.disconnect(); clientTransport?.disconnect()
        hostSession = nil; clientSession = nil; hostTransport = nil; clientTransport = nil; network = nil
        hostWorld = nil; clientWorld = nil; actor = nil; visual = nil; connected = false; ready = false
        pending = 0; replayed = 0
        if wasConnected { message = "Preview stopped. Reconnect explicitly; held input was cleared." }
    }
}
