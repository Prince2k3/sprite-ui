import Foundation
import Observation
import SpriteUIGameCenter
import SwiftUI

/// Activity routing and challenge attempts with no account, invites, or remote writes.
@MainActor struct ContentView: View {
    @State private var lab = ActivityChallengesLab()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("ACTIVITIES LAB", systemImage: "person.2.wave.2").font(.caption.bold()).foregroundStyle(.orange)
                    Text("An invitation.\nYour game decides.").font(.largeTitle.bold())
                    Text("Local activity requests wait until you accept them. Scores stay staged until finish. Challenge reports keep every attempt, even below your best.")
                        .foregroundStyle(.secondary)
                    Text(lab.notice).font(.footnote).accessibilityIdentifier("social-services-status")
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    .background(.orange.opacity(0.10), in: .rect(cornerRadius: 22))

                Stepper("Round score: \(lab.score)", value: $lab.score, in: 0...200, step: 20).disabled(lab.isBusy)
                Button("Load social catalog") { lab.load() }.disabled(lab.isBusy)
                Text("Activities: \(lab.services.activities.definitions.count) · Challenges: \(lab.services.challenges.definitions.count)")
                    .font(.caption).foregroundStyle(.secondary)

                card("Incoming activity", symbol: "tray.and.arrow.down") {
                    Text("Queue before loading the catalog to simulate a cold launch. A current activity is never replaced.").font(.caption).foregroundStyle(.secondary)
                    Button("Queue activity request") { lab.queue() }.disabled(lab.isBusy)
                    ForEach(lab.services.activities.pendingRequests) { request in
                        Text("Score attack · \(request.activity.properties["level"] ?? "unknown")").bold()
                        HStack {
                            Button("Accept activity") { lab.accept(request) }.disabled(lab.isBusy || lab.isRunning)
                            Button("Decline activity") { lab.decline(request) }.disabled(lab.isBusy)
                        }
                    }
                    Text("Waiting requests: \(lab.services.activities.pendingRequests.count)").font(.caption)
                }

                card("Stage a round, then finish", symbol: "flag.checkered") {
                    if let activity = lab.services.activities.activity {
                        Text("Activity: \(activity.state.rawValue)").bold()
                        Text("Party code: \(activity.partyCode ?? "none")").font(.caption)
                        Text("Staged score: \(activity.scores["activity-score"]?.value ?? 0)").monospacedDigit()
                    } else { Text("No current activity.") }
                    ViewThatFits(in: .horizontal) {
                        HStack { activityControls }
                        VStack(alignment: .leading) { activityControls }
                    }
                    Text("Finished activity attempts: \(lab.services.activities.completedAttempts.count)").font(.caption)
                    ForEach(lab.services.activities.completedAttempts.suffix(3)) { completion in
                        Text("Completed round: \(completion.activity.scores["activity-score"]?.value ?? 0) points").font(.caption)
                    }
                    Text("The activity uses a separate practice board. Finishing it never also calls the direct challenge reporter below.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                card("Every challenge attempt counts", symbol: "trophy") {
                    ViewThatFits(in: .horizontal) {
                        HStack { challengeControls }
                        VStack(alignment: .leading) { challengeControls }
                    }
                    Text("Challenge reports: \(lab.services.challenges.attempts.count) · Local best: \(lab.best)").font(.headline)
                    ForEach(lab.services.challenges.attempts.suffix(3)) { attempt in
                        Text("\(attempt.score) points · \(attempt.status.rawValue)").font(.caption)
                    }
                    Text("Try 100, then 20. Both attempts stay in the local ledger while the preview best remains 100. Replaying the same report ID adds nothing.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Preview challenge options") { lab.services.present(.challengeDefinition("practice-sprint")) }
                }
            }
            .buttonStyle(.bordered).tint(.orange)
            .frame(maxWidth: 720, alignment: .leading).padding().frame(maxWidth: .infinity)
        }
        .navigationTitle("Activities & challenges")
        .gameCenter(lab.services)
        .onDisappear { lab.stop() }
    }
    @ViewBuilder private var activityControls: some View {
        Button("Start score attack") { lab.start() }.disabled(lab.isBusy || lab.isRunning || lab.services.activities.definitions.isEmpty)
        Button(lab.services.activities.activity?.state == .paused ? "Resume activity" : "Pause activity") { lab.togglePause() }.disabled(lab.isBusy || !lab.isRunning)
        Button("Stage activity score") { lab.stage() }.disabled(lab.isBusy || !lab.isRunning)
        Button("Finish activity") { lab.finish() }.disabled(lab.isBusy || !lab.isRunning)
        Button("Discard activity") { lab.discard() }.disabled(lab.isBusy || !lab.isRunning)
    }
    @ViewBuilder private var challengeControls: some View {
        Button("Report challenge attempt") { lab.report() }.disabled(lab.isBusy || lab.services.challenges.definitions.isEmpty)
        Button("Replay challenge report") { lab.replay() }.disabled(lab.isBusy || lab.services.challenges.attempts.isEmpty)
    }
    private func card<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) { Label(title, systemImage: symbol).font(.title3.bold()); content() }
            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(.secondary.opacity(0.08), in: .rect(cornerRadius: 22))
    }
}

