import ECSCore
import Foundation

/// Optional host-only relevance hints. Groups are visibility organization, not a security boundary.
public struct NetworkInterestComponent: Component, Codable, Sendable {
    /// Empty means ungrouped; otherwise the observer must share at least one group.
    public var groups: Set<String>
    /// Keeps an eligible grouped entity visible independently of distance.
    public var isAlwaysRelevant: Bool
    /// Pose-update urgency under a replication budget.
    public var priority: NetworkReplicationPriority
    /// Creates application-owned hints. The interest adapter validates group bounds before using them.
    public init(groups: Set<String> = [], isAlwaysRelevant: Bool = false, priority: NetworkReplicationPriority = .normal) {
        self.groups = groups; self.isAlwaysRelevant = isAlwaysRelevant; self.priority = priority
    }
}
/// Invalid/excessive observer configuration. The existing observer remains unchanged on failure.
public enum NetworkSpatialInterestError: Error, Equatable, Sendable { case invalidConfiguration, capacityExceeded }

/// Retained host-side distance/group relevance with exit hysteresis and bounded per-player memory.
@MainActor public final class NetworkSpatialInterest {
    /// Entry radius in scene units.
    public let radius: Float
    /// Extra exit distance to avoid replica churn at the boundary.
    public let exitMargin: Float
    /// Number of explicitly configured observers, at most 32.
    public var observerCount: Int { observers.count }
    private struct Observer { var position: SIMD2<Float>; var groups: Set<String>; var visible: Set<NetworkEntityID> = [] }
    private var observers: [NetworkPeerID: Observer] = [:]
    private weak var world: World?
    private var departure: EventSubscription?
    /// Creates an adapter for a retained host world. Observer locations are explicit canonical scene-space points.
    public init(world: World, radius: Float = 500, exitMargin: Float = 50) throws {
        guard radius.isFinite, radius > 0, radius <= 100_000, exitMargin.isFinite, exitMargin >= 0, exitMargin <= 100_000 else { throw NetworkSpatialInterestError.invalidConfiguration }
        self.world = world; self.radius = radius; self.exitMargin = exitMargin
        departure = world.subscribe(to: NetworkEvents.PeerLeft.self) { [weak self] in self?.removeObserver(for: $0.peerID) }
    }
    isolated deinit { departure?.cancel() }
    /// A policy that weakly references this adapter; retain the adapter beside its session.
    public var policy: NetworkReplicationPolicy { .init { [weak self] entity, peer in self?.relevance(of: entity, for: peer.id) ?? .hidden } }
    /// Sets a canonical observer point and allowed groups. Call when the host-owned player moves.
    public func setObserver(at position: SIMD2<Float>, groups: Set<String> = [], for peer: NetworkPeerID) throws {
        guard position.x.isFinite, position.y.isFinite, abs(position.x) <= 1_000_000, abs(position.y) <= 1_000_000,
              !peer.rawValue.isEmpty, peer.rawValue.utf8.count <= 256, valid(groups) else { throw NetworkSpatialInterestError.invalidConfiguration }
        guard observers[peer] != nil || observers.count < 32 else { throw NetworkSpatialInterestError.capacityExceeded }
        var observer = observers[peer] ?? .init(position: position, groups: groups)
        observer.position = position; observer.groups = groups
        if let world { observer.visible.formIntersection(Set(world.allEntities.compactMap { $0.components[SynchronizationComponent.self]?.id })) }
        observers[peer] = observer
    }
    /// Removes one observer and its hysteresis memory.
    public func removeObserver(for peer: NetworkPeerID) { observers[peer] = nil }
    /// Clears all old player viewpoints on session teardown/recovery.
    public func removeAllObservers() { observers = [:] }
    private func valid(_ groups: Set<String>) -> Bool {
        groups.count <= 32 && groups.allSatisfy { !$0.isEmpty && $0.utf8.count <= 64 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
    }
    private func relevance(of entity: Entity, for peer: NetworkPeerID) -> NetworkRelevance {
        guard entity.world === world, let id = entity.components[SynchronizationComponent.self]?.id, var observer = observers[peer] else { return .hidden }
        let marker = entity.components[NetworkInterestComponent.self] ?? .init()
        guard valid(marker.groups), marker.groups.isEmpty || !marker.groups.isDisjoint(with: observer.groups) else {
            observer.visible.remove(id); observers[peer] = observer; return .hidden
        }
        let position = entity.scenePosition, delta = position - observer.position
        let limit = radius + (observer.visible.contains(id) ? exitMargin : 0)
        let visible = marker.isAlwaysRelevant || (position.x.isFinite && position.y.isFinite && delta.x * delta.x + delta.y * delta.y <= limit * limit)
        if visible { observer.visible.insert(id) } else { observer.visible.remove(id) }
        // A selective session captures at most 512 synchronized entities.
        if observer.visible.count > 512 { observer.visible = [id] }
        observers[peer] = observer
        return visible ? (marker.isAlwaysRelevant ? .required : .visible(priority: marker.priority)) : .hidden
    }
}
