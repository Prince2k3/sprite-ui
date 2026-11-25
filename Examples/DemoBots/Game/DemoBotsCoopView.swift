import Foundation
import Observation
import SpriteUI
import SwiftUI

/// A complete optional co-op round alongside the DemoBots campaign. Preview is explicit and account-free.
@MainActor public struct DemoBotsCoopView: View {
    @State private var game: DemoBotsCoopSession
    @State private var controls: CoopInput
    @State private var native = false
    @State private var surfaceRevision: UInt64 = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    /// Uses packaged DemoBots art when available; asset-free tutorial hosts can choose procedural fallback sprites.
    public init(usesArtwork: Bool = true) {
        let game = DemoBotsCoopSession(usesArtwork: usesArtwork)
        _game = State(initialValue: game); _controls = State(initialValue: CoopInput(game: game))
    }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("CO-OP DEBUG ARENA").font(.caption.bold()).foregroundStyle(.mint); Spacer(); Button("Close") { game.leave(); dismiss() } }
                Text("Two robots. One repair crew.").font(.title.bold())
                Text("An open-floor two-player round: move, cure four corrupted bots, and keep the shared score. The campaign and its checkpoints stay separate.").font(.footnote).foregroundStyle(.secondary)
                Toggle("Use live Game Center", isOn: $native).disabled(game.busy)
                Text("Round: \(game.phase) · \(game.secondsLeft)s · cured \(game.cured)/4 · score \(game.score)").font(.headline).accessibilityIdentifier("coop-round")
                Text(game.message).font(.caption).accessibilityIdentifier("coop-status")
                if native {
                    Button("Sign in to Game Center") { game.services.present(.signIn) }
                    TextField("Activity party code", text: $game.partyCode).textFieldStyle(.roundedBorder)
                    Text("Requires a signed app, two accounts, OS 26+, and the configured dev.spriteui.demobots.coop activity. Both players enter the same code; construction never authenticates.").font(.caption)
                    if !GameCenterActivities.isSupported { Text("Live activity parties need OS 26+. Local co-op remains available.").foregroundStyle(.orange) }
                }
                Button(native ? "Create or join co-op party" : "Start local co-op") { game.start() }.disabled(game.busy || game.services.party.isActive)
                if game.services.party.canStart { Button("Start prepared round") { game.startPreparedRound() } }
                if game.services.party.recoveryOffer != nil && game.phase != "playing" { Button("Accept host recovery offer") { game.acceptRecoveryOffer() }.disabled(game.busy) }
                GameView { content in game.buildDisplay(in: content) }
                    .id(ObjectIdentifier(game))
                    .frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 16))
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { game.resizeDisplay($0); controls.suspend(); surfaceRevision &+= 1 }
                HStack(alignment: .center) {
                    BotThumbstick(label: "MOVE", symbol: "arrow.up.and.down.and.arrow.left.and.right", tint: .white, isActive: game.canControl) { vector, _ in controls.move(vector) }.id(surfaceRevision)
                    Spacer()
                    VStack(spacing: 12) {
                        Button("Debug Beam", systemImage: "bolt.fill") { controls.fire() }.buttonStyle(.borderedProminent).tint(.cyan).disabled(!game.canControl).accessibilityIdentifier("coop-fire")
                        Text("Move: WASD / arrows / left stick\nFire: Space / gamepad south").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text("Confirmed beams: \(game.confirmedBeams) · pending actions: \(game.pendingActions) · corrections: \(game.corrections)").font(.caption.monospaced()).accessibilityIdentifier("coop-network")
                if !native {
                    Toggle("Teammate moves", isOn: $game.previewPartnerMoves)
                    Toggle("Teammate fires", isOn: $game.previewPartnerFires)
                    HStack { Text("Delay: \(Int(game.previewLatency * 1000)) ms one way"); Slider(value: $game.previewLatency, in: 0...0.3) }
                    HStack { Text("Unreliable loss: \(Int(game.previewLossRate * 100))%"); Slider(value: $game.previewLossRate, in: 0...0.8) }
                    Toggle("Vary packet delay", isOn: $game.previewJitter)
                    Text("Local queue: \(game.previewPendingPackets) packets · \(game.previewPendingBytes) B. Reliable lobby, recovery, and receipts do not drop.").font(.caption2.monospaced())
                }
                HStack {
                    Button("Save recovery point") { game.saveRecoveryPoint() }.disabled(!game.canControl || native && game.services.networkSession?.isHost != true)
                    Button("Interrupt") { controls.suspend(); game.interrupt() }.disabled(game.phase != "playing")
                }
                Button("Rejoin saved round") { controls.suspend(); game.rejoinSavedRound() }.disabled(game.busy || !(game.phase == "interrupted" || game.phase == "failed"))
                Button("Leave co-op") { controls.suspend(); game.leave() }
                ForEach(game.statistics, id: \.peerID) { value in
                    Text("\(value.peerID.rawValue): scope \(value.relevantEntities)/\(value.availableEntities) · entity \(value.replicationBytesSent) B · app \(value.applicationBytesSent) B · deferred \(value.deferredPublications)").font(.caption2.monospaced())
                }
                if native {
                    ForEach(game.services.activities.pendingRequests) { request in
                        Button("Accept co-op invitation") { game.acceptInvitation(request.id) }.disabled(game.busy || game.services.party.isActive)
                    }
                    GameCenterPartyView(services: game.services)
                }
            }.buttonStyle(.bordered).tint(.mint).padding().frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }.background(Color.black).preferredColorScheme(.dark)
        .gameCenter(game.services)
        .gameInput(controls.hub, isActive: scenePhase == .active && game.canControl && game.services.destination == nil)
        .onChange(of: game.canControl && game.services.destination == nil, initial: true) { _, active in controls.setActive(active && scenePhase == .active) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { controls.suspend() }; if phase == .background { game.interrupt() } }
        .onChange(of: native) { _, native in
            controls.suspend(); game.leave()
            let replacement = DemoBotsCoopSession(preview: !native, usesArtwork: game.usesArtwork)
            game = replacement; controls = CoopInput(game: replacement)
        }
        .onDisappear { controls.suspend(); game.leave() }
        .task {
            var last = Date()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                let now = Date(); game.advance(deltaTime: min(0.1, max(0, now.timeIntervalSince(last)))); last = now
            }
        }
    }
}

