import Foundation

@MainActor enum NetworkRecordValidation {
    static func decode(_ records: [ReplicatedEntity], schema: NetworkReplicationSchema, maximumEntities: Int) throws -> [NetworkEntityID: [String: any Component]] {
        guard records.count <= maximumEntities else { throw NetworkSessionError.capacityExceeded }
        var byID: [NetworkEntityID: ReplicatedEntity] = [:]
        var decoded: [NetworkEntityID: [String: any Component]] = [:]
        for record in records {
            guard byID[record.id] == nil, record.name.utf8.count <= 256,
                  record.selected.count <= 16, Set(record.selected).count == record.selected.count,
                  record.components.count <= record.selected.count,
                  record.owner.map({ !$0.rawValue.isEmpty && $0.rawValue.utf8.count <= 256 }) ?? true else {
                throw NetworkSessionError.invalidPacket
            }
            for name in record.selected where schema.entries[name] == nil { throw NetworkSessionError.invalidSchema }
            var values: [String: any Component] = [:]
            for box in record.components {
                guard record.selected.contains(box.name), values[box.name] == nil,
                      let entry = schema.entries[box.name] else { throw NetworkSessionError.invalidPacket }
                values[box.name] = try entry.decode(box.value)
            }
            byID[record.id] = record; decoded[record.id] = values
        }
        for record in records {
            var seen: Set<NetworkEntityID> = [record.id]
            var parent = record.parent
            while let id = parent {
                guard seen.insert(id).inserted, seen.count <= 64, let ancestor = byID[id] else { throw NetworkSessionError.invalidPacket }
                parent = ancestor.parent
            }
        }
        return decoded
    }
}