@MainActor @Observable private final class ActivityChallengesLab {
    let services = GameCenterServices.preview()
    var score = 100
    var best = 0
    var notice = "No account needed. Queue an incoming activity or load the local catalog."
    var isBusy = false
    @ObservationIgnored private var task: Task<Void, Never>?
    var isRunning: Bool {
        guard let state = services.activities.activity?.state else { return false }
        return state == .active || state == .paused
    }
    init() {
        // Constant preview fixtures; no native GameKit definitions are loaded.
        try! services.activities.configurePreview([.init(id: "practice-score-attack", title: "Score attack",
            defaultProperties: ["level": "arena"], supportsPartyCode: true)])
        try! services.activities.configureRoutes(["practice-score-attack"])
        try! services.challenges.configurePreview([.init(id: "practice-sprint", title: "Sprint", leaderboardID: "challenge-score", isRepeatable: true)])
    }
    func load() {
        run { _ = try await self.services.activities.load(); _ = try await self.services.challenges.load(); self.notice = "Local catalogs loaded. Nothing sent to Apple." }
    }
    func queue() {
        apply {
            try services.activities.startListening()
            try services.activities.simulateIncomingActivity(definitionID: "practice-score-attack", properties: ["level": "arena"], partyCode: "1234-5678")
            notice = "Activity queued. Your current game has not changed."
        }
    }
    func accept(_ request: GameCenterActivityRequest) {
        apply {
            guard request.activity.definitionID == "practice-score-attack", request.activity.properties["level"] == "arena" else {
                try services.activities.decline(request: request.id); notice = "Unsupported activity declined."; return
            }
            // A real game also checks progression/content readiness before accepting and routing.
            try services.activities.accept(request: request.id); notice = "Accepted the arena activity explicitly."
        }
    }
    func decline(_ request: GameCenterActivityRequest) { apply { try services.activities.decline(request: request.id); notice = "Request declined." } }
    func start() {
        run { _ = try await self.services.activities.start(definitionID: "practice-score-attack", partyCode: "1234-5678"); self.notice = "New practice activity started." }
    }
    func togglePause() {
        apply { if services.activities.activity?.state == .paused { try services.activities.resume() } else { try services.activities.pause() } }
    }
    func stage() {
        run { try await self.services.activities.setScore(self.score, for: "activity-score"); self.notice = "Score staged. No activity attempt submitted yet." }
    }
    func finish() { apply { try services.activities.finish(); notice = "Activity ended once. The preview receipt retains its final score." } }
    func discard() { apply { try services.activities.discard(); notice = "Staged results discarded before ending." } }
    func report() {
        run {
            _ = try await self.services.challenges.submitAttempt(score: self.score, for: "practice-sprint", attemptID: UUID())
            self.best = try await self.services.leaderboards.entries(for: "challenge-score").localPlayerEntry?.score ?? 0
            self.notice = "Challenge attempt recorded, even if below the personal best."
        }
    }
    func replay() {
        run {
            guard let last = self.services.challenges.attempts.last else { return }
            _ = try await self.services.challenges.submitAttempt(score: last.score, for: last.challengeID, attemptID: last.id, context: last.context)
            self.notice = "Existing attempt ID recognized. No extra attempt was reported."
        }
    }
    func stop() { task?.cancel(); task = nil; services.shutdown(); isBusy = false }
    private func apply(_ work: () throws -> Void) { do { try work() } catch { notice = error.localizedDescription } }
    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }; isBusy = true
        task = Task { @MainActor [weak self] in
            do { try await work(); try Task.checkCancellation() }
            catch { if !Task.isCancelled { self?.notice = error.localizedDescription } }
            if !Task.isCancelled { self?.isBusy = false }
        }
    }
}
