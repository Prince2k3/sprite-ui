import Foundation
#if canImport(GameSave)
@preconcurrency import GameSave
#endif

extension CloudSaveDriver {
    static var native: Self {
        Self(open: { container in
            #if canImport(GameSave)
            if #available(iOS 26, macOS 26, *) { return NativeCloudSaveHandle(container: container) }
            #endif
            throw ProfileSaveError.cloudUnavailable
        })
    }
}

#if canImport(GameSave)
@available(iOS 26, macOS 26, *)
@MainActor private final class NativeCloudSaveHandle: CloudSaveHandle {
    private let directory: GameSaveSyncedDirectory
    private var versions: [UUID: GameSaveSyncedDirectory.Version] = [:]
    private var ids: [URL: UUID] = [:]
    init(container: String) { directory = .openDirectory(containerIdentifier: container) }
    func finishSyncing() async { await directory.finishSyncing() }
    func snapshot() -> CloudDirectorySnapshot {
        switch directory.state {
        case .ready(let url): return .available(url, .ready)
        case .offline(let url): return .available(url, .offline)
        case .local(let url): return .available(url, .localOnly)
        case .syncing: return .syncing
        case .closed: return .closed
        case .error(let error): return .failed(error.localizedDescription)
        case .conflicted(let values):
            versions = [:]
            let locations = values.map { value in
                let id = ids[value.url] ?? UUID(); ids[value.url] = id; versions[id] = value
                return CloudVersionLocation(version: CloudSaveVersion(id: id, isLocal: value.isLocal,
                    deviceName: value.localizedNameOfSavingComputer, modifiedAt: value.modifiedDate), url: value.url)
            }
            return .conflicted(locations)
        @unknown default: return .failed("Unsupported GameSave directory state.")
        }
    }
    func resolve(_ version: UUID) throws {
        guard let native = versions[version] else { throw ProfileSaveError.unknownConflict }
        directory.resolveConflicts(with: native); versions = [:]
    }
    func triggerPendingUpload() async -> Bool { await directory.triggerPendingUpload() }
    func close() { directory.close(); versions = [:] }
}
#endif
