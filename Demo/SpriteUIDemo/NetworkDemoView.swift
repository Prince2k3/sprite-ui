import Foundation
import Observation
import SpriteUI
import SwiftUI

@MainActor
struct NetworkDemoView: View {
    @State private var model = NetworkDemoModel()
    @State private var width: CGFloat = 0
    @State private var sheet: NetworkDemoSheet?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Network lab", systemImage: "network").font(.largeTitle.bold())
                    Text("One authority. Two independent worlds.").font(.headline).foregroundStyle(.mint)
                    Text("The host owns the colored actors. The client receives complete states; its grid and camera stay local.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                let layout = width >= 680 ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 12))
                layout {
                    NetworkDemoArena(model: model, side: .host)
                    NetworkDemoArena(model: model, side: .client)
                }
                NetworkDemoCounters(model: model)
                offlineControls
                gameCenterControls
                if model.multiplayer.matchmakingState == .ready {
                    NetworkDemoArena(model: model, side: .live)
                    liveControls
                }
            }
            .padding(16)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(red: 0.035, green: 0.05, blue: 0.09))
        .preferredColorScheme(.dark).tint(.mint)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onAppear { model.resume() }
        .onDisappear { model.shutdown() }
        .sheet(item: $sheet) { item in
            switch item {
            case .authentication: GameCenterAuthenticationView(multiplayer: model.multiplayer)
            case .matchmaking: GameCenterMatchmakingView(multiplayer: model.multiplayer, request: .init())
            }
        }
        .onChange(of: model.multiplayer.matchmakingState) { _, state in
            if state == .ready { sheet = nil }
            else { model.stopLiveSession() }
        }
    }

    private var offlineControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("In-memory link", systemImage: "cable.connector").font(.headline)
            Text("Seed 42 · 10 state updates/s · link advanced once per host frame")
                .font(.caption).foregroundStyle(.secondary)
            Text("Latency \(Int(model.latency * 1000)) ms · one way").monospacedDigit()
            Slider(value: $model.latency, in: 0...0.8, step: 0.05).accessibilityLabel("Network latency")
            Text("Unreliable loss \(Int(model.loss * 100))%").monospacedDigit()
            Slider(value: $model.loss, in: 0...1, step: 0.1).accessibilityLabel("Unreliable packet loss")
            Text("Loss affects only transform-only frames ≤1,000 bytes. Full sprite states can exceed that limit and use reliable delivery, as shown above. Structural changes and commands are always reliable (up to 48,000 bytes).")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Host patrol", isOn: $model.patrol)
            Toggle("Primary actor enabled", isOn: Binding(get: { model.primaryEnabled }, set: { model.setEnabled($0) }))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 8) {
                Button("Host move left") { model.hostMove(-1) }
                Button("Host move right") { model.hostMove(1) }
                Button(model.hasExtra ? "Despawn extra" : "Spawn extra") { model.toggleExtra() }
                Button(model.clientSession == nil ? "Join / reconnect" : "Disconnect client") { model.toggleClient() }
                Button("Prepare late join") { model.prepareLateJoin() }
                Button("Client move left") { model.sendMove(-1) }.disabled(!model.clientConnected)
                Button("Client move right") { model.sendMove(1) }.disabled(!model.clientConnected)
                Button("Test rejected command") { model.sendMove(1, unauthorized: true) }.disabled(!model.clientConnected)
                Button("Offset client camera") { model.offsetClientCamera() }
            }
            .buttonStyle(.bordered).controlSize(.large)
            Text("Late join: disconnect, change host actors, then Join. Reconnect requests a fresh baseline and preserves the local camera. The rejected command targets an actor the sender does not own.")
                .font(.caption).foregroundStyle(.secondary)
            Text(model.status).font(.caption).foregroundStyle(.mint).accessibilityIdentifier("network-status")
        }
        .padding(16).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
    }

    private var gameCenterControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Game Center · real devices", systemImage: "person.2.wave.2").font(.headline)
            Text(model.authenticationDescription).font(.subheadline)
            Text(model.matchmakingDescription).font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack { gameCenterButtons }
                VStack(alignment: .leading) { gameCenterButtons }
            }
            .buttonStyle(.bordered).controlSize(.large)
            if model.multiplayer.hasPendingInvite {
                Text("Invitation from \(model.multiplayer.pendingInviterName ?? "a player"). Open Matchmaking to accept or decline.")
                    .font(.caption).foregroundStyle(.mint)
            }
            DisclosureGroup("Live play setup") {
                Text("Use a signed app with a valid team, the Game Center capability and entitlement, and a matching App Store Connect app with Game Center and multiplayer compatibility configured. Connect two signed-in devices. This demo does not enable capabilities or sign in automatically. Offline simulation is available without Game Center setup. A simulator build alone does not verify live authentication or matchmaking.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }
        }
        .padding(16).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder private var gameCenterButtons: some View {
        Button("Sign in…") { sheet = .authentication }
        Button("Matchmaking…") { sheet = .matchmaking }
            .disabled(model.multiplayer.authenticationState != .authenticated)
        Button("Disconnect match") { model.disconnectLive() }
            .disabled(model.multiplayer.transport == nil)
    }

    private var liveControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.liveDescription).font(.caption)
            HStack {
                Button("Move left") { model.liveMove(-1) }
                Button("Move right") { model.liveMove(1) }
            }.buttonStyle(.bordered).controlSize(.large)
            Text("The elected host validates the remote sender and owns actor movement. A disconnected match requires new matchmaking; there is no host migration.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private enum NetworkDemoSheet: String, Identifiable {
    case authentication, matchmaking
    var id: String { rawValue }
}

