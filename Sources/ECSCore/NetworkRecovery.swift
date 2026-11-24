import CryptoKit
import Foundation

/// Local recovery validation failures. A checksum detects corruption; it does not authenticate a file or player.
public enum NetworkRecoveryError: Error, Equatable, Sendable {
    case invalidCheckpoint, incompatibleCheckpoint, capacityExceeded, worldInUse, worldNotEmpty
}

/// The exact checkpoint a game approves for a recovery attempt. It contains no gameplay payload.
public struct NetworkRecoveryDescriptor: Codable, Hashable, Sendable, Identifiable {
    /// The immutable checkpoint identity.
    public let id: UUID
    /// The caller's level/content and wire compatibility identifier.
    public let compatibilityID: String
    /// Optional caller-owned game/party namespace, compared by the networking adapter.
    public let scope: String?
    /// The original host; this milestone does not transfer authority.
    public let hostPeerID: NetworkPeerID
    /// The exact sorted original roster, including the host.
    public let peerIDs: [NetworkPeerID]
    /// The original session incarnation, distinct from the fresh recovery session.
    public let sessionID: UUID
    /// The captured host publication sequence.
    public let sequence: UInt64
    /// The capture time, not a generic conflict-resolution policy.
    public let createdAt: Date
    /// A lowercase SHA-256 digest over metadata, selected records, and application data.
    public let digest: String

    /// Validates bounded metadata before comparing or advertising it. It does not approve authority or freshness.
    public func validate() throws {
        guard Self.validID(compatibilityID), scope.map({ !$0.isEmpty && $0.utf8.count <= 1024 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) ?? true, !peerIDs.isEmpty, peerIDs.count <= 32,
              peerIDs == peerIDs.sorted(), Set(peerIDs).count == peerIDs.count,
              peerIDs.contains(hostPeerID), peerIDs.allSatisfy({ Self.validID($0.rawValue) }),
              createdAt.timeIntervalSince1970.isFinite, digest.utf8.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw NetworkRecoveryError.invalidCheckpoint
        }
    }
    private static func validID(_ id: String) -> Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && id.utf8.count <= 256 &&
            !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}