@MainActor @Observable final class CoopInput {
    static let moveAction = InputAction("coop-move", kind: .axis2D)
    static let fireAction = InputAction("coop-fire")
    static let touch = InputDevice.virtual("coop-touch")
    let hub = PlayerInputHub()
    let player: PlayerInputSession
    private weak var game: DemoBotsCoopSession?
    private var token: InputSubscription?
    private var devices: InputDeviceSubscription?
    init(game: DemoBotsCoopSession) {
        self.game = game
        let map = InputActionMap(name: "co-op", bindings: [
            .init(Self.moveAction, control: .key("w"), scale: [0, 1]), .init(Self.moveAction, control: .key("up"), scale: [0, 1]),
            .init(Self.moveAction, control: .key("s"), scale: [0, -1]), .init(Self.moveAction, control: .key("down"), scale: [0, -1]),
            .init(Self.moveAction, control: .key("a"), scale: [-1, 0]), .init(Self.moveAction, control: .key("left"), scale: [-1, 0]),
            .init(Self.moveAction, control: .key("d"), scale: [1, 0]), .init(Self.moveAction, control: .key("right"), scale: [1, 0]),
            .init(Self.moveAction, control: .gamepadAxis(.leftStick), deadZone: 0.15), .init(Self.moveAction, control: .virtual("move")),
            .init(Self.fireAction, control: .key("space")), .init(Self.fireAction, control: .gamepadButton(.south)), .init(Self.fireAction, control: .virtual("fire"))])
        player = hub.addPlayer(named: "Co-op player", contexts: [map])
        hub.connect(.init(id: Self.touch, name: "Co-op touch"))
        for device in [InputDevice.keyboard, .pointer, Self.touch] { try? hub.assign(device, to: player) }
        hub.submit([(.virtual("move"), .axis2D(.zero)), (.virtual("fire"), .button(false))], device: Self.touch)
        devices = hub.observe { [weak self] event in
            guard let self, case .connected(let info) = event, case .controller = info.id, self.hub.owner(of: info.id) == nil else { return }
            try? self.hub.assign(info.id, to: self.player)
        }
        token = player.input.observe { [weak self] event in
            guard let self else { return }
            if event.action == Self.moveAction { self.game?.move(self.player.input.value(for: Self.moveAction).vector) }
            if event.action == Self.fireAction, event.phase == .pressed { self.game?.fire() }
        }
        setActive(false)
    }
    isolated deinit { token?.cancel(); devices?.cancel() }
    func move(_ direction: SIMD2<Float>) { hub.submit([(.virtual("move"), .axis2D(direction))], device: Self.touch) }
    func fire() { hub.submit([(.virtual("fire"), .button(false))], device: Self.touch); hub.submit([(.virtual("fire"), .button(true))], device: Self.touch); hub.submit([(.virtual("fire"), .button(false))], device: Self.touch) }
    func setActive(_ active: Bool) { player.isEnabled = active; if !active { suspend() } }
    func suspend() { hub.cancelAll(); player.stopFeedback(); game?.move(.zero) }
}