private enum NetworkDemoSide { case host, client, live }

@MainActor
private struct NetworkDemoArena: View {
    let model: NetworkDemoModel
    let side: NetworkDemoSide

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: side == .host ? "server.rack" : "display")
                    .font(.headline).foregroundStyle(side == .host ? .mint : .cyan)
                Spacer()
                Text(model.stateLabel(side)).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            GameView(viewports: model.viewports(side)) { model.install($0, side: side) }
                .onGameSurfaceChange { model.resize($0, side: side) }
                .frame(height: 230).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("\(title) network arena")
                .accessibilityIdentifier(side == .host ? "network-host-arena" : side == .client ? "network-client-arena" : "network-live-arena")
        }
        .padding(12).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
    }

    private var title: String { side == .host ? "Host · authority" : side == .client ? "Client · replica" : "Game Center · live" }
}

@MainActor
private struct NetworkDemoCounters: View {
    let model: NetworkDemoModel
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("AUTHORITATIVE → REPLICATED").font(.caption.bold()).foregroundStyle(.mint)
            Text("Host: \(model.hostCount) actors · seq \(model.hostSession?.sequence ?? 0)   |   Client: \(model.clientSession?.replicatedEntityCount ?? 0) actors · seq \(model.clientSession?.sequence ?? 0)")
            Text("Primary x: host \(model.hostX, specifier: "%.0f") · client \(model.clientX, specifier: "%.0f") · camera x \(model.cameraX, specifier: "%.0f")")
            Text("Link: \(model.linkTime, specifier: "%.1f")s · \(model.pendingPackets) queued · accepted \(model.acceptedCommands) / rejected \(model.rejectedCommands) commands")
            if let traffic = model.hostTraffic {
                Text("Last state: \(traffic.lastStateBytes) bytes · \(traffic.lastStateReliable ? "RELIABLE" : "UNRELIABLE") · sent R \(traffic.reliableStates) / U \(traffic.unreliableStates)")
                Text(traffic.lastStateBytes > 1000 ? "Reliable fallback: full state exceeds 1,000 bytes; the loss slider will not drop it." : "Small transform-only updates may use unreliable delivery; new baselines and structural changes remain reliable.")
                    .foregroundStyle(.secondary)
            }
            if let error = model.hostSession?.lastError ?? model.clientSession?.lastError {
                Text("Session error: \(String(describing: error))").foregroundStyle(.orange)
            }
        }
        .font(.caption.monospacedDigit())
        .accessibilityIdentifier("network-counters")
    }
}

