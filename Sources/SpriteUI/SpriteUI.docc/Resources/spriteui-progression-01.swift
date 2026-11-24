import Foundation
import Observation
import SpriteUI
import SwiftUI

@MainActor
struct ContentView: View {
    @State private var model = PracticeProgression()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Quests & leagues").font(.largeTitle.bold())
                Text("Local practice · no account required").foregroundStyle(.secondary)
                if let progress = try? model.journal.progress(for: "collect", at: model.now) {
                    Text("Coins: \(progress.counts[0])/3 · \(progress.status.rawValue)")
                    ProgressView(value: progress.fractionCompleted)
                    Button("Collect coin") { model.collect() }
                    Button("Claim reward") { model.claim() }.disabled(progress.status != .completed)
                }
                Text("Reward receipts: \(model.journal.claims.count)")
                Divider()
                ForEach((try? model.season.standings(in: "bronze")) ?? []) { row in
                    Text("#\(row.rank) \(row.participant.displayName): \(row.score)")
                }
                Button("Alice +10 points") { model.score() }.disabled(model.season.closedAt != nil)
                Button("End practice season") { model.finish() }.disabled(model.season.closedAt != nil)
                ForEach(model.season.placements) { placement in
                    Text("\(placement.standing.participant.displayName) → \(placement.nextTierID)")
                }
                Divider()
                Button("Save in memory") { model.save() }
                Button("Restore in memory") { model.restore() }.disabled(model.saved == nil)
                Button("Report preview achievement") { model.report() }.disabled(model.isReporting)
                Text(model.message).font(.footnote)
            }
            .buttonStyle(.bordered).padding().frame(maxWidth: 600, alignment: .leading)
        }
        .onDisappear { model.stop() }
    }
}

@MainActor @Observable
private final class PracticeProgression {
    var journal: QuestJournal
    var season: LeagueSeason
    var now = Date(timeIntervalSince1970: 1_000)
    var saved: Data?
    var message = "Collect three coins, claim once, and score before ending the season."
    var isReporting = false
    @ObservationIgnored private let services = GameCenterServices.preview(player:
        .init(id: .init(rawValue: "alice"), displayName: "Alice"))
    @ObservationIgnored private var task: Task<Void, Never>?

    init() {
        // Constant tutorial definitions; production catalogs should surface validation errors.
        journal = try! QuestJournal(playerID: "alice", quests: [QuestDefinition(id: "collect", title: "Three coins",
            objectives: [QuestObjective(id: "coins", metric: "coin", target: 3)], rewards: [QuestReward("gold", amount: 5)])])
        season = try! LeagueSeason(id: "practice", title: "Practice",
            window: ProgressionWindow(start: now, end: now.addingTimeInterval(100)),
            tiers: [LeagueTier(id: "bronze", title: "Bronze"), LeagueTier(id: "silver", title: "Silver")],
            participants: [LeagueParticipant(id: "alice", displayName: "Alice", tierID: "bronze"),
                LeagueParticipant(id: "bob", displayName: "Bob", tierID: "bronze")],
            rules: LeagueRules(promotionPlaces: 1, demotionPlaces: 0))
    }

    func collect() {
        attempt {
            try journal.record(QuestEvent(id: UUID().uuidString, metric: "coin", at: now))
            message = "Coin recorded."
        }
    }
    func claim() {
        attempt {
            let receipt = try journal.claim("collect", at: now)
            message = "Claimed receipt \(receipt.id). No external wallet is modified."
        }
    }
    func score() {
        attempt {
            try season.record(LeagueResult(id: UUID().uuidString, scores: ["alice": 10], at: now))
            message = "Result recorded."
        }
    }
    func finish() {
        attempt { now = season.window.end; try season.finalize(at: now); message = "Placements finalized." }
    }
    private struct Save: Codable { let journal: QuestJournal; let season: LeagueSeason; let now: Date }
    func save() {
        attempt { saved = try JSONEncoder().encode(Save(journal: journal, season: season, now: now)); message = "Saved in memory." }
    }
    func restore() {
        attempt {
            guard let saved else { return }
            let copy = try JSONDecoder().decode(Save.self, from: saved)
            stop(); journal = copy.journal; season = copy.season; now = copy.now
            message = "Restored counts, receipts, results, and placements."
        }
    }
    func report() {
        guard !isReporting else { return }
        isReporting = true
        let journal = journal, now = now
        task = Task { @MainActor [weak self, services] in
            do {
                try await services.progression.report(journal, using: [.init(questID: "collect", achievementID: "coin-milestone")], at: now)
                try Task.checkCancellation()
                self?.message = "Preview achievement: \(Int(services.achievements.achievements.first?.percentComplete ?? 0))%. Nothing sent to Apple."
                self?.isReporting = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.message = "Reporting failed: \(error)"; self?.isReporting = false
            }
        }
    }
    func stop() { task?.cancel(); task = nil; isReporting = false; services.shutdown() }
    private func attempt(_ action: () throws -> Void) {
        do { try action() } catch { message = "Action failed: \(error)" }
    }
}
