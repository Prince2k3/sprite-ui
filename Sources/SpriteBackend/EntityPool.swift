@_spi(Backend) import ECSCore

public enum EntityPoolError: Error, Equatable, Sendable {
    case invalidCapacity, notInScene, reentrantOperation, changedHierarchy, activatedDuringReset
}

/// A bounded pool of prefab instances. Idle instances stay attached but disabled,
/// retaining their IDs, hierarchy and rendered nodes. Physics bodies are rebuilt
/// on activation. Capacity counts both leased and idle instances.
///
/// Use reset hooks for game state (pose, velocity, health, lifetime). Release stops
/// playback and clears particles/actions; ordinary `isEnabled = false` suspends
/// them instead. A cancelled pooled animation does not deliver its completion.
/// Hooks run while disabled and must not enable/reparent the instance or call the pool.
/// Rebind joints in a reset hook if their rest frame should change with the pose.
/// The pool controls each instance root's local flag; child flags are preserved.
/// Keep the pool while using it and call `removeAll()` to remove its instances.
///
/// ```swift
/// let pool = try EntityPool(prefab: projectile, scene: scene, capacity: 32,
///     onAcquire: { $0.components[PhysicsBodyComponent.self]?.velocity = .zero })
/// let shot = try pool.acquire { $0.position = muzzlePosition }
/// // Later, on impact or expiry:
/// if let shot { try pool.release(shot) }
/// ```
@MainActor
public final class EntityPool {
    public typealias Reset = @MainActor (Entity) throws -> Void
    public let prefab: PrefabResource
    public let capacity: Int
    public let container: Entity
    private weak var scene: World?
    private let onAcquire: Reset?
    private let onRelease: Reset?
    private struct Entry { let entity: Entity; var leased: Bool }
    private var entries: [Entry] = []
    private var operating = false

    public init(prefab: PrefabResource, scene: World, capacity: Int, prewarm: Int = 0,
                onAcquire: Reset? = nil, onRelease: Reset? = nil) throws {
        guard capacity > 0, prewarm >= 0, prewarm <= capacity else { throw EntityPoolError.invalidCapacity }
        self.prefab = prefab; self.capacity = capacity; self.scene = scene
        self.onAcquire = onAcquire; self.onRelease = onRelease
        container = Entity(name: "entity-pool")
        scene.addEntity(container)
        for _ in 0..<prewarm { _ = makeEntry() }
    }

    /// Instances still owned by this pool, including disabled leases, ordered by ID.
    public var leasedEntities: [Entity] { validEntries.filter(\.leased).map(\.entity).sorted { $0.id < $1.id } }
    public var leasedCount: Int { validEntries.filter(\.leased).count }
    public var availableCount: Int { validEntries.filter { !$0.leased }.count }
    public var totalCount: Int { validEntries.count }
    private var validEntries: [Entry] { entries.filter { owns($0.entity) } }
    private func owns(_ entity: Entity) -> Bool {
        scene != nil && container.world === scene && entity.world === scene && entity.parent === container
    }
    private func begin() throws {
        guard !operating else { throw EntityPoolError.reentrantOperation }
        guard scene != nil, container.world === scene else { throw EntityPoolError.notInScene }
        operating = true
        // External removal/reparenting relinquishes ownership, never edits the foreign tree.
        entries.removeAll { !owns($0.entity) }
    }
    @discardableResult private func makeEntry() -> Int {
        let entity = prefab.instantiate(); entity.isEnabled = false
        container.addChild(entity); entries.append(Entry(entity: entity, leased: false))
        return entries.count - 1
    }

    /// Returns nil at capacity. Configuration runs before activation, so systems,
    /// physics and input cannot observe a half-reset instance. A failed hook parks
    /// the instance disabled for retry; the error is propagated.
    public func acquire(configure: Reset? = nil) throws -> Entity? {
        try begin(); defer { operating = false }
        let index: Int
        if let idle = entries.lastIndex(where: { !$0.leased }) { index = idle }
        else if entries.count < capacity { index = makeEntry() }
        else { return nil }
        let entity = entries[index].entity
        entity.isEnabled = false
        do {
            try onAcquire?(entity); try configure?(entity)
            guard owns(entity) else { throw EntityPoolError.changedHierarchy }
            guard !entity.isEnabled else { throw EntityPoolError.activatedDuringReset }
            (scene?.observer as? SpriteRenderer)?.resetPooledPresentation(entity)
            entries[index].leased = true
            entity.isEnabled = true
            guard owns(entity) else { throw EntityPoolError.changedHierarchy }
            return entity
        } catch {
            entries[index].leased = false
            if owns(entity) { entity.isEnabled = false; resetRuntime(entity) }
            throw error
        }
    }

    /// Returns false for a foreign instance or a second release. Reset errors are
    /// propagated after parking the instance disabled, so capacity is not leaked.
    @discardableResult
    public func release(_ entity: Entity) throws -> Bool {
        try begin(); defer { operating = false }
        guard let index = entries.firstIndex(where: { $0.entity === entity && $0.leased }) else { return false }
        entries[index].leased = false
        entity.isEnabled = false
        resetRuntime(entity)
        defer { if owns(entity) { entity.isEnabled = false; resetRuntime(entity) } }
        try onRelease?(entity)
        guard owns(entity) else { throw EntityPoolError.changedHierarchy }
        guard !entity.isEnabled else { throw EntityPoolError.activatedDuringReset }
        return true
    }

    /// Stops and detaches all owned instances, including outstanding leases.
    /// The empty container remains in the scene and the pool can be used again.
    public func removeAll() throws {
        try begin(); defer { operating = false }
        let old = entries; entries = []
        for entry in old {
            entry.entity.isEnabled = false; resetRuntime(entry.entity)
            if owns(entry.entity) { entry.entity.removeFromParent() }
        }
    }

    private func resetRuntime(_ root: Entity) {
        root.visit { entity in
            entity.stopAllPlayback()
            entity.components.remove(PlaybackStorage.self)
            entity.components.remove(LegacyAudioPlaybackState.self)
            if let audio = entity.components[AudioComponent.self]?.cloned() { entity._setWithoutNotifying(audio) }
            if let particles = entity.components[ParticleEmitterComponent.self]?.cloned() { entity._setWithoutNotifying(particles) }
        }
        (scene?.observer as? SpriteRenderer)?.resetPooledPresentation(root, preparing: false)
    }
}