/// Measures the actual session choice without changing bytes, sender identity or delivery.
@MainActor @Observable
private final class NetworkDemoTransport: NetworkTransport {
    let base: any NetworkTransport
    var localPeer: NetworkPeer { base.localPeer }
    var connectedPeers: [NetworkPeer] { base.connectedPeers }
    var onEvent: (@MainActor (NetworkTransportEvent) -> Void)?
    private(set) var lastStateBytes = 0
    private(set) var lastStateReliable = true
    private(set) var reliableStates = 0
    private(set) var unreliableStates = 0

    init(_ base: any NetworkTransport) {
        self.base = base
        // Keep consuming lifecycle events after stop, including a retired connection.
        base.onEvent = { [weak self] event in self?.onEvent?(event) }
    }
    func send(_ data: Data, to peer: NetworkPeerID, reliably: Bool) throws {
        try base.send(data, to: peer, reliably: reliably)
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["kind"] as? String == "state" {
            lastStateBytes = data.count; lastStateReliable = reliably
            if reliably { reliableStates += 1 } else { unreliableStates += 1 }
        }
    }
    func disconnect() { base.disconnect() }
}

private struct NetworkDemoMove: Codable {
    let actor: NetworkEntityID
    let step: Int
}

/// Root-local service: never selected in the replication schema, and no model cycle.
@MainActor
private final class NetworkDemoDriver: Component {
    weak var model: NetworkDemoModel?
    init(_ model: NetworkDemoModel) { self.model = model }
    func cloned() -> Self? { nil }
}

private struct NetworkDemoPump: System {
    init(world: World) {}
    mutating func update(context: UpdateContext) {
        context.world.root.components[NetworkDemoDriver.self]?.model?.tick(context.unscaledDeltaTime)
    }
}

@MainActor @Observable
private final class NetworkDemoModel {
    let multiplayer = GameCenterMultiplayer()
    var latency = 0.15 { didSet { network.latency = latency } }
    var loss = 0.2 { didSet { network.unreliableLossRate = loss } }
    var patrol = true
    private(set) var primaryEnabled = true
    private(set) var hasExtra = false
    private(set) var hostSession: NetworkSession?
    private(set) var clientSession: NetworkSession?
    private(set) var liveSession: NetworkSession?
    private(set) var hostTraffic: NetworkDemoTransport?
    private(set) var status = "Starting the offline worlds…"
    private(set) var hostCount = 1
    private(set) var hostX: Float = 0
    private(set) var clientX: Float = 0
    private(set) var cameraX: Float = 0
    private(set) var linkTime: TimeInterval = 0
    private(set) var pendingPackets = 0
    private(set) var acceptedCommands = 0
    private(set) var rejectedCommands = 0
    @ObservationIgnored private var network = InMemoryNetwork(latency: 0.15, unreliableLossRate: 0.2, seed: 42)
    @ObservationIgnored private var clientTraffic: NetworkDemoTransport?
    @ObservationIgnored private var liveTraffic: NetworkDemoTransport?
    @ObservationIgnored private var hostContent: GameViewContent?
    @ObservationIgnored private var clientContent: GameViewContent?
    @ObservationIgnored private var liveContent: GameViewContent?
    @ObservationIgnored private var subscriptions: [EventSubscription] = []
    @ObservationIgnored private var clientBaseline: EventSubscription?
    @ObservationIgnored private var liveSubscriptions: [EventSubscription] = []
    @ObservationIgnored private var active = false
    @ObservationIgnored private var wantsClient = true
    @ObservationIgnored private var elapsed: TimeInterval = 0
    @ObservationIgnored private var sampleElapsed: TimeInterval = 0
    @ObservationIgnored private var commandTimes: [NetworkPeerID: TimeInterval] = [:]
    @ObservationIgnored private let hostPeer = NetworkPeer(id: .init(rawValue: "host"), displayName: "Local host")
    @ObservationIgnored private let clientPeer = NetworkPeer(id: .init(rawValue: "client"), displayName: "Local client")
    @ObservationIgnored private let primaryID = NetworkEntityID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    @ObservationIgnored private let extraID = NetworkEntityID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    @ObservationIgnored private let hostCamera = Entity(name: "Host local camera", components: CameraComponent())
    @ObservationIgnored private let clientCamera = Entity(name: "Client local camera", components: CameraComponent())
    @ObservationIgnored private let liveCamera = Entity(name: "Live local camera", components: CameraComponent())

