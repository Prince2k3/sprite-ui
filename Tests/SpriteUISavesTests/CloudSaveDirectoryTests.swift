import Foundation
@testable import SpriteUISaves
import Testing

private struct CloudState: Codable, Sendable, Equatable { var score: Int }
@MainActor private final class TestCloudHandle: CloudSaveHandle {
    var value: CloudDirectorySnapshot
    var finish: (@MainActor () async -> Void)?
    var uploadWork: (@MainActor () async -> Bool)?
    var closed = false
    var selected: UUID?
    init(_ snapshot: CloudDirectorySnapshot) { value = snapshot }
    func finishSyncing() async { await finish?() }
    func snapshot() -> CloudDirectorySnapshot { value }
    func resolve(_ version: UUID) throws {
        guard case .conflicted(let values) = value, let choice = values.first(where: { $0.version.id == version }) else { throw ProfileSaveError.unknownConflict }
        selected = version; value = .available(choice.url, .ready)
    }
    func triggerPendingUpload() async -> Bool { if let uploadWork { return await uploadWork() }; return true }
    func close() { closed = true }
}
@MainActor private final class Pause {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func resume() { continuation?.resume(); continuation = nil }
}
private func cloudFolder() -> URL { URL.temporaryDirectory.appendingPathComponent("cloud-test-\(UUID())", isDirectory: true) }

@MainActor @Suite(.serialized) struct CloudSaveDirectoryTests {
    @Test func publicPreviewNeverUsesNativeServicesAndReopensLocalFiles() async throws {
        let root = cloudFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = try CloudSaveDirectory.preview(directory: root, status: .offline)
        #expect(directory.status == .closed)
        try await directory.open()
        let schema = try ProfileSaveSchema<CloudState>(), slot = try SaveSlotID("main")
        let store = try directory.makeStore(for: .guest("g"), schema: schema)
        _ = try await store.create(in: slot, state: CloudState(score: 4), at: Date())
        #expect(try await directory.requestUpload() == false)
        directory.close(); try await directory.open()
        let reopened = try directory.makeStore(for: .guest("g"), schema: schema)
        #expect(try await reopened.load(from: slot).state.score == 4)
    }

    @Test func malformedCloudStateFailsClosed() async throws {
        let handle = TestCloudHandle(.conflicted([]))
        let directory = try CloudSaveDirectory(containerIdentifier: "iCloud.example", driver: .init(open: { _ in handle }))
        await #expect(throws: ProfileSaveError.corruptData) { try await directory.open() }
        #expect(handle.closed)
        #expect(throws: ProfileSaveError.directoryClosed) { try directory.makeStore(for: .guest("g"), schema: ProfileSaveSchema<CloudState>()) }
    }
    @Test func constructionDoesNotStartCloudWork() throws {
        var calls = 0
        let directory = try CloudSaveDirectory(containerIdentifier: "iCloud.example", driver: .init(open: { _ in
            calls += 1; throw ProfileSaveError.cloudUnavailable
        }))
        #expect(directory.status == .closed && calls == 0)
    }

    @Test(arguments: [CloudSaveStatus.ready, .offline, .localOnly])
    func usableNativeStatesPreserveTheirMeaning(status: CloudSaveStatus) async throws {
        let root = cloudFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let handle = TestCloudHandle(.available(root, status))
        let directory = try CloudSaveDirectory(containerIdentifier: "iCloud.example", driver: .init(open: { _ in handle }))
        try await directory.open()
        #expect(directory.status == status)
        let store = try directory.makeStore(for: .guest("guest"), schema: ProfileSaveSchema<CloudState>())
        let slot = try SaveSlotID("main")
        _ = try await store.create(in: slot, state: CloudState(score: 10), at: Date())
        #expect(try await store.load(from: slot).state.score == 10)
        directory.close()
        #expect(handle.closed && directory.status == .closed)
        await #expect(throws: ProfileSaveError.directoryClosed) { try await store.load(from: slot) }
    }

    @Test func reopenDoesNotReactivateOldStores() async throws {
        let root = cloudFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let handle = TestCloudHandle(.available(root, .ready))
        let directory = try CloudSaveDirectory(containerIdentifier: "iCloud.example", driver: .init(open: { _ in handle }))
        try await directory.open()
        let old = try directory.makeStore(for: .guest("g"), schema: ProfileSaveSchema<CloudState>())
        let slot = try SaveSlotID("main")
        _ = try await old.create(in: slot, state: CloudState(score: 1), at: Date())
        directory.close(); try await directory.open()
        let fresh = try directory.makeStore(for: .guest("g"), schema: ProfileSaveSchema<CloudState>())
        #expect(try await fresh.load(from: slot).state.score == 1)
        await #expect(throws: ProfileSaveError.directoryClosed) { try await old.load(from: slot) }
    }

