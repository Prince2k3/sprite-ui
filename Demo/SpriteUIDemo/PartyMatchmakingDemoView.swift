import Foundation
import Observation
import SpriteUI
import SwiftUI

/// Two independent preview players, one explicitly prepared game per player, and the production lobby protocol.
@MainActor struct PartyMatchmakingDemoView: View {
    @State private var model = PartyPractice()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("PARTY HANDOFF LAB", systemImage: "person.2.fill").font(.caption.bold()).foregroundStyle(.cyan)
                    Text("Keep your game.\nJoin when everyone is ready.").font(.largeTitle.bold())
                    Text("Two local identities share one party fixture. Each prepares a separate world. Only the host can commit the handoff after both players are ready.")
                        .foregroundStyle(.secondary)
                    Text(model.message).font(.footnote).accessibilityIdentifier("party-lab-status")
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.cyan.opacity(0.1), in: .rect(cornerRadius: 22))
                VStack(alignment: .leading, spacing: 10) {
                    Label("Original campaign", systemImage: "house.fill").font(.headline)
                    Text("Campaign coins: \(model.campaignCoins)")
                    Button("Collect campaign coin") { model.campaignCoins += 1 }
                    Text("This app-owned campaign is retained throughout the lobby and handoff.").font(.caption).foregroundStyle(.secondary)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.secondary.opacity(0.08), in: .rect(cornerRadius: 22))
                Button("Create preview party") { model.create() }.disabled(model.busy || model.a.party.isActive || model.b.party.isActive)
                Toggle("Prepare Bob with a different level version", isOn: $model.mismatch).disabled(model.busy || model.a.party.state == .starting || model.a.party.state == .playing)
                participant(model.a, first: true)
                participant(model.b, first: false)
                if model.a.party.state == .playing && model.b.party.state == .playing {
                    Label("Handoff complete", systemImage: "checkmark.circle.fill").font(.title2).foregroundStyle(.mint)
                    Text("Both prepared worlds are attached. Move the host actor and watch the client replica follow.").font(.caption)
                    HStack { arena("Alice · host", positions: model.hostPositions); arena("Bob · replica", positions: model.clientPositions) }
                    Button("Move host actor") { model.moveActor() }
                    Text("Client replicas: \(model.b.networkSession?.replicatedEntityCount ?? 0)").font(.caption)
                }
                Button("Leave both parties") { model.leave() }
                Text("No Apple account, invitations, or remote score reports. The fixture clock delivers lobby and replication packets; it does not emulate a Game Center server.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: 740, alignment: .leading).padding().frame(maxWidth: .infinity)
        }
        .navigationTitle("Party matchmaking")
        .buttonStyle(.bordered).tint(.cyan)
        .gameCenter(model.a)
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                model.tick()
            }
        }
        .onDisappear { model.stop() }
    }
    private func participant(_ services: GameCenterServices, first: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(first ? "Alice · player one" : "Bob · player two").font(.title2.bold())
            Button(first ? "Prepare Alice's arena" : "Prepare Bob's arena") { model.prepare(first: first) }
                .disabled(services.party.state != .lobby)
            GameCenterPartyView(services: services)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.secondary.opacity(0.08), in: .rect(cornerRadius: 22))
    }
    private func arena(_ title: String, positions: [SIMD2<Float>]) -> some View {
        VStack {
            Text(title).font(.caption)
            Canvas { context, size in
                for point in positions {
                    let rect = CGRect(x: size.width * CGFloat(point.x / 240 + 0.5) - 8, y: size.height / 2 - 8, width: 16, height: 16)
                    context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(.cyan))
                }
            }.frame(height: 100).background(.black.opacity(0.4), in: .rect(cornerRadius: 12))
        }.frame(maxWidth: .infinity)
    }
}

@MainActor @Observable private final class PartyPractice {
    let a = GameCenterServices.preview(player: .init(id: .init(rawValue: "party-alice"), displayName: "Alice"))
    let b = GameCenterServices.preview(player: .init(id: .init(rawValue: "party-bob"), displayName: "Bob"))
    var campaignCoins = 7
    var mismatch = false
    var message = "Create a party, prepare both arenas, then ready each player."
    var busy = false
    var hostPositions: [SIMD2<Float>] = []
    var clientPositions: [SIMD2<Float>] = []
    @ObservationIgnored private let firstWorld = World()
    @ObservationIgnored private let secondWorld = World()
    @ObservationIgnored private var fixture: GameCenterPartyPreview?
    @ObservationIgnored private var task: Task<Void, Never>?
    init() {
        for services in [a, b] {
            try! services.activities.configurePreview([.init(id: "party-arena", title: "Party arena", defaultProperties: ["level": "arena"], supportsPartyCode: true)])
        }
    }
    func create() {
        guard !busy else { return }; busy = true
        task = Task { @MainActor in
            defer { if !Task.isCancelled { busy = false; task = nil } }
            do {
                let fixture = try GameCenterPartyPreview(players: [a.localPlayer!, b.localPlayer!]); self.fixture = fixture
                for services in [a, b] {
                    try services.party.configurePreview(fixture)
                    _ = try await services.activities.load()
                    if services.activities.activity?.state == .active || services.activities.activity?.state == .paused { try services.activities.discard() }
                    _ = try await services.activities.start(definitionID: "party-arena", partyCode: "1234-5678")
                }
                async let first: Void = a.party.findMatch()
                async let second: Void = b.party.findMatch()
                _ = try await (first, second); try Task.checkCancellation()
                message = "Fixed roster connected. The campaign has not changed. Prepare each player's world."
            } catch { if !Task.isCancelled { message = error.localizedDescription; a.party.leave(); b.party.leave() } }
        }
    }
    func prepare(first: Bool) {
        do {
            let world = first ? firstWorld : secondWorld
            for entity in world.entities { entity.removeFromParent() }
            if first { world.addEntity(Entity(name: "party-actor", components: SynchronizationComponent())) }
            try (first ? a : b).party.prepare(in: world, compatibilityID: !first && mismatch ? "arena-v2" : "arena-v1")
            message = "Prepared \(first ? "Alice" : "Bob"). Mark ready separately. Different level versions prevent start."
        } catch { message = error.localizedDescription }
    }
    func moveActor() {
        guard a.party.state == .playing, let entity = firstWorld.entities.first else { return }
        entity.position.x = entity.position.x >= 90 ? -90 : entity.position.x + 30
    }
    func tick() {
        fixture?.advance(by: 0.1)
        firstWorld.update(deltaTime: 0.1); secondWorld.update(deltaTime: 0.1)
        let host = firstWorld.entities.map(\.position), client = secondWorld.entities.map(\.position)
        if host != hostPositions { hostPositions = host }; if client != clientPositions { clientPositions = client }
    }
    func leave() { a.party.leave(); b.party.leave(); message = "Parties left. Campaign coins and activities were not submitted or reset." }
    func stop() { task?.cancel(); task = nil; busy = false; a.shutdown(); b.shutdown(); fixture = nil }
}
