import Foundation

/// Relative pose-update urgency. Host authority and membership do not depend on this priority.
public enum NetworkReplicationPriority: Int, Codable, Comparable, Sendable {
    case background = 0, normal = 1, high = 2, critical = 3
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
/// A host's per-player membership decision. Owned actors and required ancestors are always retained.
public enum NetworkRelevance: Sendable {
    case hidden
    case visible(priority: NetworkReplicationPriority = .normal)
    case required
}
/// Main-actor host selection evaluated against canonical entities. It is relevance, not an authorization boundary.
@MainActor public struct NetworkReplicationPolicy {
    let decision: (Entity, NetworkPeer) -> NetworkRelevance
    let isSelective: Bool
    private init() { decision = { _, _ in .visible() }; isSelective = false }
    /// Replicates the complete selected world, preserving existing behavior.
    public static var all: Self { .init() }
    /// Creates an opt-in policy. Keep it pure and retain any weakly referenced adapter separately.
    public init(_ decision: @escaping (Entity, NetworkPeer) -> NetworkRelevance) { self.decision = decision; isSelective = true }
}
/// A per-player token budget for entity replication only. Control and application messages remain independently bounded.
public struct NetworkReplicationBudget: Hashable, Sendable {
    /// Sustained entity-replication bytes per second, clamped to 512...1,000,000.
    public let bytesPerSecond: Double
    /// Maximum accrued bytes, clamped to 512...48,000. A full membership frame must fit this burst.
    public let burstBytes: Int
    /// Maximum pose packet including its envelope, clamped to 512...1,000 bytes.
    public let maximumPosePacketBytes: Int
    /// Maximum pose packets per publication, clamped to 1...8.
    public let maximumPosePacketsPerUpdate: Int
    /// Refresh/age-priority threshold, clamped to 0.05...5 seconds; capacity can delay refresh beyond it.
    public let refreshInterval: TimeInterval
    /// Creates bounded replication traffic settings. Baselines and structural changes also consume this budget.
    public init(bytesPerSecond: Double = 12_000, burstBytes: Int = 48_000, maximumPosePacketBytes: Int = 1_000,
                maximumPosePacketsPerUpdate: Int = 4, refreshInterval: TimeInterval = 0.5) {
        self.bytesPerSecond = bytesPerSecond.isFinite ? min(1_000_000, max(512, bytesPerSecond)) : 12_000
        self.burstBytes = min(48_000, max(512, burstBytes)); self.maximumPosePacketBytes = min(1_000, max(512, maximumPosePacketBytes))
        self.maximumPosePacketsPerUpdate = min(8, max(1, maximumPosePacketsPerUpdate))
        self.refreshInterval = refreshInterval.isFinite ? min(5, max(0.05, refreshInterval)) : 0.5
    }
}
/// Read-only per-player wire diagnostics for the current session incarnation.
public struct NetworkPeerReplicationStatistics: Sendable {
    /// The recipient/player identity.
    public let peerID: NetworkPeerID
    /// Latest scoped and global synchronized entity counts.
    public internal(set) var relevantEntities = 0
    public internal(set) var availableEntities = 0
    /// Lifetime bytes sent/received, including wire envelopes. Counters saturate instead of wrapping.
    public internal(set) var replicationBytesSent: UInt64 = 0
    public internal(set) var applicationBytesSent: UInt64 = 0
    public internal(set) var controlBytesSent: UInt64 = 0
    public internal(set) var bytesReceived: UInt64 = 0
    /// Successfully sent entity packets, including reliable membership and unreliable poses.
    public internal(set) var replicationPacketsSent: UInt64 = 0
    /// Publications deferred for insufficient credits; structural changes take precedence over poses.
    public internal(set) var deferredPublications: UInt64 = 0
    /// Latest number of changed/due pose records still awaiting a send.
    public internal(set) var deferredPoseUpdates = 0
    /// Remaining replication credits. Nil means the full-state path has no token budget.
    public internal(set) var availableReplicationBytes: Double?
    /// Creates empty diagnostics for one player.
    public init(peerID: NetworkPeerID) { self.peerID = peerID }
}
