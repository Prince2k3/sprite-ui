import Foundation
import Synchronization

// MARK: - Registry

/// The component types a snapshot can save, each under a stable name.
///
/// A component is saved only if its type is registered. Register your own `Codable`
/// components once, before saving or loading:
///
/// ```swift
/// struct Health: Component, Codable { var hp: Int }
/// Health.registerComponent()
/// ```
///
/// `Transform` and `InputTargetComponent` are always registered. The sprite backend
/// registers its own components when a renderer is made, or with
/// `SpriteRenderer.registerComponents()`.
public enum ComponentRegistry {
    struct Entry: Sendable {
        let name: String
        let type: any Component.Type
        let encode: @Sendable (any Component, any Encoder) throws -> Void
        let decode: @Sendable (any Decoder) throws -> any Component

        init<T: Component & Codable>(_ type: T.Type, name: String) {
            self.name = name
            self.type = type
            encode = { component, encoder in try (component as! T).encode(to: encoder) }
            decode = { decoder in try T(from: decoder) }
        }
    }

    private struct Entries: Sendable {
        var byName: [String: Entry] = [:]
        var byType: [ObjectIdentifier: Entry] = [:]

        mutating func add(_ entry: Entry) {
            if let old = byType[ObjectIdentifier(entry.type)] { byName[old.name] = nil }
            byName[entry.name] = entry
            byType[ObjectIdentifier(entry.type)] = entry
        }
    }

    private static let entries: Mutex<Entries> = {
        var entries = Entries()
        entries.add(Entry(Transform.self, name: defaultName(Transform.self)))
        entries.add(Entry(TransformInterpolationComponent.self, name: defaultName(TransformInterpolationComponent.self)))
        entries.add(Entry(InputTargetComponent.self, name: defaultName(InputTargetComponent.self)))
        return Mutex(entries)
    }()

    /// Registers a component type under `name`, by default its module-qualified type name.
    /// Registering a type again replaces its name.
    public static func register<T: Component & Codable>(_ type: T.Type, named name: String? = nil) {
        let entry = Entry(type, name: name ?? defaultName(type))
        entries.withLock { $0.add(entry) }
    }

    /// Whether snapshots save components of this type.
    public static func isRegistered(_ type: any Component.Type) -> Bool {
        entry(for: type) != nil
    }

    /// Whether a stable component name can be decoded, for validation before restoring a snapshot.
    public static func isRegistered(named name: String) -> Bool {
        entry(named: name) != nil
    }

    /// The name a registered type is saved under.
    public static func name(of type: any Component.Type) -> String? {
        entry(for: type)?.name
    }

    static func entry(for type: any Component.Type) -> Entry? {
        entries.withLock { $0.byType[ObjectIdentifier(type)] }
    }

    static func entry(named name: String) -> Entry? {
        entries.withLock { $0.byName[name] }
    }

    private static func defaultName(_ type: Any.Type) -> String {
        String(reflecting: type)
    }
}

extension Component where Self: Codable {
    /// Lets snapshots save this component. See ``ComponentRegistry``.
    public static func registerComponent(named name: String? = nil) {
        ComponentRegistry.register(Self.self, named: name)
    }
}

// MARK: - Snapshots

/// One entity, its saved components, and its children, frozen as values.
///
/// Only components whose type is in the ``ComponentRegistry`` are kept. Decoding skips
/// components whose type isn't registered, so an older build can still read a newer file.
public struct EntitySnapshot {
    /// The entity's ID when the snapshot was taken.
    public var id: Entity.ID
    public var name: String
    public var isEnabled: Bool
    public var components: [any Component]
    public var children: [EntitySnapshot]
    /// Original scene pose for relocating reference frames when instantiating a subtree.
    public var sceneTransform: AffineTransform2D?

    public init(id: Entity.ID = 0, name: String = "", isEnabled: Bool = true, components: [any Component] = [], children: [EntitySnapshot] = [], sceneTransform: AffineTransform2D? = nil) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.components = components
        self.children = children
        self.sceneTransform = sceneTransform
    }

    /// The saved component of a type, if any.
    public subscript<T: Component>(_ type: T.Type) -> T? {
        components.lazy.compactMap { $0 as? T }.first
    }

    /// Makes a new entity tree from the snapshot, with new IDs. Use it to spawn copies,
    /// such as a saved prefab. Internal entity references are remapped after all children exist.
    @MainActor
    public func makeEntity() -> Entity {
        var restored: [Entity.ID: Entity] = [:]
        let root = makeEntity(restored: &restored, keepingIDs: { _ in false })
        let info = referenceInfo(parentTransform: .identity)
        let context = EntityReferenceRemapping(operation: .clone, root: root, destinations: restored,
            names: info.names, transforms: info.transforms, sourceRootID: id)
        var all: [Entity] = []; root.visit { all.append($0) }
        remapComponents(in: all, using: context)
        return root
    }

    /// Makes the entity tree, keeping each saved ID that `keepsID` allows.
    /// `restored` collects every new entity under its saved ID.
    @MainActor
    func makeEntity(restored: inout [Entity.ID: Entity], keepingIDs keepsID: (Entity.ID) -> Bool) -> Entity {
        let entity = keepsID(id) ? Entity(restoringID: id) : Entity()
        entity.name = name
        entity.isEnabled = isEnabled
        entity.components.set(components.compactMap { $0.cloned() })
        restored[id] = entity
        for child in children {
            entity.addChild(child.makeEntity(restored: &restored, keepingIDs: keepsID))
        }
        return entity
    }
    @MainActor
    func referenceInfo(parentTransform: AffineTransform2D) -> (names: [(Entity.ID, String)], transforms: [Entity.ID: AffineTransform2D]) {
        let pose = sceneTransform ?? (parentTransform * (self[Transform.self] ?? .identity).matrix)
        var names = [(id, name)], transforms = [id: pose]
        for child in children {
            let info = child.referenceInfo(parentTransform: pose)
            names += info.names; transforms.merge(info.transforms) { _, new in new }
        }
        return (names, transforms)
    }

}

