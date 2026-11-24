import Foundation
import Observation
import SpriteUI
import SwiftUI

/// Durable local profiles and an explicitly account-free two-device conflict exercise.
@MainActor
struct ProfileSavesDemoView: View {
    @State private var lab = ProfileSavesLab()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("SAVES LAB", systemImage: "externaldrive.badge.person.crop").font(.caption.bold()).foregroundStyle(.cyan)
                    Text("A home for\nyour progress.").font(.largeTitle.bold())
                    Text("Local profiles, atomic quest rewards, and save conflicts. The preview never signs in or sends data to Apple.").foregroundStyle(.secondary)
                    Text(lab.notice).font(.footnote).accessibilityIdentifier("profile-saves-status")
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                .background(.cyan.opacity(0.10), in: .rect(cornerRadius: 22))

                card("Local profile", symbol: "person.crop.square") {
                    Picker("Identity", selection: $lab.identity) {
                        Text("Guest Alice").tag(false); Text("Account Alice").tag(true)
                    }.pickerStyle(.segmented).disabled(lab.isBusy)
                    Picker("Save slot", selection: $lab.slotName) {
                        Text("Campaign").tag("campaign"); Text("Autosave").tag("autosave")
                    }.pickerStyle(.segmented).disabled(lab.isBusy)
                    Text("Each identity and slot has separate files. Switching does not merge guest progress into an account.").font(.caption).foregroundStyle(.secondary)
                    if let profile = lab.profile {
                        HStack {
                            Text("\(profile.state.journal.events.count)/2 coins").bold()
                            Spacer(); Text("Gold: \(profile.wallet.balance(for: "gold"))").bold()
                        }
                        Text("Receipts: \(profile.state.journal.claims.count) · Revision: \(profile.revision.uuidString.prefix(8))").font(.caption).monospaced()
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack { localControls }
                        VStack(alignment: .leading) { localControls }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack { persistenceControls }
                        VStack(alignment: .leading) { persistenceControls }
                    }
                    Text("Changes persist immediately in Application Support. Recovery deliberately restores the previous wallet and quest state together.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                card("Two-device conflict preview", symbol: "arrow.triangle.branch") {
                    Text("Create two local fixture directories: Duo has 10 points, Mac has 30. Inspect either version, then choose the whole directory to keep.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("Create conflict preview") { lab.makeConflict() }.disabled(lab.isBusy)
                    Text("Directory: \(String(describing: lab.cloud?.status ?? .closed))").font(.caption).monospaced()
                    ForEach(lab.cloud?.conflicts ?? []) { version in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(version.deviceName) · \(lab.versionScores[version.id] ?? 0) points").bold()
                            Button("Keep \(version.deviceName) save") { lab.resolve(version.id) }.disabled(lab.isBusy)
                        }
                    }
                    Text(lab.cloudSummary).font(.footnote)
                    ViewThatFits(in: .horizontal) {
                        HStack { cloudControls }
                        VStack(alignment: .leading) { cloudControls }
                    }
                    Text("Selection affects every profile and slot in a GameSave directory. This preview only selects a local fixture; it performs no cloud synchronization.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                DisclosureGroup("Configured iCloud · optional") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("iCloud.com.example.game", text: $lab.containerIdentifier).textFieldStyle(.roundedBorder)
                        Text("Requires iOS/macOS 26+, a signed app with iCloud Documents, and a configured container. Cloud identity is separate from Game Center identity.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Open configured iCloud") { lab.openNative() }
                            .disabled(lab.isBusy || lab.containerIdentifier.isEmpty || !CloudSaveDirectory.isSupported)
                    }.padding(.top, 8)
                }
            }
            .buttonStyle(.bordered).tint(.cyan)
            .frame(maxWidth: 720, alignment: .leading).padding().frame(maxWidth: .infinity)
        }
        .navigationTitle("Profiles & saves")
        .onChange(of: lab.identity) { lab.selectionChanged() }
        .onChange(of: lab.slotName) { lab.selectionChanged() }
        .onDisappear { lab.stop() }
    }
    @ViewBuilder private var localControls: some View {
        Button("Open local slot") { lab.openLocal() }.disabled(lab.isBusy)
        Button("Collect save coin") { lab.collect() }.disabled(lab.isBusy || lab.profile == nil)
        Button("Claim 10 gold") { lab.claim() }.disabled(lab.isBusy || lab.profile == nil)
    }
    @ViewBuilder private var persistenceControls: some View {
        Button("Reload saved profile") { lab.reload() }.disabled(lab.isBusy || lab.profile == nil)
        Button("Try stale write") { lab.staleWrite() }.disabled(lab.isBusy || lab.stale == nil)
        Button("Recover previous save") { lab.recover() }.disabled(lab.isBusy || lab.profile == nil)
    }
    @ViewBuilder private var cloudControls: some View {
        Button("Close directory") { lab.closeCloud() }.disabled(lab.isBusy || lab.cloud == nil)
        Button("Test closed store") { lab.testClosedStore() }.disabled(lab.isBusy || lab.cloudStore == nil)
    }
    private func card<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) { Label(title, systemImage: symbol).font(.title3.bold()); content() }
            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(.secondary.opacity(0.08), in: .rect(cornerRadius: 22))
    }
}

