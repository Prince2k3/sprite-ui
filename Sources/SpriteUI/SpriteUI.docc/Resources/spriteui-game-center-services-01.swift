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

@MainActor
struct ContentView: View {
    @State private var progress = PreviewProgressLab()

    var body: some View {
        ScrollView {
            ProgressPanel(model: progress).padding().buttonStyle(.bordered)
        }
        .onDisappear { progress.stop() }
    }
}
