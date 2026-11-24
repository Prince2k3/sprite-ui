import SwiftUI

/// Explicit catalog loading and native activity creation entry points. Incoming gameplay routing remains application-owned.
@MainActor public struct GameCenterActivitiesView: View {
    private let services: GameCenterServices
    @State private var task: Task<Void, Never>?
    @State private var error: String?
    /// Creates a catalog menu without loading definitions or starting an activity.
    public init(services: GameCenterServices) { self.services = services }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Activities").font(.title2.bold())
                Button("Load activities") {
                    guard task == nil else { return }
                    task = Task { @MainActor in
                        defer { task = nil }
                        do { _ = try await services.activities.load(); error = nil }
                        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                    }
                }.disabled(services.activities.isLoading)
                ForEach(services.activities.definitions) { definition in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(definition.title).font(.headline)
                        if let details = definition.details { Text(details).font(.caption) }
                        Button("Open activity options") { services.present(.activityDefinition(definition.id)) }
                    }
                }
                if !services.activities.pendingRequests.isEmpty { Text("An activity is waiting. Return to the game to continue.").font(.footnote) }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                Button("Done") { services.dismiss() }
            }.padding()
        }.onDisappear { task?.cancel(); task = nil }
    }
}

/// Explicit challenge catalog and native friend-challenge creation entry points.
@MainActor public struct GameCenterChallengesView: View {
    private let services: GameCenterServices
    @State private var task: Task<Void, Never>?
    @State private var error: String?
    /// Creates a menu without loading metadata, submitting scores, or presenting native UI.
    public init(services: GameCenterServices) { self.services = services }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Challenges").font(.title2.bold())
                Button("Load challenges") {
                    guard task == nil else { return }
                    task = Task { @MainActor in
                        defer { task = nil }
                        do { _ = try await services.challenges.load(); error = nil }
                        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                    }
                }.disabled(services.challenges.isLoading)
                Button("Browse Game Center challenges") { services.present(.challengeOverview) }
                ForEach(services.challenges.definitions) { definition in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(definition.title).font(.headline)
                        if let details = definition.details { Text(details).font(.caption) }
                        Text(definition.isRepeatable ? "Repeatable challenge" : "One attempt per challenge").font(.caption)
                        Button("Create challenge") { services.present(.challengeDefinition(definition.id)) }
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                Button("Done") { services.dismiss() }
            }.padding()
        }.onDisappear { task?.cancel(); task = nil }
    }
}