/// A bounded application-owned host checkpoint. Only replication-schema-selected data is saved.
/// Use a trusted approved descriptor and a matching schema; neither a checksum nor peer metadata supplies anti-cheat authority.
public struct NetworkRecoveryCheckpoint: Codable, Sendable {
    /// The maximum encoded checkpoint size (256 KiB).
    public static let maximumBytes = 262_144
    /// The exact metadata to approve for one fresh match.
    public let descriptor: NetworkRecoveryDescriptor
    /// Up to 64 KiB of application-owned inert state. Decode and validate its own schema before restoring gameplay.
    public let applicationState: Data
    let records: [ReplicatedEntity]
    private struct Body: Codable {
        var version = 1
        let id: UUID
        let compatibilityID: String
        let scope: String?
        let host: NetworkPeerID
        let peers: [NetworkPeerID]
        let sessionID: UUID
        let sequence: UInt64
        let at: Date
        let applicationState: Data
        let records: [ReplicatedEntity]
    }
    private struct Archive: Codable { let body: Body; let digest: String }
    private var body: Body {
        Body(id: descriptor.id, compatibilityID: descriptor.compatibilityID, scope: descriptor.scope, host: descriptor.hostPeerID,
             peers: descriptor.peerIDs, sessionID: descriptor.sessionID, sequence: descriptor.sequence, at: descriptor.createdAt,
             applicationState: applicationState, records: records)
    }
    init(records: [ReplicatedEntity], compatibilityID: String, scope: String? = nil, host: NetworkPeerID, peers: [NetworkPeerID],
         sessionID: UUID, sequence: UInt64, applicationState: Data, at date: Date) throws {
        let body = Body(id: UUID(), compatibilityID: compatibilityID, scope: scope, host: host, peers: peers, sessionID: sessionID,
            sequence: sequence, at: date, applicationState: applicationState, records: records)
        try self.init(archive: Archive(body: body, digest: Self.hash(body)))
    }
    private init(archive: Archive) throws {
        let body = archive.body
        guard body.version == 1 else { throw NetworkRecoveryError.invalidCheckpoint }
        guard body.records.count <= 512, body.applicationState.count <= 65_536 else { throw NetworkRecoveryError.capacityExceeded }
        descriptor = .init(id: body.id, compatibilityID: body.compatibilityID, scope: body.scope, hostPeerID: body.host, peerIDs: body.peers,
            sessionID: body.sessionID, sequence: body.sequence, createdAt: body.at, digest: archive.digest)
        records = body.records; applicationState = body.applicationState
        try descriptor.validate()
        guard archive.digest == Self.hash(body) else { throw NetworkRecoveryError.invalidCheckpoint }
        guard try Self.encoder().encode(archive).count <= Self.maximumBytes else { throw NetworkRecoveryError.capacityExceeded }
    }
    /// Decodes and validates a bounded archive without creating entities or accessing a world.
    public init(data: Data) throws {
        guard data.count <= Self.maximumBytes else { throw NetworkRecoveryError.capacityExceeded }
        try self.init(archive: JSONDecoder().decode(Archive.self, from: data))
    }
    /// Reads a bounded local file. No cloud store or Game Center account is accessed.
    public init(contentsOf url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size <= Self.maximumBytes else { throw NetworkRecoveryError.capacityExceeded }
        try self.init(data: Data(contentsOf: url))
    }
    /// Returns a canonical checksummed archive for application-owned persistence.
    public func jsonData() throws -> Data { try Self.encoder().encode(Archive(body: body, digest: descriptor.digest)) }
    /// Writes the archive atomically. The application chooses its location and backup policy.
    public func write(to url: URL) throws { try jsonData().write(to: url, options: .atomic) }
    /// Validates the archive when decoded through a caller's Codable container as well.
    public init(from decoder: any Decoder) throws { try self.init(archive: Archive(from: decoder)) }
    /// Encodes the same bounded archive used by jsonData().
    public func encode(to encoder: any Encoder) throws { try Archive(body: body, digest: descriptor.digest).encode(to: encoder) }

    /// Restores selected inert entities after exact application approval, leaving local-only entities intact.
    /// The target must have no network session or synchronized entities. Every record is decoded before attachment.
    /// App-owned event observers still run when the fully prepared hierarchy is attached.
    @MainActor @discardableResult
    public func restore(in world: World, approving approved: NetworkRecoveryDescriptor,
                        schema: NetworkReplicationSchema = .init()) throws -> [NetworkEntityID: Entity] {
        guard descriptor == approved else { throw NetworkRecoveryError.incompatibleCheckpoint }
        try descriptor.validate()
        guard world.networkSessionOwner == nil else { throw NetworkRecoveryError.worldInUse }
        guard !world.allEntities.contains(where: { $0.components.has(SynchronizationComponent.self) }) else { throw NetworkRecoveryError.worldNotEmpty }
        let decoded = try NetworkRecordValidation.decode(records, schema: schema, maximumEntities: 512)
        var entities: [NetworkEntityID: Entity] = [:]
        for record in records {
            let entity = Entity(name: record.name)
            entity.isEnabled = record.isEnabled
            entity.components.set(Array(decoded[record.id]!.values))
            if decoded[record.id]?["transform"] == nil { entity.components.remove(Transform.self) }
            entity.components.set(SynchronizationComponent(id: record.id, owner: record.owner, components: record.selected, interpolates: record.interpolates))
            entities[record.id] = entity
        }
        for record in records { if let parent = record.parent { entities[parent]!.addChild(entities[record.id]!) } }
        for record in records where record.parent == nil { world.addEntity(entities[record.id]!) }
        return entities
    }
    private static func encoder() -> JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }
    private static func hash(_ body: Body) -> String {
        // Construction/decoding validates finite dates and schemas before encoding saved values.
        guard let data = try? encoder().encode(body) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
