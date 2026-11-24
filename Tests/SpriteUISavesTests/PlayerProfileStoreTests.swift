import Foundation
import Gameplay
import Synchronization
@testable import SpriteUISaves
import Testing

private struct TestProgress: Codable, Sendable, Equatable { var score = 0; var journal: QuestJournal }
private let saveNow = Date(timeIntervalSince1970: 3_000)
private func temporaryDirectory() -> URL { URL.temporaryDirectory.appendingPathComponent("spriteui-saves-\(UUID())", isDirectory: true) }
private func testState(player: String = "alice") throws -> TestProgress {
    TestProgress(journal: try QuestJournal(playerID: player, quests: [QuestDefinition(id: "first", title: "First",
        objectives: [QuestObjective(id: "coins", metric: "coin", target: 2)], rewards: [QuestReward("gold", amount: 10)])]))
}
private func testStore(_ directory: URL, player: PlayerProfileID = .guest("alice"), maximumBytes: Int = 4 * 1_024 * 1_024) throws -> PlayerProfileStore<TestProgress> {
    try PlayerProfileStore(player: player, directory: directory, schema: ProfileSaveSchema(), maximumBytes: maximumBytes)
}
private func files(in directory: URL) -> [URL] {
    (FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "slot" }
}

@Suite struct PlayerProfileStoreTests {
    @Test func futureArchiveFormatCannotBeReplacedByBackupRecovery() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try testStore(root), slot = try SaveSlotID("main")
        let original = try await store.create(in: slot, state: testState(), at: saveNow)
        try await store.save(original, at: saveNow)
        let url = try #require(files(in: root).first)
        let record = try JSONDecoder().decode(ProfileSlotFile.self, from: Data(contentsOf: url))
        let future = Data("{\"formatVersion\":2,\"newStructure\":true}".utf8)
        try saveEncoder().encode(ProfileSlotFile(current: future, previous: record.previous)).write(to: url)
        let before = try Data(contentsOf: url)
        #expect(try await store.slots().first?.health == .unreadable)
        await #expect(throws: ProfileSaveError.unsupportedVersion(2)) { try await store.recoverBackup(in: slot, at: saveNow) }
        #expect(try Data(contentsOf: url) == before)
    }
    @Test func deleteIsExplicitAndRevisionChecked() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try testStore(root), slot = try SaveSlotID("main")
        let original = try await store.create(in: slot, state: testState(), at: saveNow)
        let latest = try await store.update(original, at: saveNow) { $0.state.score = 1 }
        await #expect(throws: ProfileSaveError.staleRevision) { try await store.delete(original) }
        try await store.delete(latest)
        await #expect(throws: ProfileSaveError.slotNotFound) { try await store.load(from: slot) }
        #expect(try await store.slots().isEmpty)
    }
    @Test func failedAtomicReplacementDoesNotCommitWalletOrClaim() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fail = Mutex(false)
        let store = try PlayerProfileStore<TestProgress>(player: .guest("alice"), directory: root, schema: ProfileSaveSchema(),
            maximumBytes: 4 * 1_024 * 1_024, access: ProfileDirectoryGate().activate(), readOnly: false,
            writeFile: { bytes, url in
                if fail.withLock({ $0 }) { throw CocoaError(.fileWriteOutOfSpace) }
                try bytes.write(to: url, options: .atomic)
            })
        var state = try testState()
        try state.journal.record(QuestEvent(id: "coins", metric: "coin", amount: 2, at: saveNow))
        let slot = try SaveSlotID("main")
        let original = try await store.create(in: slot, state: state, at: saveNow)
        fail.withLock { $0 = true }
        await #expect(throws: CocoaError.self) {
            try await store.update(original, at: saveNow) { try $0.claimQuestReward("first", in: \.journal, at: saveNow) }
        }
        let loaded = try await store.load(from: slot)
        #expect(loaded == original && loaded.wallet.balance(for: "gold") == 0 && loaded.state.journal.claims.isEmpty)
        fail.withLock { $0 = false }
        let retried = try await store.update(loaded, at: saveNow) { try $0.claimQuestReward("first", in: \.journal, at: saveNow) }
        #expect(retried.wallet.balance(for: "gold") == 10)
    }

    @Test func overflowingRewardRollsBackAllCurrencyAndJournalChanges() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try testStore(root), slot = try SaveSlotID("main")
        let target = try QuestObjective(id: "one", metric: "win", target: 1)
        var journal = try QuestJournal(playerID: "alice", quests: [
            QuestDefinition(id: "max", title: "Maximum", objectives: [target], rewards: [QuestReward("gold", amount: Int.max)]),
            QuestDefinition(id: "overflow", title: "Overflow", objectives: [target], rewards: [QuestReward("silver", amount: 5), QuestReward("gold")])])
        try journal.record(QuestEvent(id: "won", metric: "win", at: saveNow))
        let original = try await store.create(in: slot, state: TestProgress(journal: journal), at: saveNow)
        let maximum = try await store.update(original, at: saveNow) { try $0.claimQuestReward("max", in: \.journal, at: saveNow) }
        await #expect(throws: ProfileSaveError.invalidValue) {
            try await store.update(maximum, at: saveNow) { try $0.claimQuestReward("overflow", in: \.journal, at: saveNow) }
        }
        let loaded = try await store.load(from: slot)
        #expect(loaded == maximum && loaded.wallet.balance(for: "silver") == 0)
        #expect(try loaded.state.journal.progress(for: "overflow", at: saveNow).status == .completed)
    }

    @Test func cancelledLocalTransactionDoesNotStart() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try testStore(root), slot = try SaveSlotID("main")
        let original = try await store.create(in: slot, state: testState(), at: saveNow)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.update(original, at: saveNow) { $0.state.score = 99 }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.load(from: slot) == original)
    }
    @Test func createUpdateLoadAndList() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try testStore(root), slot = try SaveSlotID("campaign")
        let initial = try await store.create(in: slot, state: testState(), at: saveNow)
        let updated = try await store.update(initial, at: saveNow.addingTimeInterval(1)) { $0.state.score = 12 }
        #expect(updated.parentRevision == initial.revision)
        #expect(updated.revision != initial.revision)
        #expect(try await store.load(from: slot) == updated)
        let listing = try await store.slots()
        #expect(listing.count == 1 && listing[0].slot == slot && listing[0].health == .available)
        await #expect(throws: ProfileSaveError.slotExists) { try await store.create(in: slot, state: testState(), at: saveNow) }
    }

    @Test func namespacesAndSlotsNeverCross() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let guest = try testStore(root), account = try testStore(root, player: .account(provider: "game-center", id: "alice"))
        let slot = try SaveSlotID("../campaign/a"), other = try SaveSlotID("campaign-b")
        let g = try await guest.create(in: slot, state: testState(), at: saveNow)
        let a = try await account.create(in: slot, state: testState(), at: saveNow)
        #expect(g.player != a.player)
        #expect(files(in: root).count == 2)
        await #expect(throws: ProfileSaveError.identityMismatch) { try await account.save(g, at: saveNow) }
        await #expect(throws: ProfileSaveError.slotNotFound) { try await guest.load(from: other) }
        let another = try await guest.create(in: other, state: testState(), at: saveNow)
        #expect(another.slot != g.slot)
        #expect(try await guest.slots().count == 2)
    }

    @Test func staleRevisionCannotOverwriteNewProgressAcrossStores() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try testStore(root), second = try testStore(root), slot = try SaveSlotID("main")
        let original = try await first.create(in: slot, state: testState(), at: saveNow)
        let stale = try await second.load(from: slot)
        let latest = try await first.update(original, at: saveNow) { $0.state.score = 40 }
        await #expect(throws: ProfileSaveError.staleRevision) { try await second.update(stale, at: saveNow) { $0.state.score = 1 } }
        #expect(try await first.load(from: slot) == latest)
    }

    @Test func concurrentStoresCommitOnlyOneCandidateRevision() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try testStore(root), b = try testStore(root), slot = try SaveSlotID("main")
        let original = try await a.create(in: slot, state: testState(), at: saveNow)
        let outcomes = await withTaskGroup(of: Bool.self) { group in
            for store in [a, b] {
                group.addTask {
                    do { try await store.update(original, at: saveNow) { $0.state.score += 1 }; return true }
                    catch { return false }
                }
            }
            var values: [Bool] = []; for await value in group { values.append(value) }; return values
        }
        #expect(outcomes.filter { $0 }.count == 1)
        #expect(try await a.load(from: slot).state.score == 1)
    }

    @Test func thrownTransactionDoesNotPersistCandidate() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try testStore(root), slot = try SaveSlotID("main")
        let original = try await store.create(in: slot, state: testState(), at: saveNow)
        await #expect(throws: ProfileSaveError.invalidValue) {
            try await store.update(original, at: saveNow) { candidate in
                candidate.state.score = 99; throw ProfileSaveError.invalidValue
            }
        }
        #expect(try await store.load(from: slot) == original)
    }

    @Test func questClaimAndWalletCommitTogether() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try testStore(root), slot = try SaveSlotID("main")
        var state = try testState()
        try state.journal.record(QuestEvent(id: "coins", metric: "coin", amount: 2, at: saveNow))
        let original = try await store.create(in: slot, state: state, at: saveNow)
        let claimed = try await store.update(original, at: saveNow) { profile in
            try profile.claimQuestReward("first", in: \.journal, at: saveNow)
        }
        #expect(claimed.wallet.balance(for: "gold") == 10)
        #expect(claimed.state.journal.claims.count == 1)
        await #expect(throws: ProgressionError.alreadyClaimed) {
            try await store.update(claimed, at: saveNow) { try $0.claimQuestReward("first", in: \.journal, at: saveNow) }
        }
        let spent = try await store.update(claimed, at: saveNow) { try $0.spend(4, currency: "gold") }
        #expect(spent.wallet.balance(for: "gold") == 6)
        await #expect(throws: ProfileSaveError.invalidValue) {
            try await store.update(spent, at: saveNow) { try $0.spend(7, currency: "gold") }
        }
        #expect(try await store.load(from: slot) == spent)
    }

    @Test func failedClaimDoesNotLeaveReceiptOrGrant() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try testStore(root), slot = try SaveSlotID("main")
        let original = try await store.create(in: slot, state: testState(player: "someone-else"), at: saveNow)
        await #expect(throws: ProfileSaveError.identityMismatch) {
            try await store.update(original, at: saveNow) { try $0.claimQuestReward("first", in: \.journal, at: saveNow) }
        }
        #expect(try await store.load(from: slot) == original)
    }

    @Test func walletRetainsGrantKeyWhenJournalIsReplaced() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try testStore(root), slot = try SaveSlotID("main")
        var state = try testState()
        try state.journal.record(QuestEvent(id: "coins", metric: "coin", amount: 2, at: saveNow))
        let unclaimed = state
        let original = try await store.create(in: slot, state: state, at: saveNow)
        let first = try await store.update(original, at: saveNow) { try $0.claimQuestReward("first", in: \.journal, at: saveNow) }
        let second = try await store.update(first, at: saveNow) {
            $0.state = unclaimed; try $0.claimQuestReward("first", in: \.journal, at: saveNow)
        }
        #expect(second.wallet.balance(for: "gold") == 10)
        #expect(second.wallet.appliedClaimIDs.count == 1)
    }

    @Test func checksumDamageIsVisibleAndRecoveryIsExplicit() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try testStore(root), slot = try SaveSlotID("main")
        let first = try await store.create(in: slot, state: testState(), at: saveNow)
        try await store.update(first, at: saveNow) { $0.state.score = 2 }
        let url = try #require(files(in: root).first)
        let bytes = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(ProfileSlotFile.self, from: bytes)
        try saveEncoder().encode(ProfileSlotFile(current: Data("damaged".utf8), previous: file.previous)).write(to: url)
        await #expect(throws: (any Error).self) { try await store.load(from: slot) }
        #expect(try await store.slots().first?.health == .recoveryAvailable)
        #expect(try Data(contentsOf: url) != bytes)
        let recovered = try await store.recoverBackup(in: slot, at: saveNow)
        #expect(recovered.state.score == 0)
        #expect(recovered.revision != first.revision)
        #expect(try await store.load(from: slot) == recovered)
    }

    @Test func unreadableSlotIsNotSilentlyRecreated() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try testStore(root), slot = try SaveSlotID("main")
        _ = try await store.create(in: slot, state: testState(), at: saveNow)
        let url = try #require(files(in: root).first)
        try Data("corrupt file".utf8).write(to: url)
        #expect(try await store.slots().first?.health == .unreadable)
        await #expect(throws: ProfileSaveError.slotExists) { try await store.create(in: slot, state: testState(), at: saveNow) }
    }

    @Test func schemaMigrationIsExplicitAndLoadDoesNotRewrite() async throws {
        struct Old: Codable, Sendable { var score: Int }
        struct New: Codable, Sendable { var points: Int; var level: Int }
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let slot = try SaveSlotID("main")
        let old = try PlayerProfileStore<Old>(player: .guest("alice"), directory: root, schema: ProfileSaveSchema())
        let previous = try await old.create(in: slot, state: Old(score: 8), at: saveNow)
        let url = try #require(files(in: root).first), before = try Data(contentsOf: url)
        let schema = try ProfileSaveSchema<New>(version: 2, migrations: [1: { bytes in
            let state = try JSONDecoder().decode(Old.self, from: bytes)
            return try JSONEncoder().encode(New(points: state.score, level: 1))
        }])
        let current = try PlayerProfileStore(player: .guest("alice"), directory: root, schema: schema)
        let migrated = try await current.load(from: slot)
        #expect(migrated.state.points == 8 && migrated.state.level == 1)
        #expect(migrated.revision == previous.revision && migrated.schemaVersion == 2)
        #expect(try Data(contentsOf: url) == before)
        try await current.save(migrated, at: saveNow)
        await #expect(throws: ProfileSaveError.unsupportedVersion(2)) { try await old.load(from: slot) }
        await #expect(throws: ProfileSaveError.unsupportedVersion(2)) { try await old.recoverBackup(in: slot, at: saveNow) }
    }

    @Test func badMigrationAndOversizedStatePreserveDisk() async throws {
        struct Blob: Codable, Sendable { var bytes: String }
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let slot = try SaveSlotID("main")
        let store = try PlayerProfileStore<Blob>(player: .guest("alice"), directory: root, schema: ProfileSaveSchema(), maximumBytes: 2_048)
        let original = try await store.create(in: slot, state: Blob(bytes: "small"), at: saveNow)
        await #expect(throws: ProfileSaveError.capacityExceeded) {
            try await store.update(original, at: saveNow) { $0.state.bytes = String(repeating: "x", count: 10_000) }
        }
        let missing = try PlayerProfileStore<Blob>(player: .guest("alice"), directory: root, schema: ProfileSaveSchema(version: 2))
        await #expect(throws: ProfileSaveError.unsupportedVersion(1)) { try await missing.load(from: slot) }
        #expect(try await store.load(from: slot).state.bytes == "small")
    }

    @Test func invalidIDsDatesAndSymlinkFilesAreRejected() async throws {
        #expect(SaveSlotID(rawValue: "") == nil)
        #expect(throws: ProfileSaveError.invalidIdentifier) { try SaveSlotID("bad\nslot") }
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: ProfileSaveError.invalidIdentifier) { try testStore(root, player: .account(provider: "", id: "x")) }
        let store = try testStore(root), slot = try SaveSlotID("main")
        _ = try await store.create(in: slot, state: testState(), at: saveNow)
        let url = try #require(files(in: root).first)
        try FileManager.default.removeItem(at: url)
        let destination = root.appendingPathComponent("outside")
        try Data("untouched".utf8).write(to: destination)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
        await #expect(throws: ProfileSaveError.corruptData) { try await store.load(from: slot) }
        #expect(try Data(contentsOf: destination) == Data("untouched".utf8))
        try FileManager.default.removeItem(at: destination)
        // A dangling link is still an existing slot entry; creation must not replace it.
        await #expect(throws: ProfileSaveError.slotExists) { try await store.create(in: slot, state: testState(), at: saveNow) }
        // The enumerator URL can cache its pre-replacement resource values; query the actual link.
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == destination.path)
    }
}
