import Foundation
import Observation
import SpriteUI
import SwiftUI

/// Local interruptions and fresh-match recovery. No accounts or native score submissions.
@MainActor struct MultiplayerRecoveryDemoView: View {
    @State private var model = RecoveryPractice()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("RECOVERY LAB", systemImage: "arrow.clockwise.circle.fill").font(.caption.bold()).foregroundStyle(.mint)
                    Text("A lost connection.\nA deliberate return.").font(.largeTitle.bold())
                    Text("Keep an approved host checkpoint, match the same players again, and wait for a fresh client baseline before resuming.").foregroundStyle(.secondary)
                    Text(model.message).font(.footnote).accessibilityIdentifier("recovery-lab-status")
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.mint.opacity(0.1), in: .rect(cornerRadius: 22))
                Text("Alice: \(model.a.party.state.rawValue) · Bob: \(model.b.party.state.rawValue)").font(.headline)
                Text("Round progress: \(model.progress) · Saved progress: \(model.savedProgress.map(String.init) ?? "none")")
                Text("Host x: \(Int(model.hostX)) · Client x: \(model.clientX.map { String(Int($0)) } ?? "none")")
                    .monospacedDigit().accessibilityIdentifier("recovery-world-positions")
                if let offer = model.a.party.recoveryOffer { Text("Approved checkpoint \(offer.id.uuidString.prefix(8))").font(.caption) }
                Button("Start a new local round") { model.start() }.disabled(model.busy || model.a.party.isActive || model.b.party.isActive)
                Button("Advance round") { model.advanceRound() }.disabled(!model.playing || model.busy)
                Button("Save host checkpoint") { model.save() }.disabled(!model.playing || model.busy)
                Divider()
                Button("Simulate background interruption") { model.interrupt() }.disabled(!model.a.party.isActive || model.busy)
                Button("Simulate connection loss") { model.disconnect() }.disabled(!model.playing || model.busy)
                Toggle("Keep Bob offline during retry", isOn: $model.keepBobOffline).disabled(model.busy || model.a.party.isActive)
                Toggle("Stall client baseline updates", isOn: $model.stallClient).disabled(model.busy)
                Button("Retry fresh match from saved checkpoint") { model.retry() }
                    .disabled(model.busy || model.approved == nil || model.a.party.isActive || model.b.party.isActive)
                Button("Resume approved checkpoint") { model.resume() }.disabled(!model.a.party.canStart || model.busy)
                Button("Return to game menu") { model.returnToMenu() }
                if let error = model.a.party.lastError { Text(error.localizedDescription).font(.footnote).foregroundStyle(.orange) }
                if let interruption = model.a.party.interruption { Text("Interruption: \(interruption.reason.rawValue)").font(.caption) }
                Text("The checkpoint saves only selected inert state. Old worlds and score reporting stay application-owned. Fixture timeouts are two seconds; there are no automatic retries or rewards.")
                    .font(.caption).foregroundStyle(.secondary)
            }.buttonStyle(.bordered).tint(.mint).padding().frame(maxWidth: 740, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle("Multiplayer recovery")
        .gameCenter(model.a)
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                model.tick()
            }
        }
        .onDisappear { model.stop() }
    }
}
private struct RecoveryRound: Codable { var progress: Int }
@MainActor @Observable private final class RecoveryPractice {
    let a = GameCenterServices.preview(player: .init(id: .init(rawValue: "recovery-alice"), displayName: "Alice"))
    let b = GameCenterServices.preview(player: .init(id: .init(rawValue: "recovery-bob"), displayName: "Bob"))
    var progress = 3
    var savedProgress: Int?
    var approved: NetworkRecoveryDescriptor?
    var hostX: Float = 0
    var clientX: Float?
    var keepBobOffline = false
    var stallClient = false
    var message = "Start, save, advance again, then interrupt and retry the saved round."
    var busy = false
    var playing: Bool { a.party.state == .playing && b.party.state == .playing }
    @ObservationIgnored private var hostWorld = World()
    @ObservationIgnored private var clientWorld = World()
    @ObservationIgnored private var oldWorlds: [World] = []
    @ObservationIgnored private var fixture: GameCenterPartyPreview?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pendingProgress: Int?
    init() {
        for services in [a, b] {
            try! services.activities.configurePreview([.init(id: "recovery-arena", title: "Recovery arena", supportsPartyCode: true)])
            services.party.recoveryConfiguration = .init(matchmakingTimeout: 2, resynchronizationTimeout: 2)
        }
    }
    private func checkpointURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SpriteUIRecoveryPractice", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("approved-round.json")
    }
    func start() {
        run {
            let fixture = try GameCenterPartyPreview(players: [self.a.localPlayer!, self.b.localPlayer!]); self.fixture = fixture
            self.approved = nil; self.savedProgress = nil; self.pendingProgress = nil
            for services in [self.a, self.b] {
                services.party.leave(); try services.party.configurePreview(fixture)
                _ = try await services.activities.load()
                if services.activities.activity?.state == .active || services.activities.activity?.state == .paused { try services.activities.discard() }
                _ = try await services.activities.start(definitionID: "recovery-arena", partyCode: "1234-5678")
            }
            async let first: Void = self.a.party.findMatch(); async let second: Void = self.b.party.findMatch(); _ = try await (first, second)
            self.oldWorlds = [self.hostWorld, self.clientWorld]; self.hostWorld = World(); self.clientWorld = World()
            let actor = Entity(name: "round-actor", components: SynchronizationComponent()); actor.position = [30, 0]; self.hostWorld.addEntity(actor)
            self.progress = 3
            try self.a.party.prepare(in: self.hostWorld, compatibilityID: "recovery-arena-v1")
            try self.b.party.prepare(in: self.clientWorld, compatibilityID: "recovery-arena-v1")
            try self.readyAndStart(); self.message = "Round running. Save a checkpoint before interrupting."
        }
    }
    func advanceRound() { guard playing, let actor = hostWorld.entities.first else { return }; progress += 1; actor.position.x += 30 }
    func save() {
        do {
            let checkpoint = try a.party.recoveryCheckpoint(applicationState: JSONEncoder().encode(RecoveryRound(progress: progress)))
            try checkpoint.write(to: checkpointURL()); approved = checkpoint.descriptor; savedProgress = progress
            message = "Checkpoint written. Its exact descriptor is pinned for this exercise. Advance again, then interrupt."
        } catch { message = error.localizedDescription }
    }
    func interrupt() { a.party.applicationDidEnterBackground(); message = "Connection interrupted. Nothing retries or restores until you ask." }
    func disconnect() { b.party.leave(); message = "Bob left the fixed match. The original host and roster must return through a fresh match." }
    func retry() {
        run {
            let checkpoint = try NetworkRecoveryCheckpoint(contentsOf: self.checkpointURL())
            guard checkpoint.descriptor == self.approved, checkpoint.descriptor.compatibilityID == "recovery-arena-v1" else { throw NetworkRecoveryError.incompatibleCheckpoint }
            let round = try JSONDecoder().decode(RecoveryRound.self, from: checkpoint.applicationState)
            guard (0...9999).contains(round.progress) else { throw NetworkRecoveryError.invalidCheckpoint }
            if self.keepBobOffline { try await self.a.party.findMatch() }
            else {
                async let first: Void = self.a.party.findMatch(); async let second: Void = self.b.party.findMatch(); _ = try await (first, second)
            }
            try Task.checkCancellation()
            try self.a.party.offerRecovery(checkpoint)
            for _ in 0..<8 { self.fixture?.advance() }
            self.oldWorlds = [self.hostWorld, self.clientWorld]; self.hostWorld = World(); self.clientWorld = World()
            try self.a.party.prepareRecovery(in: self.hostWorld, accepting: checkpoint.descriptor, compatibilityID: "recovery-arena-v1")
            try self.b.party.prepareRecovery(in: self.clientWorld, accepting: checkpoint.descriptor, compatibilityID: "recovery-arena-v1")
            try self.a.party.setReady(true); try self.b.party.setReady(true)
            self.pendingProgress = round.progress
            self.message = "Fresh party matched and checkpoint explicitly accepted. Choose Resume to resynchronize."
        }
    }
    func resume() {
        do { try a.party.startSession(); message = "Waiting for the fresh client baseline before Playing." }
        catch { message = error.localizedDescription }
    }
    private func readyAndStart() throws {
        try a.party.setReady(true); try b.party.setReady(true)
        for _ in 0..<8 { fixture?.advance() }
        try a.party.startSession()
    }
    func tick() {
        fixture?.advance(by: 0.1)
        hostWorld.update(deltaTime: 0.1)
        if !(stallClient && b.party.state == .resynchronizing) { clientWorld.update(deltaTime: 0.1) }
        let host = hostWorld.entities.first?.position.x ?? 0, client = clientWorld.entities.first?.position.x
        if hostX != host { hostX = host }; if clientX != client { clientX = client }
        if playing, let value = pendingProgress { progress = value; pendingProgress = nil; message = "Recovered. The approved round and fresh client baseline agree." }
    }
    func returnToMenu() { task?.cancel(); task = nil; busy = false; a.party.leave(); b.party.leave(); pendingProgress = nil; message = "At the game menu. The saved checkpoint was preserved; nothing resumed or reported." }
    func stop() { task?.cancel(); task = nil; a.shutdown(); b.shutdown(); busy = false }
    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true
        task = Task { @MainActor [weak self] in
            do { try await work(); try Task.checkCancellation() }
            catch { if !Task.isCancelled { self?.message = error.localizedDescription } }
            if !Task.isCancelled { self?.busy = false; self?.task = nil }
        }
    }
}
