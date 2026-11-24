import SwiftUI

/// A small, explicit programmatic matchmaking flow. Present it in a sheet;
/// observe service.selectedMatch to open your game's own turn interface.
/// Merely showing this view never authenticates or initiates matchmaking.
@MainActor
public struct GameCenterTurnBasedMatchmakingView: View {
    private let service: GameCenterTurnBasedMatches
    private let request: GameCenterMatchRequest
    @State private var operation: Task<Void, Never>?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    public init(service: GameCenterTurnBasedMatches, request: GameCenterMatchRequest = .init()) {
        self.service = service; self.request = request
    }

    public var body: some View {
        VStack(spacing: 16) {
            Text("Turn-Based Matches").font(.headline)
            if operation != nil {
                ProgressView("Finding a match…")
                Button("Cancel") { operation?.cancel() }
            } else {
                Text("Start a saved match and take turns when you're ready.")
                Button("Refresh saved games") {
                    run { _ = try await service.list() }
                }.disabled(service.isLoading)
                if !service.matches.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(service.matches) { match in
                                Button {
                                    run { _ = try await service.load(id: match.id) }
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(match.status == .ended ? "Finished game" : match.localCanAct ? "Your turn" : "Waiting for a turn")
                                        Text(match.id).font(.caption.monospaced()).lineLimit(1)
                                    }
                                }.disabled(service.isLoading)
                            }
                        }
                    }.frame(maxHeight: 240)
                }
                Button("Find Match") {
                    run { _ = try await service.findMatch(request) }
                }
                .disabled(service.isLoading)
            }
            if let error { Text(error).foregroundStyle(.secondary) }
            if let match = service.selectedMatch {
                Text(match.status == .ended ? "Match finished" : match.localCanAct ? "Your turn" : "Waiting for the next turn")
                    .font(.subheadline)
            }
            Button("Done") { dismiss() }
        }
        .padding()
        .onDisappear { operation?.cancel() }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard operation == nil else { return }
        error = nil
        operation = Task { @MainActor in
            defer { operation = nil }
            do { try await work() }
            catch is CancellationError { }
            catch GameCenterServiceError.cancelled { }
            catch { self.error = error.localizedDescription }
        }
    }
}