    var clientConnected: Bool { clientSession?.state == .connected }
    var authenticationDescription: String {
        switch multiplayer.authenticationState {
        case .unauthenticated: "Not signed in · choose Sign in to begin"
        case .authenticating: "Signing in…"
        case .authenticated: "Signed in as \(multiplayer.localPeer?.displayName ?? "player")"
        case .failed(let message): "Sign-in failed: \(message)"
        }
    }
    var matchmakingDescription: String {
        switch multiplayer.matchmakingState {
        case .idle: "No live match · offline link above is independent"
        case .matchmaking: "Matchmaking…"
        case .waitingForPlayers: "Waiting for the complete player roster…"
        case .ready: "Match ready · host elected from authenticated player IDs"
        case .failed(let message): "Match failed: \(message)"
        }
    }
    var liveDescription: String {
        guard let liveSession else { return "Installing live session…" }
        return "\(liveSession.isHost ? "Host authority" : "Client replica") · \(stateLabel(.live)) · seq \(liveSession.sequence) · \(liveSession.replicatedEntityCount) actors\(liveSession.lastError.map { " · \($0)" } ?? "")"
    }

    func viewports(_ side: NetworkDemoSide) -> [GameViewport] {
        [GameViewport(id: "main", camera: camera(side).id, region: .largestUsable)]
    }
    func stateLabel(_ side: NetworkDemoSide) -> String {
        let session = side == .host ? hostSession : side == .client ? clientSession : liveSession
        return session.map { String(describing: $0.state).uppercased() } ?? "OFFLINE"
    }
    private func camera(_ side: NetworkDemoSide) -> Entity { side == .host ? hostCamera : side == .client ? clientCamera : liveCamera }

    func install(_ content: GameViewContent, side: NetworkDemoSide) {
        content.renderer.backgroundColor = .init(red: 0.025, green: 0.04, blue: 0.07, alpha: 1)
        let camera = camera(side)
        camera.removeFromParent(); content.add(camera)
        for x in stride(from: -240, through: 240, by: 40) {
            let line = Entity(components: SpriteComponent(color: .white.opacity(0.07), size: [1, 320]))
            line.position = [Float(x), 0]; line.zPosition = -10; content.add(line)
        }
        for y in stride(from: -160, through: 160, by: 40) {
            let line = Entity(components: SpriteComponent(color: .white.opacity(0.07), size: [480, 1]))
            line.position = [0, Float(y)]; line.zPosition = -10; content.add(line)
        }
        resize(content.surfaceGeometry, side: side)
        switch side {
        case .host:
            hostContent = content
            content.add(actor(primaryID, owner: clientPeer.id))
            content.world.root.components.set(NetworkDemoDriver(self))
            do { try content.world.systems.add(NetworkDemoPump.self) } catch { status = "Pump setup: \(error)" }
            subscriptions = [content.subscribe(to: NetworkEvents.CommandReceived.self) { [weak self] event in self?.receive(event, live: false) }]
            startOffline()
        case .client: clientContent = content; startOffline()
        case .live: liveContent = content; startLive(content)
        }
    }

