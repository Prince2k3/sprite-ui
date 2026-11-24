import Foundation
import Observation
import SpriteUI
import SwiftUI

/// Local quest receipts, season placement, persistence, and opt-in preview reporting.
@MainActor
struct ProgressionDemoView: View {
    @State private var lab = ProgressionLab()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("PROGRESSION LAB", systemImage: "flag.checkered").font(.caption.bold()).foregroundStyle(.mint)
                    Text("Small goals.\nA season to grow.").font(.largeTitle.bold())
                    Text("Alice’s local quests and a three-player practice league. No account, server, or Apple sign-in is used.")
                        .foregroundStyle(.secondary)
                    Text(lab.notice).font(.footnote).accessibilityIdentifier("progression-status")
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                .background(.mint.opacity(0.1), in: .rect(cornerRadius: 22))

                section("Quests", symbol: "checklist") {
                    ForEach(lab.journal.quests) { quest in
                        if let progress = try? lab.journal.progress(for: quest.id, at: lab.clock) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text(quest.title).bold(); Spacer(); Text(progress.status.rawValue.capitalized).font(.caption) }
                                ProgressView(value: progress.fractionCompleted)
                                Text(zip(progress.counts, quest.objectives).map { "\($0.0)/\($0.1.target) \($0.1.metric)" }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                                if progress.status == .completed {
                                    Button("Claim \(quest.title)") { lab.claim(quest.id) }
                                }
                            }.padding(.vertical, 5)
                        }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack { questControls }
                        VStack(alignment: .leading) { questControls }
                    }
                    Text("Claimed gold: \(lab.gold) · Receipts: \(lab.journal.claims.count) · Entity events: \(lab.eventCount)")
                        .font(.caption)
                    Text("Collect five coins to unlock the win quest. The daily quest expires when the practice clock advances. Replaying the last event changes nothing.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                section("Practice league · Silver", symbol: "trophy") {
                    ForEach((try? lab.league.standings(in: "silver")) ?? []) { row in
                        HStack {
                            Text("#\(row.rank)").monospacedDigit().foregroundStyle(.secondary)
                            Text(row.participant.displayName).bold()
                            Spacer()
                            Text("\(row.score) pt").monospacedDigit()
                            if let placement = lab.league.placements.first(where: { $0.id == row.id }) {
                                Text("→ \(placement.nextTierID.capitalized)").font(.caption).foregroundStyle(.mint)
                            }
                        }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack { leagueControls }
                        VStack(alignment: .leading) { leagueControls }
                    }
                    Text(lab.league.closedAt == nil ? "Season open · promotion: top one · demotion: bottom one" : "Season closed · placements saved")
                        .font(.caption)
                    Text("Ties share a rank. A tied group crossing a promotion or demotion cutoff stays together in Silver.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                section("Keep it and report it", symbol: "square.and.arrow.down") {
                    ViewThatFits(in: .horizontal) {
                        HStack { saveControls }
                        VStack(alignment: .leading) { saveControls }
                    }
                    Button("Report to preview Game Center") { lab.report() }.disabled(lab.isReporting)
                    Text(lab.reportSummary).font(.caption).foregroundStyle(.secondary)
                    Text("Save writes a local file. Reset starts a fresh practice run; Load restores quests, reward receipts, result IDs, and placements. Preview reports are separate and do not grant rewards.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.bordered).tint(.mint)
            .frame(maxWidth: 720, alignment: .leading).padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Quests & leagues")
        .onDisappear { lab.stopReporting() }
    }

    @ViewBuilder private var questControls: some View {
        Button("Collect coin") { lab.record(metric: "coin") }
        Button("Win round") { lab.record(metric: "win") }
        Button("Replay event") { lab.replayEvent() }.disabled(lab.lastEvent == nil)
    }
    @ViewBuilder private var leagueControls: some View {
        Button("Alice +10") { lab.score("alice", 10) }.disabled(lab.league.closedAt != nil)
        Button("Bob +10") { lab.score("bob", 10) }.disabled(lab.league.closedAt != nil)
        Button("Close season") { lab.closeSeason() }.disabled(lab.league.closedAt != nil)
    }
    @ViewBuilder private var saveControls: some View {
        Button("Save progress") { lab.save() }
        Button("Load progress") { lab.load() }.disabled(!lab.hasSave)
        Button("Reset practice") { lab.reset() }
    }
    private func section<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol).font(.title3.bold())
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        .background(.secondary.opacity(0.08), in: .rect(cornerRadius: 22))
    }
}

@MainActor @Observable
private final class ProgressionLab {
    var journal: QuestJournal
    var league: LeagueSeason
    var clock: Date
    var lastEvent: QuestEvent?
    var eventCount = 0
    var notice = "Collect coins, claim a reward, then finish the practice season."
    var hasSave = false
    var isReporting = false
    var reportSummary = "No reports yet. Preview scores include Alice only; the custom league roster stays local."
    @ObservationIgnored private let world = World()
    @ObservationIgnored private let player = Entity(name: "quest-player")
    @ObservationIgnored private let services = GameCenterServices.preview(player: .init(id: .init(rawValue: "alice"), displayName: "Alice"))
    @ObservationIgnored private var subscription: EventSubscription?
    @ObservationIgnored private var task: Task<Void, Never>?
    private static let start = Date(timeIntervalSince1970: 2_000_000)
    private var saveURL: URL { URL.documentsDirectory.appending(path: "spriteui-progression-practice.json") }
    var gold: Int { journal.claims.flatMap(\.rewards).filter { $0.identifier == "gold" }.reduce(0) { $0 + $1.amount } }

