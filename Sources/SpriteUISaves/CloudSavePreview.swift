import Foundation

/// A local fixture representing one whole-directory conflict choice; no Apple service is involved.
public struct CloudSavePreviewVersion: Sendable {
    /// An existing fixture directory, using the same SpriteUIProfiles layout as a native directory.
    public let directory: URL
    /// A display-only device name.
    public let deviceName: String
    /// Whether the fixture represents a local version.
    public let isLocal: Bool
    /// The explicit fixture timestamp.
    public let modifiedAt: Date
    /// Creates a validated local conflict fixture without touching files.
    public init(directory: URL, deviceName: String, isLocal: Bool, modifiedAt: Date) throws {
        guard directory.isFileURL, !deviceName.isEmpty, modifiedAt.timeIntervalSinceReferenceDate.isFinite else { throw ProfileSaveError.invalidValue }
        self.directory = directory; self.deviceName = deviceName; self.isLocal = isLocal; self.modifiedAt = modifiedAt
    }
}

extension CloudSaveDirectory {
    /// Creates an account-free available-directory fixture. Status must be ready, offline, or localOnly.
    /// This performs no synchronization and never invokes GameSave, even on supported systems.
    public static func preview(directory: URL, status: CloudSaveStatus = .localOnly) throws -> CloudSaveDirectory {
        guard directory.isFileURL, [.ready, .offline, .localOnly].contains(status) else { throw ProfileSaveError.invalidValue }
        return try CloudSaveDirectory(containerIdentifier: "local-preview", driver: .init(open: { _ in
            PreviewCloudSaveHandle(.available(directory, status))
        }))
    }

    /// Creates an explicit whole-directory conflict fixture. Choosing a version selects its local directory;
    /// no directories are merged, copied, removed, or uploaded by the preview.
    public static func preview(versions: [CloudSavePreviewVersion]) throws -> CloudSaveDirectory {
        guard versions.count >= 2, Set(versions.map { $0.directory.standardizedFileURL }).count == versions.count else { throw ProfileSaveError.invalidValue }
        let locations = versions.map {
            CloudVersionLocation(version: .init(id: UUID(), isLocal: $0.isLocal, deviceName: $0.deviceName, modifiedAt: $0.modifiedAt), url: $0.directory)
        }
        return try CloudSaveDirectory(containerIdentifier: "local-preview", driver: .init(open: { _ in
            PreviewCloudSaveHandle(.conflicted(locations))
        }))
    }
}

@MainActor private final class PreviewCloudSaveHandle: CloudSaveHandle {
    private var current: CloudDirectorySnapshot
    init(_ snapshot: CloudDirectorySnapshot) { current = snapshot }
    func finishSyncing() async {}
    func snapshot() -> CloudDirectorySnapshot { current }
    func resolve(_ version: UUID) throws {
        guard case .conflicted(let versions) = current, let chosen = versions.first(where: { $0.version.id == version }) else {
            throw ProfileSaveError.unknownConflict
        }
        current = .available(chosen.url, .ready)
    }
    func triggerPendingUpload() async -> Bool { false }
    func close() { current = .closed }
}
