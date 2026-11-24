import SpriteUI
import SwiftUI
import Observation

@MainActor @Observable
final class PreviewProgressLab {
    let services = GameCenterServices.preview()
    var status = "Local memory only; no Apple account required"
    var isWorking = false
    @ObservationIgnored private var operation: Task<Void, Never>?

    var progress: Double {
        services.achievements.achievements.first { $0.identifier == "first-steps" }?.percentComplete ?? 0
    }
    var bestScore: Int? { services.leaderboards.lastResults?.localPlayerEntry?.score }

    func reportProgress() {
        run {
            _ = try await self.services.achievements.load()
            try await self.services.achievements.report(progress: min(100, self.progress + 25), for: "first-steps")
            self.status = "Local achievement progress updated"
        }
    }

    func submit(_ score: Int) {
        run {
            try await self.services.leaderboards.submit(score: score, to: "practice-score")
            _ = try await self.services.leaderboards.entries(for: "practice-score", range: 1...10)
            self.status = "Local highest score loaded; preview rank is always 1"
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        operation = Task { @MainActor in
            defer { self.isWorking = false; self.operation = nil }
            do { try await work() }
            catch { self.status = error.localizedDescription }
        }
    }

    func stop() { operation?.cancel() }
}

@MainActor
struct ProgressPanel: View {
    let model: PreviewProgressLab

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local achievements and scores").font(.headline)
            ProgressView(value: model.progress, total: 100)
            Text("Achievement: \(Int(model.progress))%")
            Text(model.bestScore.map { "Highest local score: \($0) · rank 1" } ?? "No score submitted")
            HStack {
                Button("Progress +25%") { model.reportProgress() }
                Button("Submit 120") { model.submit(120) }
                Button("Submit 80") { model.submit(80) }
            }
            .disabled(model.isWorking)
            Text(model.status).font(.caption)
        }
    }
}

// Application state: a versioned value, never an ECS world snapshot.
struct PracticeTurnState: Codable {
    var total: Int
}

@MainActor @Observable
final class PreviewTurnLab {
    let store: InMemoryTurnBasedStore
    let players: [NetworkPeer]
    let services: [GameCenterTurnBasedMatches]
    private(set) var selectedPlayer = 0
    private(set) var total = 0
    var status = "Create a local two-player match"
    var isWorking = false
    @ObservationIgnored private var matchID: String?
    @ObservationIgnored private var operation: Task<Void, Never>?

    init() {
        let sharedStore = InMemoryTurnBasedStore()
        store = sharedStore
        let a = NetworkPeer(id: .init(rawValue: "preview-a"), displayName: "Player A")
        let b = NetworkPeer(id: .init(rawValue: "preview-b"), displayName: "Player B")
        players = [a, b]
        services = [a, b].map {
            GameCenterTurnBasedMatches(mode: .preview(player: $0), previewStore: sharedStore)
        }
    }

    var service: GameCenterTurnBasedMatches { services[selectedPlayer] }
    var match: GameCenterTurnBasedMatch? { service.selectedMatch }
    var canAct: Bool { match?.localCanAct == true && !isWorking }

    func create() {
        run {
            self.selectedPlayer = 0
            let id = try self.store.createMatch(participants: self.players.map { Optional($0) })
            self.matchID = id
            let fresh = try await self.service.load(id: id)
            _ = try await self.service.save(PracticeTurnState(total: 0), in: fresh, version: 1)
            try await self.reload()
        }
    }

    func select(_ index: Int) {
        guard !isWorking else { return }
        selectedPlayer = index
        if matchID != nil { refresh() }
    }

    func refresh() { run { try await self.reload() } }

    func savePoint() {
        run {
            try await self.reload()
            guard let match = self.match else { throw GameCenterServiceError.notFound }
            _ = try await self.service.save(PracticeTurnState(total: self.total + 1), in: match, version: 1)
            try await self.reload()
        }
    }

    func pass() {
        run {
            try await self.reload()
            guard let match = self.match else { throw GameCenterServiceError.notFound }
            _ = try await self.service.endTurn(PracticeTurnState(total: self.total), in: match,
                nextParticipantSlots: [1 - self.selectedPlayer], version: 1)
            try await self.reload()
        }
    }

    func finish() {
        run {
            try await self.reload()
            guard let match = self.match else { throw GameCenterServiceError.notFound }
            // This cooperative practice game always ends tied.
            _ = try await self.service.finish(PracticeTurnState(total: self.total), in: match,
                outcomes: [0: .tied, 1: .tied], version: 1)
            try await self.reload()
        }
    }

    private func reload() async throws {
        guard let matchID else { throw GameCenterServiceError.notFound }
        let match = try await service.load(id: matchID)
        let value = try service.state(of: match, as: PracticeTurnState.self, version: 1)
        guard value.total >= 0 else { throw GameCenterServiceError.invalidData }
        total = value.total
        status = match.status == .ended ? "Ended · both participants tied" :
            "Current turn: \(match.currentPlayer?.displayName ?? "Waiting for a player")"
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        operation = Task { @MainActor in
            defer { self.isWorking = false; self.operation = nil }
            do { try await work() }
            catch { self.status = error.localizedDescription }
        }
    }

    func stop() { operation?.cancel() }
}

@MainActor
struct TurnPanel: View {
    let model: PreviewTurnLab

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local saved turns").font(.headline)
            Text("Viewing: \(model.players[model.selectedPlayer].displayName)")
            HStack {
                Button("View Player A") { model.select(0) }
                Button("View Player B") { model.select(1) }
            }.disabled(model.isWorking)
            Text("Saved total: \(model.total)")
            Text(model.status)
            HStack {
                Button("New local match") { model.create() }
                Button("Reload") { model.refresh() }.disabled(model.match == nil)
            }.disabled(model.isWorking)
            HStack {
                Button("Save +1 (keep turn)") { model.savePoint() }
                Button("Pass turn") { model.pass() }
                Button("Finish tied") { model.finish() }
            }.disabled(!model.canAct)
            Text("Both identities share one in-memory store. Reload explicitly; nothing reaches Apple.")
                .font(.caption)
        }
    }
}

@MainActor
struct OptionalNativePanel: View {
    @Environment(\.gameCenterServices) private var services

    var body: some View {
        if let services {
            VStack(alignment: .leading, spacing: 12) {
                Text("Optional native services").font(.headline)
                Text("These buttons use your signed app configuration. Opening this panel does not sign in.")
                GameCenterServicesView(services: services)
                Button("Disconnect real-time session") { services.disconnect() }
                Text("Signed two-account testing remains pending. The local lab above stays account-free.")
                    .font(.caption)
            }
        }
    }
}

@MainActor
struct ContentView: View {
    @State private var progress = PreviewProgressLab()
    @State private var turns = PreviewTurnLab()
    @State private var native = GameCenterServices(mode: .live)
    @State private var showNative = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ProgressPanel(model: progress)
                Divider()
                TurnPanel(model: turns)
                Divider()
                DisclosureGroup("Optional native Game Center", isExpanded: $showNative) {
                    OptionalNativePanel()
                }
            }.padding().buttonStyle(.bordered)
        }
        // Install once on a stable parent, not on every service button.
        .gameCenter(native)
        .onDisappear { progress.stop(); turns.stop() }
    }
}
