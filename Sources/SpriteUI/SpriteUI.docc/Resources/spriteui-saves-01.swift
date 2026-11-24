import Foundation
import Gameplay
import Observation
import SpriteUISaves
import SwiftUI

@MainActor struct ContentView: View {
    @State private var model = ProfilePractice()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("A saved player").font(.largeTitle.bold())
                Text("Local files · account-free preview").foregroundStyle(.secondary)
                if let profile = model.profile {
                    Text("Gold: \(profile.wallet.balance(for: "gold")) · Receipts: \(profile.state.quests.claims.count)")
                    Text("Quest events: \(profile.state.quests.events.count)")
                }
                Button("Open local profile") { model.open() }
                Button("Collect coin") { model.collect() }.disabled(model.profile == nil)
                Button("Claim 10 gold") { model.claim() }.disabled(model.profile == nil)
                Button("Reload") { model.reload() }.disabled(model.profile == nil)
                Divider()
                Button("Open offline cloud preview") { model.openPreview() }
                Button("Close preview") { model.cloud?.close() }
                Text("Preview: \(String(describing: model.cloud?.status ?? .closed))")
                Text(model.message).font(.footnote)
            }
            .disabled(model.isBusy).buttonStyle(.bordered).padding()
            .frame(maxWidth: 600, alignment: .leading)
        }.onDisappear { model.stop() }
    }
}

private struct PracticeProfileState: Codable, Sendable { var quests: QuestJournal }
@MainActor @Observable private final class ProfilePractice {
    var profile: PlayerProfile<PracticeProfileState>?
    var cloud: CloudSaveDirectory?
    var message = "Open a profile, collect two coins, then claim once."
    var isBusy = false
    @ObservationIgnored private var store: PlayerProfileStore<PracticeProfileState>?
    @ObservationIgnored private var task: Task<Void, Never>?
    private let slot = try! SaveSlotID("campaign") // Checked-in valid fixture ID.
    private func initial() throws -> PracticeProfileState {
        try PracticeProfileState(quests: QuestJournal(playerID: "practice", quests: [
            QuestDefinition(id: "first", title: "Two coins", objectives: [QuestObjective(id: "coins", metric: "coin", target: 2)],
                            rewards: [QuestReward("gold", amount: 10)])]))
    }
    func open() {
        run {
            let root = try ProfileSaveLocation.applicationSupport(appIdentifier: "com.example.spriteui.saves-tutorial")
            let store = try PlayerProfileStore<PracticeProfileState>(player: .guest("practice"), directory: root, schema: ProfileSaveSchema())
            do { self.profile = try await store.load(from: self.slot) }
            catch ProfileSaveError.slotNotFound { self.profile = try await store.create(in: self.slot, state: self.initial(), at: Date()) }
            self.store = store; self.message = "Local profile open. Existing progress was preserved."
        }
    }
    func collect() {
        run {
            guard let store = self.store, let profile = self.profile else { return }
            let date = Date(), id = UUID().uuidString
            self.profile = try await store.update(profile, at: date) {
                try $0.state.quests.record(QuestEvent(id: id, metric: "coin", at: date))
            }
            self.message = "Coin persisted."
        }
    }
    func claim() {
        run {
            guard let store = self.store, let profile = self.profile else { return }
            let date = Date()
            self.profile = try await store.update(profile, at: date) { try $0.claimQuestReward("first", in: \.quests, at: date) }
            self.message = "Receipt and gold committed together. Another claim will fail."
        }
    }
    func reload() {
        run {
            guard let store = self.store else { return }
            self.profile = try await store.load(from: self.slot); self.message = "Loaded the saved revision."
        }
    }
    func openPreview() {
        run {
            self.cloud?.close()
            let root = try ProfileSaveLocation.applicationSupport(appIdentifier: "com.example.spriteui.saves-tutorial")
                .appendingPathComponent("preview", isDirectory: true)
            let cloud = try CloudSaveDirectory.preview(directory: root, status: .offline)
            self.cloud = cloud; try await cloud.open()
            self.message = "Offline fixture ready. No Apple service contacted; the local profile was not copied into it."
        }
    }
    func stop() { task?.cancel(); task = nil; cloud?.close(); isBusy = false }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }; isBusy = true
        task = Task { @MainActor [weak self] in
            do { try await action(); try Task.checkCancellation() }
            catch { if !Task.isCancelled { self?.message = "Action failed: \(error)" } }
            if !Task.isCancelled { self?.isBusy = false }
        }
    }
}