    init() {
        // These immutable, checked-in fixtures use constant valid IDs and values.
        journal = try! Self.makeJournal()
        league = try! Self.makeLeague()
        clock = Self.start
        player.components.set(QuestJournalComponent(journal)); world.addEntity(player)
        subscription = world.subscribe(to: QuestEvents.Recorded.self, on: player) { [weak self] _ in self?.eventCount += 1 }
        hasSave = FileManager.default.fileExists(atPath: saveURL.path)
    }

    private static func makeJournal() throws -> QuestJournal {
        try QuestJournal(playerID: "alice", quests: [
            QuestDefinition(id: "collect", title: "Five coins", objectives: [QuestObjective(id: "coins", metric: "coin", target: 5)], rewards: [QuestReward("gold", amount: 25)]),
            QuestDefinition(id: "win", title: "First victory", objectives: [QuestObjective(id: "wins", metric: "win", target: 1)], prerequisites: ["collect"], rewards: [QuestReward("badge")]),
            QuestDefinition(id: "daily-1", title: "Daily three", objectives: [QuestObjective(id: "coins", metric: "coin", target: 3)],
                window: ProgressionWindow(start: start, end: start.addingTimeInterval(50)), rewards: [QuestReward("gold", amount: 10)])])
    }
    private static func makeLeague() throws -> LeagueSeason {
        try LeagueSeason(id: "practice-1", title: "Practice season", window: ProgressionWindow(start: start, end: start.addingTimeInterval(100)),
            tiers: [LeagueTier(id: "bronze", title: "Bronze"), LeagueTier(id: "silver", title: "Silver"), LeagueTier(id: "gold", title: "Gold")],
            participants: [LeagueParticipant(id: "alice", displayName: "Alice", tierID: "silver"), LeagueParticipant(id: "bob", displayName: "Bob", tierID: "silver"),
                LeagueParticipant(id: "casey", displayName: "Casey", tierID: "silver")], rules: LeagueRules())
    }

    func record(metric: String) {
        perform {
            let event = try QuestEvent(id: UUID().uuidString, metric: metric, at: clock)
            let completed = try player.recordQuestEvent(event)
            journal = player.components[QuestJournalComponent.self]!.journal; lastEvent = event
            notice = completed.isEmpty ? "Recorded \(metric)." : "Completed: \(completed.joined(separator: ", ")). Claim your rewards."
        }
    }
    func replayEvent() {
        perform {
            guard let event = lastEvent else { return }
            try player.recordQuestEvent(event)
            journal = player.components[QuestJournalComponent.self]!.journal
            notice = "Duplicate event ignored. Counts and entity events did not change."
        }
    }
    func claim(_ id: String) {
        perform {
            try player.claimQuestReward(id, at: clock)
            journal = player.components[QuestJournalComponent.self]!.journal
            notice = "Reward receipt saved. Claimed gold: \(gold)."
        }
    }
    func score(_ id: String, _ amount: Int) {
        perform {
            try league.record(LeagueResult(id: UUID().uuidString, scores: [id: amount], at: clock))
            notice = "Recorded \(id.capitalized)’s result."
        }
    }
    func closeSeason() {
        perform {
            clock = league.window.end
            try league.finalize(at: clock)
            notice = "Season closed. Whole tied groups remain together; the daily quest has expired if unfinished."
        }
    }
    private struct Save: Codable {
        var version = 1
        let journal: QuestJournal
        let league: LeagueSeason
        let clock: Date
    }
    func save() {
        perform {
            try JSONEncoder().encode(Save(journal: journal, league: league, clock: clock)).write(to: saveURL, options: .atomic)
            hasSave = true; notice = "Saved quest receipts and league progress to this device."
        }
    }
    func load() {
        perform {
            let save = try JSONDecoder().decode(Save.self, from: Data(contentsOf: saveURL))
            guard save.version == 1, save.journal.playerID == "alice", save.clock.timeIntervalSinceReferenceDate.isFinite else { throw ProgressionError.invalidSave }
            stopReporting(); journal = save.journal; league = save.league; clock = save.clock
            player.components.set(QuestJournalComponent(journal)); lastEvent = nil
            reportSummary = "Preview reports cleared. Report restored progress explicitly when ready."
            notice = "Loaded \(journal.claims.count) receipts and \(league.results.count) league results."
        }
    }
    func reset() {
        perform {
            stopReporting(); journal = try Self.makeJournal(); league = try Self.makeLeague(); clock = Self.start
            player.components.set(QuestJournalComponent(journal)); lastEvent = nil; eventCount = 0
            reportSummary = "No reports yet."; notice = "Fresh practice run. Your saved file is still available."
        }
    }
    func report() {
        guard !isReporting else { return }
        isReporting = true
        let journal = journal, league = league, now = clock
        task = Task { @MainActor [weak self, services] in
            do {
                try await services.progression.report(journal, using: [.init(questID: "collect", achievementID: "practice-coins")], at: now)
                if league.closedAt == nil {
                    try await services.progression.submit(league, using: .init(seasonID: league.id, leaderboardID: "practice-season"), at: now)
                }
                try Task.checkCancellation()
                let percent = services.achievements.achievements.first?.percentComplete ?? 0
                self?.reportSummary = "Preview achievement: \(Int(percent))%. Alice’s local points: \(league.score(for: "alice") ?? 0). \(league.closedAt == nil ? "Score submitted." : "Closed season was not submitted.")"
                self?.isReporting = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.notice = "Reporting failed: \(error)"; self?.isReporting = false
            }
        }
    }
    func stopReporting() { task?.cancel(); task = nil; services.shutdown(); isReporting = false }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { notice = "Could not apply action: \(error)" }
    }
}