    func resize(_ geometry: GameSurfaceGeometry, side: NetworkDemoSide) {
        let size = geometry.largestUsableRegion.size
        guard size.width > 0, size.height > 0 else { return }
        camera(side).components[CameraComponent.self]?.zoom = Float(min(size.width / 360, size.height / 240))
    }
    func resume() { active = true; startOffline() }
    func shutdown() {
        active = false; stopOffline(); stopLiveSession(); multiplayer.shutdown()
    }
    private func schema() throws -> NetworkReplicationSchema {
        var schema = NetworkReplicationSchema()
        try schema.register(SpriteComponent.self, named: "sprite")
        return schema
    }
    private func actor(_ id: NetworkEntityID, owner: NetworkPeerID? = nil) -> Entity {
        let entity = Entity(name: id == primaryID ? "Primary" : "Extra", components:
            SpriteComponent(color: id == primaryID ? .mint : .orange, size: [28, 28]),
            SynchronizationComponent(id: id, owner: owner, components: ["transform", "sprite"]))
        if id == extraID { entity.position = [65, 55] }
        return entity
    }
    private func startOffline() {
        guard active, hostSession == nil, let hostContent, clientContent != nil else { return }
        do {
            let transport = NetworkDemoTransport(try network.connect(hostPeer))
            hostTraffic = transport
            let session = NetworkSession(world: hostContent.world, transport: transport, role: .host, schema: try schema())
            try session.start(); hostSession = session
            if wantsClient { try joinClient() }
            status = wantsClient ? "Offline link ready. The client is requesting its baseline." : "Host is running. Change actors, then Join for a late baseline."
        } catch { status = "Offline connection failed: \(error)"; stopOffline() }
    }
    private func joinClient() throws {
        guard clientSession == nil, let clientContent else { return }
        commandTimes[clientPeer.id] = nil
        clientBaseline?.cancel()
        clientBaseline = clientContent.subscribe(to: NetworkEvents.PeerJoined.self) { [weak self] _ in
            guard let self, self.clientConnected else { return }
            self.status = "Client received the host baseline; its local camera was preserved."
        }
        let transport = NetworkDemoTransport(try network.connect(clientPeer))
        clientTraffic = transport
        let session = NetworkSession(world: clientContent.world, transport: transport, role: .client(host: hostPeer.id), schema: try schema())
        do { try session.start(); clientSession = session }
        catch { transport.disconnect(); clientTraffic = nil; throw error }
    }
    private func stopOffline() {
        clientBaseline?.cancel(); clientBaseline = nil
        clientSession?.stop(); hostSession?.stop()
        clientTraffic?.disconnect(); hostTraffic?.disconnect()
        clientSession = nil; hostSession = nil; clientTraffic = nil; hostTraffic = nil
        network.advance(by: 0)
        network = InMemoryNetwork(latency: latency, unreliableLossRate: loss, seed: 42)
    }
    func toggleClient() {
        if clientSession != nil {
            clientBaseline?.cancel(); clientBaseline = nil
            clientSession?.stop(); clientTraffic?.disconnect()
            clientSession = nil; clientTraffic = nil; wantsClient = false
            status = "Client disconnected. Its camera is still local; host changes continue."
        } else {
            wantsClient = true
            do { try joinClient(); status = "Joining with a fresh complete baseline…" }
            catch { status = "Join failed: \(error)" }
        }
    }
    func prepareLateJoin() { wantsClient = false; stopOffline(); startOffline() }
    func setEnabled(_ enabled: Bool) {
        primaryEnabled = enabled; hostSession?.entity(withNetworkID: primaryID)?.isEnabled = enabled
        synchronizeHost()
    }
    func toggleExtra() {
        guard let hostContent else { return }
        if let extra = hostSession?.entity(withNetworkID: extraID) { extra.removeFromParent(); hasExtra = false }
        else { hostContent.add(actor(extraID)); hasExtra = true }
        synchronizeHost()
    }
    func hostMove(_ step: Int) {
        patrol = false
        guard let entity = hostSession?.entity(withNetworkID: primaryID) else { return }
        move(entity, step: step); synchronizeHost()
    }
    private func synchronizeHost() {
        do { try hostSession?.synchronize() } catch { status = "Host synchronization failed: \(error)" }
    }
    func sendMove(_ step: Int, unauthorized: Bool = false) {
        patrol = false
        do {
            try clientSession?.sendCommand(JSONEncoder().encode(NetworkDemoMove(actor: unauthorized ? extraID : primaryID, step: step)))
            status = "Command sent reliably; waiting for host validation."
        } catch { status = "Command failed: \(error)" }
    }
    func offsetClientCamera() {
        clientCamera.position.x = clientCamera.position.x == 0 ? 45 : 0
        cameraX = clientCamera.position.x
    }
    private func move(_ entity: Entity, step: Int) { entity.position.x = min(140, max(-140, entity.position.x + Float(step) * 24)) }

