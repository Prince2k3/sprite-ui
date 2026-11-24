import Foundation
import Observation
import SpriteUI
import SwiftUI

/// A local tutorial alongside the explicitly user-driven live Game Center menu.
@MainActor
struct GameServicesDemoView: View {
    @State private var live = GameCenterServices(mode: .live)
    @State private var lab = GameServicesPreviewLab()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    introduction
                    NavigationLink {
                        ProgressionDemoView()
                    } label: {
                        Label("Quests & leagues lab", systemImage: "flag.checkered")
                    }
                    .buttonStyle(.borderedProminent).tint(.mint)
                    NavigationLink {
                        ProfileSavesDemoView()
                    } label: {
                        Label("Player profiles & saves lab", systemImage: "externaldrive.badge.person.crop")
                    }
                    .buttonStyle(.bordered).tint(.cyan)
                    NavigationLink {
                        ActivityChallengesDemoView()
                    } label: {
                        Label("Activities & challenges lab", systemImage: "person.2.wave.2")
                    }
                    .buttonStyle(.bordered).tint(.orange)
                    NavigationLink {
                        PartyMatchmakingDemoView()
                    } label: {
                        Label("Party matchmaking lab", systemImage: "person.2.fill")
                    }
                    .buttonStyle(.bordered).tint(.cyan)
                    NavigationLink {
                        MultiplayerRecoveryDemoView()
                    } label: {
                        Label("Multiplayer recovery lab", systemImage: "arrow.clockwise.circle.fill")
                    }
                    .buttonStyle(.bordered).tint(.mint)
                    NavigationLink {
                        PredictionDemoView()
                    } label: {
                        Label("Prediction & reconciliation lab", systemImage: "bolt.horizontal.circle")
                    }
                    .buttonStyle(.bordered).tint(.cyan)
                    NavigationLink {
                        InteractionDemoView()
                    } label: {
                        Label("Interactions & lag compensation lab", systemImage: "scope")
                    }
                    .buttonStyle(.bordered).tint(.mint)
                    previewIdentity
                    turnBasedCard
                    achievementCard
                    leaderboardCard
                    liveCard
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding()
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Game services")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .gameCenter(live)
        .onDisappear { lab.shutdown() }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("BASICS LAB", systemImage: "gamecontroller.fill")
                .font(.caption.bold()).tracking(2).foregroundStyle(.mint)
            Text("One setup.\nA few great moves.")
                .font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
            Text("Pass a turn, earn an achievement, and post your best score. Every exercise below runs locally.")
                .foregroundStyle(.secondary)
            Label("No account needed · nothing sent to Apple", systemImage: "checkmark.shield")
                .font(.caption.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(.mint.opacity(0.10), in: .rect(cornerRadius: 24))
    }