extension EntitySnapshot: Codable {
    private enum CodingKeys: String, CodingKey { case id, name, isEnabled, components, children, sceneTransform }
    private enum BoxKeys: String, CodingKey { case type, value }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Entity.ID.self, forKey: .id) ?? 0
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        sceneTransform = try container.decodeIfPresent(AffineTransform2D.self, forKey: .sceneTransform)
        children = try container.decodeIfPresent([EntitySnapshot].self, forKey: .children) ?? []
        components = []
        guard container.contains(.components) else { return }
        var list = try container.nestedUnkeyedContainer(forKey: .components)
        while !list.isAtEnd {
            let box = try list.nestedContainer(keyedBy: BoxKeys.self)
            let typeName = try box.decode(String.self, forKey: .type)
            guard let entry = ComponentRegistry.entry(named: typeName) else { continue }
            components.append(try entry.decode(box.superDecoder(forKey: .value)))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        if !isEnabled { try container.encode(false, forKey: .isEnabled) }
        try container.encodeIfPresent(sceneTransform, forKey: .sceneTransform)
        if !name.isEmpty { try container.encode(name, forKey: .name) }
        var list = container.nestedUnkeyedContainer(forKey: .components)
        for component in components {
            guard let entry = ComponentRegistry.entry(for: type(of: component)) else { continue }
            var box = list.nestedContainer(keyedBy: BoxKeys.self)
            try box.encode(entry.name, forKey: .type)
            try entry.encode(component, box.superEncoder(forKey: .value))
        }
        if !children.isEmpty { try container.encode(children, forKey: .children) }
    }
}

/// Every top-level entity of a world, ready to write to a file and restore later.
///
/// ```swift
/// try world.snapshot().write(to: saveURL)
/// // later, or after relaunching
/// world.restore(try WorldSnapshot(contentsOf: saveURL))
/// ```
public struct WorldSnapshot: Codable {
    /// Bumped if the file layout changes.
    public var version: Int = 1
    public var entities: [EntitySnapshot]

    public init(entities: [EntitySnapshot]) {
        self.entities = entities
    }

    /// Reads a snapshot written by ``WorldSnapshot/jsonData(prettyPrinted:)``.
    public init(data: Data) throws {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        self = try decoder.decode(WorldSnapshot.self, from: data)
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    /// JSON with sorted keys, so saving the same world twice gives the same bytes.
    public func jsonData(prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try encoder.encode(self)
    }

    /// Writes the snapshot atomically, replacing any file already there.
    public func write(to url: URL) throws {
        try jsonData().write(to: url, options: .atomic)
    }

    /// The number of entities at every depth.
    public var entityCount: Int {
        func count(_ snapshots: [EntitySnapshot]) -> Int {
            snapshots.reduce(0) { $0 + 1 + count($1.children) }
        }
        return count(entities)
    }
}

// MARK: - Taking and restoring

extension Entity {
    /// This entity and its children, with every registered component.
    ///
    /// Components are ordered by their registered name so snapshots compare and save
    /// the same way each time.
    public func snapshot() -> EntitySnapshot {
        let saved = storage.values
            .compactMap { component in ComponentRegistry.entry(for: type(of: component)).map { ($0.name, component) } }
            .sorted { $0.0 < $1.0 }
            .compactMap { $0.1.cloned() }
        return EntitySnapshot(id: id, name: name, isEnabled: isEnabled, components: saved, children: children.map { $0.snapshot() }, sceneTransform: sceneTransformMatrix)
    }
}

extension World {
    /// Every top-level entity, with its children and registered components.
    /// Pass `include` to leave out entities, such as short-lived effects.
    public func snapshot(including include: (Entity) -> Bool = { _ in true }) -> WorldSnapshot {
        WorldSnapshot(entities: entities.filter(include).map { $0.snapshot() })
    }

    /// Removes every top-level entity, then adds the snapshot's entities in their place.
    ///
    /// Restored entities keep the IDs they were saved with, so components that point at
    /// other entities by ID, such as a camera's target, still find them. If an ID is
    /// already taken, by the world's root or a duplicate in the snapshot, that entity
    /// gets a new one instead. EntityReferencingComponents remap their links before
    /// attachment. The result maps each saved ID to its restored entity.
    @discardableResult
    public func restore(_ snapshot: WorldSnapshot) -> [Entity.ID: Entity] {
        resetFixedStepClock()
        for entity in entities { removeEntity(entity) }
        var restored: [Entity.ID: Entity] = [:]
        var taken: Set<Entity.ID> = [root.id]
        var names: [(Entity.ID, String)] = [], transforms: [Entity.ID: AffineTransform2D] = [:]
        for saved in snapshot.entities {
            let info = saved.referenceInfo(parentTransform: .identity)
            names += info.names; transforms.merge(info.transforms) { _, new in new }
        }
        Entity.reserveIDs(through: transforms.keys.max() ?? 0)
        let roots = snapshot.entities.map { $0.makeEntity(restored: &restored, keepingIDs: { taken.insert($0).inserted }) }
        var all: [Entity] = []; for entity in roots { entity.visit { all.append($0) } }
        let context = EntityReferenceRemapping(operation: .restore, root: nil, destinations: restored,
            names: names, transforms: transforms, sourceRootID: nil)
        remapComponents(in: all, using: context)
        for entity in roots { addEntity(entity) }
        return restored
    }
}
