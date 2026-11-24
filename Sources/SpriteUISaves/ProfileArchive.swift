import CryptoKit
import Foundation

struct ProfileArchiveHeader: Decodable { let formatVersion: Int }

struct ProfileRecord: Codable {
    let player: PlayerProfileID
    let slot: SaveSlotID
    let schemaVersion: Int
    let revision: UUID
    let parentRevision: UUID?
    let savedAt: Date
    let payload: Data
    let wallet: ProfileWallet
}

struct ProfileArchive: Codable {
    let formatVersion: Int
    let body: Data
    let checksum: String

    init(record: ProfileRecord) throws {
        formatVersion = 1; body = try saveEncoder().encode(record); checksum = saveDigest(body)
    }
    func record(maximumBytes: Int) throws -> ProfileRecord {
        guard formatVersion == 1 else { throw ProfileSaveError.unsupportedVersion(formatVersion) }
        guard body.count <= maximumBytes, saveDigest(body) == checksum else { throw ProfileSaveError.corruptData }
        let record = try JSONDecoder().decode(ProfileRecord.self, from: body)
        try record.player.validate()
        guard record.schemaVersion > 0, record.savedAt.timeIntervalSinceReferenceDate.isFinite,
              record.payload.count <= maximumBytes else { throw ProfileSaveError.corruptData }
        return record
    }
}

struct ProfileSlotFile: Codable {
    let formatVersion: Int
    let current: Data
    let previous: Data?
    init(current: Data, previous: Data?) { formatVersion = 1; self.current = current; self.previous = previous }
}

func saveEncoder() -> JSONEncoder {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder
}
func saveDigest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

/// The persistent location of local saves, independent of Game Center and Documents.
public enum ProfileSaveLocation {
    /// Returns an application-scoped Application Support path without creating files.
    public static func applicationSupport(appIdentifier: String) throws -> URL {
        try validateSaveID(appIdentifier)
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        return base.appendingPathComponent("SpriteUISaves", isDirectory: true)
            .appendingPathComponent(saveDigest(Data(appIdentifier.utf8)), isDirectory: true)
    }
}