    private var previewIdentity: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LOCAL PREVIEW").font(.caption.bold()).foregroundStyle(.secondary)
            Picker("Preview player", selection: $lab.player) {
                ForEach(GameServicesPreviewPlayer.allCases) { player in
                    Text(player.rawValue).tag(player)
                }
            }
            .pickerStyle(.segmented)
            .disabled(lab.isBusy)
            Text("You are \(lab.player.rawValue). Each player has their own saved view; refresh to see the other player’s move.")
                .font(.caption).foregroundStyle(.secondary)
            Label(lab.notice, systemImage: lab.noticeIsError ? "exclamationmark.circle" : "info.circle")
                .font(.footnote)
                .foregroundStyle(lab.noticeIsError ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("game-services-status")
        }
    }

    private var turnBasedCard: some View {
        GameServicesLessonCard(number: "01", title: "Take turns", symbol: "arrow.triangle.2.circlepath", color: .cyan) {
            Text("A tiny counter game: add one, then pass. Finish at three moves. Both identities share one in-memory match.")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(lab.counter.moves, format: .number)
                    .font(.system(size: 52, weight: .bold, design: .rounded)).monospacedDigit()
                Text("/ 3 moves").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if lab.isFinished {
                    Label("Finished", systemImage: "checkmark.seal.fill").foregroundStyle(.mint)
                }
            }
            ProgressView(value: Double(lab.counter.moves), total: 3).tint(.cyan)
            VStack(alignment: .leading, spacing: 6) {
                Text(lab.turnDescription).font(.headline)
                Text(lab.snapshotDescription).font(.caption).foregroundStyle(.secondary)
                if lab.isFinished {
                    ForEach(lab.snapshot?.participants ?? []) { participant in
                        Text("\(participant.player?.displayName ?? "Player"): \(String(describing: participant.outcome))")
                            .font(.subheadline)
                    }
                }
            }
            controls {
                Button(lab.hasMatch ? "New match" : "Start local match", action: lab.newMatch)
                Button("Refresh \(lab.player.rawValue)", action: lab.refresh)
                    .disabled(!lab.hasMatch)
                Button("Save +1", action: lab.saveMove).disabled(!lab.canAddMove)
                Button("Pass turn", action: lab.passTurn).disabled(!lab.canPassTurn)
                Button("Finish game", action: lab.finish).disabled(!lab.canFinish)
                Button("Try stale save", action: lab.proveStaleSave).disabled(!lab.canProveStaleSave)
            }
            if let proof = lab.staleProof {
                Label(proof, systemImage: "checkmark.shield.fill")
                    .font(.caption).foregroundStyle(.mint)
            }
            Text("Try it: Alice saves +1, tests a stale save, then passes. Switch to Bob and refresh. Repeat until three moves, then finish and refresh the other player.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var achievementCard: some View {
        GameServicesLessonCard(number: "02", title: "Make progress", symbol: "medal.fill", color: .orange) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("First steps").font(.headline)
                    Text("\(lab.player.rawValue)’s local achievement").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(lab.achievementProgress / 100, format: .percent.precision(.fractionLength(0)))
                    .font(.title2.bold()).monospacedDigit()
            }
            ProgressView(value: lab.achievementProgress, total: 100).tint(.orange)
            controls {
                Button("25%") { lab.reportProgress(25) }
                Button("50%") { lab.reportProgress(50) }
                Button("Unlock 100%", action: lab.unlock)
                Button("Load progress", action: lab.loadAchievements)
            }
            Text("Reports only move progress forward. Try 25% again after 50%. Unlock uses the same achievement at 100%.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var leaderboardCard: some View {
        GameServicesLessonCard(number: "03", title: "Beat your best", symbol: "trophy.fill", color: .purple) {
            Stepper(value: $lab.score, in: 0...10_000, step: 50) {
                Text("Score: \(lab.score)").font(.headline).monospacedDigit()
            }
            .disabled(lab.isBusy)
            controls {
                Button("Submit score", action: lab.submitScore)
                Button("Load scores", action: lab.loadScores)
            }
            if let results = lab.leaderboard {
                if results.entries.isEmpty {
                    Text("No score submitted for \(lab.player.rawValue) yet.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(results.entries) { entry in
                    HStack {
                        Text("#\(entry.rank)").font(.headline).foregroundStyle(.purple)
                        Text(entry.player.displayName)
                        Spacer()
                        Text(entry.formattedScore).bold().monospacedDigit()
                    }
                    .padding(12)
                    .background(.purple.opacity(0.08), in: .rect(cornerRadius: 12))
                }
                Text("Loaded players: \(results.totalPlayerCount) · Local best: \(results.localPlayerEntry?.formattedScore ?? "—")")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Submit, then load to inspect the result.").font(.subheadline).foregroundStyle(.secondary)
            }
            Text("Preview keeps only this player’s highest score, at local rank 1. Alice and Bob do not share a ranking; this is not a global leaderboard.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var liveCard: some View {
        GameServicesLessonCard(number: "04", title: "Open Game Center", symbol: "network", color: .green) {
            Label("LIVE · optional", systemImage: "person.crop.circle.badge.checkmark")
                .font(.caption.bold()).foregroundStyle(.green)
            Text("These buttons use Apple’s services and your Game Center account. Opening this tab never starts sign-in. Start with Setup help for a signed app and configured identifiers.")
                .font(.subheadline).foregroundStyle(.secondary)
            GameCenterServicesView(services: live)
            Text("Real-time matchmaking opens the native player flow. The Network tab demonstrates entity replication; this lab focuses on the service basics.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func controls<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8, content: content)
            VStack(alignment: .leading, spacing: 8, content: content)
        }
        .buttonStyle(.bordered)
        .disabled(lab.isBusy)
    }
}

private struct GameServicesLessonCard<Content: View>: View {
    let number: String
    let title: String
    let symbol: String
    let color: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: 42, height: 42)
                    .background(color.opacity(0.12), in: .rect(cornerRadius: 12))
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("LESSON \(number)").font(.caption2.bold()).foregroundStyle(.secondary)
                    Text(title).font(.title3.bold())
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.background, in: .rect(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(.primary.opacity(0.10)) }
    }
}

private enum GameServicesPreviewPlayer: String, CaseIterable, Identifiable {
    case alice = "Alice", bob = "Bob"
    var id: String { rawValue }
    var peer: NetworkPeer { .init(id: .init(rawValue: "lab-\(rawValue.lowercased())"), displayName: rawValue) }
    var other: Self { self == .alice ? .bob : .alice }
    var slot: Int { self == .alice ? 0 : 1 }
}

private struct GameServicesCounter: Codable {
    var moves = 0
}

/// The only asynchronous exercises use explicit preview services. The live
/// facade above is independent and is presented only by its built-in buttons.
@MainActor @Observable
private final class GameServicesPreviewLab {
    var player: GameServicesPreviewPlayer = .alice
    var score = 150
    private(set) var isBusy = false
    private(set) var notice = "Start a local match, or try an achievement or score."
    private(set) var noticeIsError = false
    private(set) var staleProof: String?
    private var snapshots: [GameServicesPreviewPlayer: GameCenterTurnBasedMatch] = [:]
    private var counters: [GameServicesPreviewPlayer: GameServicesCounter] = [:]
    private var achievements: [GameServicesPreviewPlayer: [GameCenterAchievement]] = [:]
    private var leaderboards: [GameServicesPreviewPlayer: GameCenterLeaderboardResults] = [:]
    private var staleSnapshots: [GameServicesPreviewPlayer: GameCenterTurnBasedMatch] = [:]
    private var matchID: String?
    private var latestRevision: String?
    @ObservationIgnored private var store: InMemoryTurnBasedStore
    @ObservationIgnored private var turnServices: [GameServicesPreviewPlayer: GameCenterTurnBasedMatches]
    @ObservationIgnored private let services: [GameServicesPreviewPlayer: GameCenterServices]
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    private let achievementID = "demo.first-steps"
    private let leaderboardID = "demo.high-score"

    init() {
        let store = InMemoryTurnBasedStore()
        self.store = store
        turnServices = Dictionary(uniqueKeysWithValues: GameServicesPreviewPlayer.allCases.map {
            ($0, GameCenterTurnBasedMatches(mode: .preview(player: $0.peer), previewStore: store))
        })
        services = Dictionary(uniqueKeysWithValues: GameServicesPreviewPlayer.allCases.map {
            ($0, GameCenterServices.preview(player: $0.peer))
        })
    }

    var snapshot: GameCenterTurnBasedMatch? { snapshots[player] }
    var counter: GameServicesCounter { counters[player] ?? .init() }
    var hasMatch: Bool { matchID != nil }
    var isFinished: Bool { snapshot?.status == .ended }
    var isFresh: Bool { snapshot != nil && snapshot?.revision == latestRevision }
    var canAddMove: Bool { isFresh && snapshot?.localCanAct == true && counter.moves < 3 }
    var canPassTurn: Bool { isFresh && snapshot?.localCanAct == true && counter.moves < 3 }
    var canFinish: Bool { isFresh && snapshot?.localCanAct == true && counter.moves == 3 }
    var canProveStaleSave: Bool { staleSnapshots[player] != nil && !isFinished }
    var achievementProgress: Double { achievements[player]?.first { $0.identifier == achievementID }?.percentComplete ?? 0 }
    var leaderboard: GameCenterLeaderboardResults? { leaderboards[player] }
    var turnDescription: String {
        guard let snapshot else { return "Alice + Bob · ready when you are" }
        if isFinished { return "Game over · final counter saved" }
        return "\(snapshot.currentPlayer?.displayName ?? "Waiting player")’s turn · viewing as \(player.rawValue)"
    }
    var snapshotDescription: String {
        guard hasMatch else { return "State is a small Codable counter, separate from an ECS world." }
        if !isFresh { return "This player’s snapshot is out of date. Refresh before acting." }
        if isFinished { return "Final snapshot · both participant outcomes were saved." }
        return snapshot?.localCanAct == true ? "Fresh snapshot · you can save or pass." : "Fresh snapshot · waiting for the other player."
    }

    func newMatch() {
        run { [self] in
            turnServices = [:] // Releasing the old services tears down their listeners.
            store = InMemoryTurnBasedStore()
            turnServices = Dictionary(uniqueKeysWithValues: GameServicesPreviewPlayer.allCases.map {
                ($0, GameCenterTurnBasedMatches(mode: .preview(player: $0.peer), previewStore: store))
            })
            snapshots = [:]; counters = [:]; staleSnapshots = [:]; staleProof = nil
            matchID = nil; latestRevision = nil; player = .alice
            let id = try store.createMatch(participants: [GameServicesPreviewPlayer.alice.peer, GameServicesPreviewPlayer.bob.peer])
            let alice = turnService(.alice)
            let initial = try await alice.load(id: id)
            let saved = try await alice.save(GameServicesCounter(), in: initial)
            matchID = id
            try receive(saved, for: .alice)
            try receive(try await turnService(.bob).load(id: id), for: .bob)
            notice = "Match ready. Alice starts. Save +1 to make the first move."
        }
    }

    func refresh() {
        run { [self] in
            guard let matchID else { return }
            try receive(try await turnService(player).load(id: matchID), for: player)
            notice = "\(player.rawValue) refreshed: \(counter.moves) moves, \(isFinished ? "game finished" : "current turn loaded")."
        }
    }

    func saveMove() {
        run { [self] in
            guard let snapshot, canAddMove else { return }
            var next = counter; next.moves += 1
            let saved = try await turnService(player).save(next, in: snapshot)
            staleSnapshots[player] = snapshot
            try receive(saved, for: player)
            notice = "\(player.rawValue) saved move \(next.moves). \(next.moves == 3 ? "Finish the game to record the outcomes." : "Try a stale save, then pass the turn.")"
        }
    }

    func passTurn() {
        run { [self] in
            guard let snapshot, canPassTurn else { return }
            let next = player.other
            let passed = try await turnService(player).endTurn(counter, in: snapshot, nextParticipantSlots: [next.slot])
            staleSnapshots[player] = snapshot
            try receive(passed, for: player)
            notice = "Turn passed to \(next.rawValue). Switch to \(next.rawValue), then refresh their saved view."
        }
    }

    func finish() {
        run { [self] in
            guard let snapshot, canFinish else { return }
            let finished = try await turnService(player).finish(counter, in: snapshot,
                outcomes: [player.slot: .won, player.other.slot: .lost])
            try receive(finished, for: player)
            notice = "\(player.rawValue) made the final move and won. Switch players and refresh to see the finished state."
        }
    }

    func proveStaleSave() {
        run { [self] in
            guard let old = staleSnapshots[player] else { return }
            do {
                _ = try await turnService(player).save(counter, in: old)
                throw GameCenterServiceError.gameCenter("Unexpected result: the stale save was accepted.")
            } catch GameCenterServiceError.staleMatch {
                staleProof = "Stale save rejected. The newer counter was preserved."
                notice = "Expected rejection: the old revision cannot overwrite a newer save."
            }
        }
    }

    func reportProgress(_ progress: Double) {
        run { [self] in
            let service = previewService(player).achievements
            try await service.report(progress: progress, for: achievementID)
            achievements[player] = try await service.load()
            notice = "\(player.rawValue)’s achievement progress loaded after reporting \(Int(progress))%."
        }
    }

    func unlock() {
        run { [self] in
            let service = previewService(player).achievements
            try await service.unlock(achievementID)
            achievements[player] = try await service.load()
            notice = "First steps unlocked for \(player.rawValue), locally."
        }
    }

    func loadAchievements() {
        run { [self] in
            achievements[player] = try await previewService(player).achievements.load()
            notice = "Loaded \(player.rawValue)’s local achievement progress."
        }
    }

    func submitScore() {
        run { [self] in
            try await previewService(player).leaderboards.submit(score: score, to: leaderboardID, context: UInt64(counter.moves))
            leaderboards[player] = nil
            notice = "Submitted \(score) for \(player.rawValue). Load scores to see their highest local score."
        }
    }

    func loadScores() {
        run { [self] in
            leaderboards[player] = try await previewService(player).leaderboards.entries(for: leaderboardID, range: 1...25)
            notice = "Loaded only \(player.rawValue)’s local ranking. No global players are simulated."
        }
    }

    func shutdown() {
        generation = UUID(); work?.cancel(); work = nil; isBusy = false
        turnServices = [:]
        services.values.forEach { $0.shutdown() }
        snapshots = [:]; counters = [:]; staleSnapshots = [:]; achievements = [:]; leaderboards = [:]
        matchID = nil; latestRevision = nil; staleProof = nil
        notice = "Start a local match, or try an achievement or score."
        noticeIsError = false
    }

    private func turnService(_ player: GameServicesPreviewPlayer) -> GameCenterTurnBasedMatches {
        turnServices[player]!
    }

    private func previewService(_ player: GameServicesPreviewPlayer) -> GameCenterServices {
        services[player]!
    }

    private func receive(_ match: GameCenterTurnBasedMatch, for player: GameServicesPreviewPlayer) throws {
        let state = try turnService(player).state(of: match, as: GameServicesCounter.self)
        snapshots[player] = match; counters[player] = state; latestRevision = match.revision
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true; noticeIsError = false
        let token = generation
        work = Task { [weak self] in
            guard let self else { return }
            defer {
                if token == self.generation { self.isBusy = false; self.work = nil }
            }
            do {
                try Task.checkCancellation()
                try await operation()
            } catch {
                guard token == self.generation, !Task.isCancelled else { return }
                self.notice = error.localizedDescription
                self.noticeIsError = true
            }
        }
    }
}