    @Test func conflictsAreInspectedWithoutFilesystemChangesThenSelectedExplicitly() async throws {
        let first = cloudFolder(), second = cloudFolder()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let slot = try SaveSlotID("main"), schema = try ProfileSaveSchema<CloudState>()
        for (root, score) in [(first, 10), (second, 30)] {
            let store = try PlayerProfileStore(player: .guest("g"), directory: root.appendingPathComponent("SpriteUIProfiles"), schema: schema)
            _ = try await store.create(in: slot, state: CloudState(score: score), at: Date())
        }
        let local = CloudSaveVersion(id: UUID(), isLocal: true, deviceName: "Phone", modifiedAt: Date())
        let remote = CloudSaveVersion(id: UUID(), isLocal: false, deviceName: "Mac", modifiedAt: Date())
        let handle = TestCloudHandle(.conflicted([.init(version: local, url: first), .init(version: remote, url: second)]))
        let directory = try CloudSaveDirectory(containerIdentifier: "iCloud.example", driver: .init(open: { _ in handle }))
        try await directory.open()
        #expect(directory.conflicts.count == 2 && directory.status == .conflicted)
        #expect(throws: ProfileSaveError.directoryClosed) { try directory.makeStore(for: .guest("g"), schema: schema) }
        // Remove the fixture writer's lock. Inspection must not recreate it or add any other file.
        try FileManager.default.removeItem(at: second.appendingPathComponent("SpriteUIProfiles/store.lock"))
        let before = FileManager.default.enumerator(atPath: second.path)?.allObjects as? [String]
        let preview = try directory.inspect(remote.id, for: .guest("g"), schema: schema)
        let profile = try await preview.load(from: slot)
        #expect(profile.state.score == 30)
        await #expect(throws: ProfileSaveError.readOnly) { try await preview.update(profile, at: Date()) { $0.state.score = 999 } }
        #expect(before == FileManager.default.enumerator(atPath: second.path)?.allObjects as? [String])
        try directory.resolve(using: remote.id)
        #expect(handle.selected == remote.id && directory.status == .ready)
        await #expect(throws: ProfileSaveError.directoryClosed) { try await preview.load(from: slot) }
        let store = try directory.makeStore(for: .guest("g"), schema: schema)
        #expect(try await store.load(from: slot).state.score == 30)
        #expect(throws: ProfileSaveError.unknownConflict) { try directory.resolve(using: local.id) }
    }

    @Test func closingDuringOpenRetiresLateCompletion() async throws {
        let pause = Pause(), handle = TestCloudHandle(.available(cloudFolder(), .ready))
        handle.finish = { await pause.wait() }
        let directory = try CloudSaveDirectory(containerIdentifier: "iCloud.example", driver: .init(open: { _ in handle }))
        let task = Task { @MainActor in try await directory.open() }
        while pause.continuation == nil { await Task.yield() }
        directory.close()
        do { try await task.value; Issue.record("A closed open should fail") } catch { }
        pause.resume(); await Task.yield()
        #expect(directory.status == .closed && handle.closed)
    }

    @Test func cancellationReleasesCallerAndClosesNativeHandle() async throws {
        let pause = Pause(), handle = TestCloudHandle(.available(cloudFolder(), .ready))
        handle.finish = { await pause.wait() }
        let directory = try CloudSaveDirectory(containerIdentifier: "iCloud.example", driver: .init(open: { _ in handle }))
        let task = Task { @MainActor in try await directory.open() }
        while pause.continuation == nil { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(directory.status == .closed && handle.closed)
        pause.resume()
    }

    @Test func iCloudAccountChangeInvalidatesExistingStores() async throws {
        let root = cloudFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let handle = TestCloudHandle(.available(root, .ready))
        let directory = try CloudSaveDirectory(containerIdentifier: "iCloud.example", driver: .init(open: { _ in handle }))
        try await directory.open()
        let store = try directory.makeStore(for: .guest("g"), schema: ProfileSaveSchema<CloudState>())
        NotificationCenter.default.post(name: .NSUbiquityIdentityDidChange, object: nil)
        await #expect(throws: ProfileSaveError.directoryClosed) { try await store.slots() }
        await Task.yield()
        #expect(directory.status == .closed)
    }

    @Test func uploadResultDoesNotPromiseRemoteDurabilityAndCannotOutliveClose() async throws {
        let pause = Pause(), handle = TestCloudHandle(.available(cloudFolder(), .offline))
        let directory = try CloudSaveDirectory(containerIdentifier: "iCloud.example", driver: .init(open: { _ in handle }))
        try await directory.open()
        #expect(try await directory.requestUpload() == true)
        #expect(directory.status == .offline)
        handle.uploadWork = { await pause.wait(); return true }
        let task = Task { @MainActor in try await directory.requestUpload() }
        while pause.continuation == nil { await Task.yield() }
        await #expect(throws: ProfileSaveError.operationInProgress) { try await directory.requestUpload() }
        directory.close(); pause.resume()
        await #expect(throws: ProfileSaveError.directoryClosed) { try await task.value }
    }

    @Test func nativeFailureAndUnavailableDriverDoNotEraseLocalStore() async throws {
        let root = cloudFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try PlayerProfileStore(player: .guest("g"), directory: root, schema: ProfileSaveSchema<CloudState>())
        let slot = try SaveSlotID("main")
        _ = try await store.create(in: slot, state: CloudState(score: 8), at: Date())
        let directory = try CloudSaveDirectory(containerIdentifier: "iCloud.example", driver: .init(open: { _ in throw ProfileSaveError.cloudUnavailable }))
        await #expect(throws: ProfileSaveError.cloudUnavailable) { try await directory.open() }
        #expect(try await store.load(from: slot).state.score == 8)
    }
}