    private func receive(_ event: NetworkEvents.CommandReceived, live: Bool) {
        let session = live ? liveSession : hostSession
        let commandTime = live ? ProcessInfo.processInfo.systemUptime : elapsed
        guard let session, session.isHost,
              session.peers.contains(where: { $0.id == event.sender }),
              let command = try? JSONDecoder().decode(NetworkDemoMove.self, from: event.data),
              command.actor == primaryID, (-1...1).contains(command.step), command.step != 0,
              let entity = session.entity(withNetworkID: command.actor), entity.isEnabled,
              entity.components[SynchronizationComponent.self]?.owner == event.sender,
              commandTime - (commandTimes[event.sender] ?? -1) >= 0.12 else {
            rejectedCommands += 1; status = "Host rejected command: ownership, actor, action, enabled state or rate check failed."
            return
        }
        commandTimes[event.sender] = commandTime
        move(entity, step: command.step)
        acceptedCommands += 1; status = "Host accepted authenticated sender and moved the actor."
        // Called inside NetworkSession.update: mutate only; its cadence captures next state.
    }

    func tick(_ delta: TimeInterval) {
        guard active else { return }
        elapsed += delta
        network.advance(by: delta) // Exactly one pump, from the host simulation phase.
        if patrol, let entity = hostSession?.entity(withNetworkID: primaryID), entity.isEnabled {
            entity.position = [sin(Float(elapsed) * 0.8) * 110, cos(Float(elapsed) * 0.6) * 45]
        }
        sampleElapsed += delta
        if sampleElapsed >= 0.1 {
            sampleElapsed = 0
            hostCount = hostContent?.world.allEntities.filter { $0.components.has(SynchronizationComponent.self) }.count ?? 0
            hostX = hostSession?.entity(withNetworkID: primaryID)?.position.x ?? 0
            clientX = clientSession?.entity(withNetworkID: primaryID)?.position.x ?? 0
            linkTime = network.currentTime; pendingPackets = network.pendingMessageCount
        }
    }

    private func startLive(_ content: GameViewContent) {
        guard liveSession == nil, let transport = multiplayer.transport, let hostID = multiplayer.hostPeerID else { return }
        do {
            let isHost = transport.localPeer.id == hostID
            if isHost { content.add(actor(primaryID, owner: transport.connectedPeers.first?.id)) }
            let measured = NetworkDemoTransport(transport); liveTraffic = measured
            let session = NetworkSession(world: content.world, transport: measured,
                role: isHost ? .host : .client(host: hostID), schema: try schema())
            liveSubscriptions = [content.subscribe(to: NetworkEvents.CommandReceived.self) { [weak self] event in self?.receive(event, live: true) }]
            try session.start(); liveSession = session
        } catch { status = "Live session failed: \(error)"; disconnectLive() }
    }
    func liveMove(_ step: Int) {
        guard let liveSession else { return }
        if liveSession.isHost {
            if let entity = liveSession.entity(withNetworkID: primaryID) { move(entity, step: step) }
            do { try liveSession.synchronize() } catch { status = "Live synchronization failed: \(error)" }
        } else {
            do { try liveSession.sendCommand(JSONEncoder().encode(NetworkDemoMove(actor: primaryID, step: step))) }
            catch { status = "Live command failed: \(error)" }
        }
    }
    func stopLiveSession() {
        liveSession?.stop(); liveSession = nil; liveTraffic = nil
        liveSubscriptions = []; liveContent = nil
    }
    func disconnectLive() { stopLiveSession(); multiplayer.disconnect() }
}