private struct SavesLabState: Codable, Sendable { var points = 0; var journal: QuestJournal }

@MainActor @Observable
private final class ProfileSavesLab {
    var identity = false
    var slotName = "campaign"
    var profile: PlayerProfile<SavesLabState>?
    var stale: PlayerProfile<SavesLabState>?
    var cloud: CloudSaveDirectory?
    var versionScores: [UUID: Int] = [:]
    var cloudSummary = "No directory open."
    var containerIdentifier = ""
    var notice = "Open a local slot to start. Nothing runs on appearance."
    var isBusy = false
    @ObservationIgnored private var store: PlayerProfileStore<SavesLabState>?
    @ObservationIgnored var cloudStore: PlayerProfileStore<SavesLabState>?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    private var player: PlayerProfileID { identity ? .account(provider: "demo-account", id: "alice") : .guest("alice") }
    private var schema: ProfileSaveSchema<SavesLabState> { try! ProfileSaveSchema() }
    private var slot: SaveSlotID { try! SaveSlotID(slotName) }
    private func root() throws -> URL { try ProfileSaveLocation.applicationSupport(appIdentifier: "dev.spriteui.demo.profiles") }
    private func initial(points: Int = 0) throws -> SavesLabState {
        SavesLabState(points: points, journal: try QuestJournal(playerID: "alice", quests: [QuestDefinition(id: "save-coins", title: "Two coins",
            objectives: [QuestObjective(id: "coins", metric: "coin", target: 2)], rewards: [QuestReward("gold", amount: 10)])]))
    }
    func selectionChanged() { stop(); profile = nil; stale = nil; store = nil; notice = "Selection changed. Open this identity’s slot explicitly." }
    func openLocal() {
        run {
            let store = try PlayerProfileStore(player: self.player, directory: self.root(), schema: self.schema)
            let profile: PlayerProfile<SavesLabState>
            do { profile = try await store.load(from: self.slot) }
            catch ProfileSaveError.slotNotFound { profile = try await store.create(in: self.slot, state: self.initial(), at: Date()) }
            self.store = store; self.profile = profile; self.stale = profile
            self.notice = "Opened \(self.identity ? "account" : "guest") \(self.slotName). Gold: \(profile.wallet.balance(for: "gold"))."
        }
    }
    func collect() {
        run {
            guard let store = self.store, let profile = self.profile else { return }
            let date = Date(), eventID = UUID().uuidString
            let updated = try await store.update(profile, at: date) {
                try $0.state.journal.record(QuestEvent(id: eventID, metric: "coin", at: date))
            }
            self.stale = profile; self.profile = updated; self.notice = "Coin saved immediately."
        }
    }
    func claim() {
        run {
            guard let store = self.store, let profile = self.profile else { return }
            let date = Date()
            let updated = try await store.update(profile, at: date) { try $0.claimQuestReward("save-coins", in: \.journal, at: date) }
            self.stale = profile; self.profile = updated
            self.notice = "Receipt and \(updated.wallet.balance(for: "gold")) gold committed in one file replacement."
        }
    }
    func reload() {
        run {
            guard let store = self.store else { return }
            self.profile = try await store.load(from: self.slot); self.notice = "Reloaded the durable profile."
        }
    }
    func staleWrite() {
        run {
            guard let store = self.store, let stale = self.stale else { return }
            do { try await store.update(stale, at: Date()) { $0.state.points = 999 }; self.notice = "This revision was still current; a new revision was committed. Reload." }
            catch ProfileSaveError.staleRevision { self.notice = "Stale write rejected. Newer quest and wallet progress was preserved." }
        }
    }
    func recover() {
        run {
            guard let store = self.store else { return }
            self.profile = try await store.recoverBackup(in: self.slot, at: Date())
            self.notice = "Restored the previous quest state and wallet together as a new revision."
        }
    }
    func makeConflict() {
        run {
            self.cloud?.close()
            let fixtures = try self.root().appendingPathComponent("preview-\(UUID())", isDirectory: true)
            var choices: [CloudSavePreviewVersion] = []
            for (name, score) in [("Duo", 10), ("Mac", 30)] {
                let directory = fixtures.appendingPathComponent(name, isDirectory: true)
                let store = try PlayerProfileStore(player: self.player, directory: directory.appendingPathComponent("SpriteUIProfiles"), schema: self.schema)
                _ = try await store.create(in: self.slot, state: self.initial(points: score), at: Date())
                choices.append(try CloudSavePreviewVersion(directory: directory, deviceName: name, isLocal: name == "Duo", modifiedAt: Date()))
            }
            let cloud = try CloudSaveDirectory.preview(versions: choices); self.cloud = cloud
            try await cloud.open(); self.versionScores = [:]
            for version in cloud.conflicts {
                let store = try cloud.inspect(version.id, for: self.player, schema: self.schema)
                self.versionScores[version.id] = try await store.load(from: self.slot).state.points
            }
            self.cloudSummary = "Two intact local fixture versions. Choose one explicitly."
        }
    }
    func resolve(_ id: UUID) {
        run {
            guard let cloud = self.cloud else { return }
            try cloud.resolve(using: id)
            if cloud.status == .syncing { try await cloud.finishSyncing() }
            let store = try cloud.makeStore(for: self.player, schema: self.schema)
            let profile = try await store.load(from: self.slot)
            self.cloudStore = store; self.cloudSummary = "Selected save: \(profile.state.points) points. Local profile slot was not replaced."
        }
    }
    func closeCloud() { cloud?.close(); cloudSummary = "Directory closed. Any store from it is now invalid." }
    func testClosedStore() {
        run {
            guard let store = self.cloudStore else { return }
            do { _ = try await store.slots(); self.cloudSummary = "Store still active. Close the directory first." }
            catch ProfileSaveError.directoryClosed { self.cloudSummary = "Closed store rejected access, as expected." }
        }
    }
    func openNative() {
        run {
            self.cloud?.close()
            let cloud = try CloudSaveDirectory(containerIdentifier: self.containerIdentifier)
            self.cloud = cloud; try await cloud.open()
            self.cloudSummary = "Native directory: \(String(describing: cloud.status)). Configure your own profile/slot handling before writing."
        }
    }
    func stop() { generation = UUID(); task?.cancel(); task = nil; cloud?.close(); isBusy = false }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }; isBusy = true
        let current = generation
        task = Task { @MainActor [weak self] in
            do { try await action(); try Task.checkCancellation() }
            catch { if !Task.isCancelled, self?.generation == current { self?.notice = "Could not complete: \(error)" } }
            if self?.generation == current { self?.isBusy = false }
        }
    }
}
