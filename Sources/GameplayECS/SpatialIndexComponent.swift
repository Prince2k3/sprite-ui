@_spi(Backend) import ECSCore
import Gameplay

/// Groups for spatial queries, so a search can look for only enemies, only pickups,
/// and so on. Define your own with distinct bits:
///
/// ```swift
/// extension SpatialCategories {
///     static let enemies = SpatialCategories(rawValue: 1 << 1)
///     static let pickups = SpatialCategories(rawValue: 1 << 2)
/// }
/// ```
public struct SpatialCategories: OptionSet, Hashable, Codable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// The category entities get unless you give them one.
    public static let `default` = SpatialCategories(rawValue: 1)
    /// Matches every category.
    public static let all = SpatialCategories(rawValue: .max)
}

/// Makes an entity findable with the world's spatial queries, such as
/// ``ECSCore/World/entities(within:of:matching:)``.
///
/// Add ``SpatialIndexSystem`` after the systems that move things, so the index
/// holds each frame's final positions.
public struct SpatialIndexComponent: Component, Hashable, Codable, Sendable {
    /// The groups this entity belongs to.
    public var categories: SpatialCategories

    public init(categories: SpatialCategories = .default) {
        self.categories = categories
    }
}

/// Keeps the world's spatial index in step with the entities that have a
/// ``SpatialIndexComponent``.
///
/// ```swift
/// world.addSystem(MovementSystem.self)
/// world.addSystem(SpatialIndexSystem.self)   // after anything that moves entities
/// ```
public struct SpatialIndexSystem: System {
    public static var dependencies: [SystemDependency] { [.after(SteeringSystem.self), .after(PathFollowSystem.self)] }
    public init(world: World) {}

    public mutating func update(context: UpdateContext) {
        context.world.updateSpatialIndex()
    }
}

/// The index lives in a class so per-frame updates edit it in place instead of
/// copying it out of the root's components and back.
@MainActor
final class SpatialIndexStorage {
    var hash: SpatialHash<Entity.ID>
    var categories: [Entity.ID: SpatialCategories] = [:]

    init(cellSize: Float) {
        hash = SpatialHash(cellSize: cellSize)
    }
}

struct WorldSpatialIndexComponent: Component {
    let storage: SpatialIndexStorage
    func cloned() -> Self? { nil }
}

extension World {
    /// The bucket size used when a world's index is first made.
    public static let defaultSpatialCellSize: Float = 64

    private var spatialStorage: SpatialIndexStorage {
        if let stored = root.components[WorldSpatialIndexComponent.self] {
            return stored.storage
        }
        let storage = SpatialIndexStorage(cellSize: Self.defaultSpatialCellSize)
        root._setWithoutNotifying(WorldSpatialIndexComponent(storage: storage))
        return storage
    }

    /// The bucket size of the world's spatial index. Pick something near the radius
    /// you usually search; setting it rebuilds the index.
    public var spatialCellSize: Float {
        get { spatialStorage.hash.cellSize }
        set {
            let storage = SpatialIndexStorage(cellSize: newValue)
            root._setWithoutNotifying(WorldSpatialIndexComponent(storage: storage))
            updateSpatialIndex()
        }
    }

    /// A copy of the index as of its last update, keyed by entity ID, for queries
    /// the helpers here don't cover.
    public var spatialIndex: SpatialHash<Entity.ID> { spatialStorage.hash }

    /// Re-reads every indexed entity's scene position.
    ///
    /// ``SpatialIndexSystem`` calls this each frame. Call it yourself to query
    /// right after adding or moving entities.
    public func updateSpatialIndex() {
        let storage = spatialStorage
        var current: [Entity.ID: SpatialCategories] = [:]
        for entity in allEntities where entity.isActive {
            guard let component = entity.components[SpatialIndexComponent.self] else { continue }
            current[entity.id] = component.categories
            storage.hash.insert(entity.id, at: entity.scenePosition)
        }
        for id in storage.categories.keys where current[id] == nil {
            storage.hash.remove(id)
        }
        storage.categories = current
    }

    // MARK: Queries

    /// Indexed entities within `radius` of a scene point, nearest first.
    public func entities(
        within radius: Float,
        of point: SIMD2<Float>,
        matching categories: SpatialCategories = .all
    ) -> [Entity] {
        let storage = spatialStorage
        return resolve(storage.hash.elements(within: radius, of: point), categories, storage)
            .map { ($0, distanceSquared($0, point, storage)) }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// Indexed entities inside a scene-space box, in no particular order.
    public func entities(in box: BoundingBox, matching categories: SpatialCategories = .all) -> [Entity] {
        let storage = spatialStorage
        return resolve(storage.hash.elements(in: box), categories, storage)
    }

    /// Up to `count` indexed entities nearest to a scene point, nearest first.
    ///
    /// Pass `excluding` to skip the entity doing the looking.
    public func nearestEntities(
        to point: SIMD2<Float>,
        count: Int,
        maxDistance: Float = .infinity,
        matching categories: SpatialCategories = .all,
        excluding excluded: Entity? = nil
    ) -> [Entity] {
        let storage = spatialStorage
        guard count > 0 else { return [] }
        // Filtering can drop candidates, so ask for more until there are enough
        // or the index runs out.
        var request = count + (excluded == nil ? 0 : 1)
        while true {
            let ids = storage.hash.nearest(to: point, count: request, maxDistance: maxDistance)
            let found = resolve(ids, categories, storage).filter { $0 !== excluded }
            if found.count >= count || ids.count < request { return Array(found.prefix(count)) }
            request *= 2
        }
    }

    /// The indexed entity nearest to a scene point, if any.
    public func nearestEntity(
        to point: SIMD2<Float>,
        maxDistance: Float = .infinity,
        matching categories: SpatialCategories = .all,
        excluding excluded: Entity? = nil
    ) -> Entity? {
        nearestEntities(to: point, count: 1, maxDistance: maxDistance, matching: categories, excluding: excluded).first
    }

    private func resolve(
        _ ids: [Entity.ID],
        _ categories: SpatialCategories,
        _ storage: SpatialIndexStorage
    ) -> [Entity] {
        ids.compactMap { id in
            guard let entity = entity(withID: id), entity.isActive,
                  storage.categories[id]?.isDisjoint(with: categories) == false
            else { return nil }
            return entity
        }
    }

    private func distanceSquared(_ entity: Entity, _ point: SIMD2<Float>, _ storage: SpatialIndexStorage) -> Float {
        let delta = (storage.hash.position(of: entity.id) ?? entity.scenePosition) - point
        return (delta * delta).sum()
    }
}
