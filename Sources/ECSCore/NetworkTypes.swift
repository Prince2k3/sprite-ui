import Foundation

/// A transport-authenticated player identity, independent of local entity IDs.
public struct NetworkPeerID: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A connected player's identity and presentation name.
public struct NetworkPeer: Hashable, Codable, Sendable {
    public let id: NetworkPeerID
    public let displayName: String
    public init(id: NetworkPeerID, displayName: String) { self.id = id; self.displayName = displayName }
}

/// Connection and message notifications. Transports must derive `from` from the
/// authenticated connection, never from a field in the message body.
public enum NetworkTransportEvent: Sendable {
    case connected(NetworkPeer)
    case disconnected(NetworkPeerID)
    case received(Data, from: NetworkPeerID)
    case failed(String)
}

/// A player-to-player byte channel. The session owns `onEvent` until stopped.
/// Reliable delivery must preserve order per sender/recipient pair. Callbacks
/// arrive on the main actor; sessions queue them until their next update.
@MainActor
public protocol NetworkTransport: AnyObject {
    var localPeer: NetworkPeer { get }
    var connectedPeers: [NetworkPeer] { get }
    var onEvent: (@MainActor (NetworkTransportEvent) -> Void)? { get set }
    func send(_ data: Data, to peer: NetworkPeerID, reliably: Bool) throws
    func disconnect()
}

/// Stable, globally unique replicated identity. Local `Entity.ID`s are never sent.
public struct NetworkEntityID: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue.uuidString < rhs.rawValue.uuidString }
}

/// Opts an entity into host-authoritative replication. Names in `components`
/// select entries in the session's schema; missing selected components are
/// removed from replicas. Ancestors must also be synchronized, or be the root.
/// `owner` associates commands with a player; it does not grant write authority.
public struct SynchronizationComponent: Component, Equatable, Codable, Sendable {
    public let id: NetworkEntityID
    public var owner: NetworkPeerID?
    public var components: [String]
    public var interpolates: Bool
    public init(id: NetworkEntityID = .init(), owner: NetworkPeerID? = nil,
                components: [String] = ["transform"], interpolates: Bool = true) {
        self.id = id; self.owner = owner; self.components = components; self.interpolates = interpolates
    }
    /// Clones must receive a fresh network identity. Saved worlds may retain one
    /// by decoding this component explicitly before starting a new session.
    public func cloned() -> Self? {
        Self(owner: owner, components: components, interpolates: interpolates)
    }
}

/// Explicitly permitted wire components. Registration here does not register a
/// snapshot type, or allow remote callers to mutate it. `Transform` is included
/// as `transform`. Register the same names and value formats on every participant.
/// Components must use `NetworkEntityID` for cross-entity references: local IDs,
/// native bodies, resources and behavior systems are not portable network state.
@MainActor
public struct NetworkReplicationSchema {
    struct Entry {
        let type: any Component.Type
        let encode: (any Component) throws -> Data
        let decode: (Data) throws -> any Component
        let remove: (Entity) -> Void
    }
    var entries: [String: Entry] = [:]
    public init() {
        try! register(Transform.self, named: "transform", validate: { pose in
            guard pose.translation.x.isFinite, pose.translation.y.isFinite, pose.rotation.isFinite,
                  pose.scale.x.isFinite, pose.scale.y.isFinite, pose.zPosition.isFinite else {
                throw NetworkSessionError.invalidState
            }
        })
    }
    /// A throwing validator runs on both outgoing and incoming values, before
    /// any received frame changes the world. Register only inert value data;
    /// native physics, cameras, input and runtime services belong on local entities.
    /// Custom coders and validators must be side-effect free.
    public mutating func register<T: Component & Codable>(_ type: T.Type, named name: String,
                                                          validate: @escaping (T) throws -> Void = { _ in }) throws {
        guard !name.isEmpty, name.utf8.count <= 64, entries[name] == nil,
              !entries.values.contains(where: { ObjectIdentifier($0.type) == ObjectIdentifier(type) }),
              !(type is any EntityReferencingComponent.Type), type != SynchronizationComponent.self else {
            throw NetworkSessionError.invalidSchema
        }
        entries[name] = Entry(type: type, encode: { value in
            guard let value = value as? T else { throw NetworkSessionError.invalidSchema }
            try validate(value)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(value)
        }, decode: { data in
            let value = try JSONDecoder().decode(T.self, from: data)
            try validate(value); return value
        }, remove: { $0.components.remove(type) })
    }
}

/// Bounded traffic and smoothing settings. Complete states repair lost updates;
/// structural/component changes are reliable, small pose-only updates may be
/// unreliable. This first version is intended for small real-time matches.
public struct NetworkSessionConfiguration: Hashable, Sendable {
    public let updatesPerSecond: Double
    public let interpolationDuration: TimeInterval
    public let maximumEntities: Int
    public let maximumPacketBytes: Int
    public let maximumQueuedMessages: Int
    public let maximumCommandBytes: Int
    public init(updatesPerSecond: Double = 10, interpolationDuration: TimeInterval = 0.1,
                maximumEntities: Int = 128, maximumPacketBytes: Int = 48_000,
                maximumQueuedMessages: Int = 128, maximumCommandBytes: Int = 4096) {
        self.updatesPerSecond = updatesPerSecond.isFinite ? min(60, max(1, updatesPerSecond)) : 10
        self.interpolationDuration = interpolationDuration.isFinite ? min(1, max(0, interpolationDuration)) : 0.1
        self.maximumEntities = min(512, max(1, maximumEntities))
        self.maximumPacketBytes = min(48_000, max(512, maximumPacketBytes))
        self.maximumQueuedMessages = min(1024, max(1, maximumQueuedMessages))
        self.maximumCommandBytes = min(16_000, max(1, maximumCommandBytes))
    }
}

/// A session failure, with no automatic host migration or reconnection.
public enum NetworkSessionError: Error, Equatable, Sendable, LocalizedError {
    case invalidState, invalidSchema, invalidPacket, incompatibleVersion
    case worldUnavailable, worldInUse, transportInUse, notHost, notConnected
    case packetTooLarge, capacityExceeded, reentrantOperation, hostDisconnected
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidState: "The session or replicated state is invalid."
        case .invalidSchema: "All players must register the same permitted component names and formats."
        case .invalidPacket: "A multiplayer message failed validation."
        case .incompatibleVersion: "The multiplayer protocol versions do not match."
        case .worldUnavailable: "The multiplayer world is no longer available."
        case .worldInUse: "This world already has an active network session."
        case .transportInUse: "This connection already has a message handler."
        case .notHost: "Only the host can publish entity state."
        case .notConnected: "The session has not joined the match."
        case .packetTooLarge: "The replicated state or command exceeds the configured message size."
        case .capacityExceeded: "The session's entity or message budget was exceeded."
        case .reentrantOperation: "This session operation cannot run inside another session operation."
        case .hostDisconnected: "The host left the match. Start a new match to continue."
        case .transport(let message): message
        }
    }
}

/// Session notifications, published on the owning world after validation.
public enum NetworkEvents {
    public struct PeerJoined: Event { public let peer: NetworkPeer }
    public struct PeerLeft: Event { public let peerID: NetworkPeerID }
    /// Application commands are opaque. The host must validate ownership,
    /// allowed actions, rate and game rules before changing authoritative state.
    public struct CommandReceived: Event { public let data: Data; public let sender: NetworkPeerID }
    public struct DidApplyState: Event { public let sequence: UInt64; public let entityCount: Int }
    public struct Failed: Event { public let error: NetworkSessionError }
}
