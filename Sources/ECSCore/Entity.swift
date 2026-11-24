/// An object in a ``World``: an identity, a set of components, and a place in the hierarchy.
@MainActor
open class Entity: Identifiable {
    public typealias ID = UInt64

    private static var nextID: ID = 1

    public nonisolated let id: ID
    public var name: String

    /// Local enablement. Disabling a parent suspends its subtree without changing
    /// the children's local flags or removing anything from the world.
    public var isEnabled: Bool {
        get { enabled }
        set {
            guard enabled != newValue else { return }
            let previous = activationStates()
            enabled = newValue
            activationDidChange(from: previous)
        }
    }
    private var enabled = true

    public var isEnabledInHierarchy: Bool { isEnabled && (parent?.isEnabledInHierarchy ?? true) }
    /// Enabled in a world. Scene pause is a separate clock setting.
    public var isActive: Bool { world != nil && isEnabledInHierarchy }
    @_spi(Backend) public private(set) var activationRevision: UInt64 = 0

    func invalidateActivation() { activationRevision &+= 1 }

    private func activationStates() -> [(Entity, Bool)] {
        var result: [(Entity, Bool)] = []
        visit { result.append(($0, $0.isEnabledInHierarchy)) }
        return result
    }

    private func activationDidChange(from previous: [(Entity, Bool)]) {
        var changes: [(Entity, Bool, UInt64)] = []
        for (entity, old) in previous {
            let value = entity.isEnabledInHierarchy
            guard old != value else { continue }
            entity.activationRevision &+= 1
            changes.append((entity, value, entity.activationRevision))
        }
        // Invalidate the whole transition before callbacks can capture fresh poses.
        for (entity, _, _) in changes {
            guard let world = entity.world else { continue }
            if entity === world.root { world.resetFixedStepClock() }
            world.invalidateFixedTransform(for: entity)
        }
        // Finish backend transitions before user handlers can reenter this setter.
        for (entity, _, _) in changes {
            if let world = entity.world { world.observer?.world(world, activationDidChange: entity) }
        }
        for (entity, value, revision) in changes {
            guard entity.activationRevision == revision, let world = entity.world else { continue }
            world.publish(WorldEvents.DidChangeEntityActivation(entity: entity, isEnabledInHierarchy: value), from: entity)
        }
    }

    public private(set) weak var parent: Entity?
    public private(set) var children: [Entity] = []

    /// The world this entity belongs to, or `nil` if it hasn't been added to one.
    public internal(set) weak var world: World?

    var storage: [ObjectIdentifier: any Component] = [:]

    public var components: ComponentSet { ComponentSet(entity: self) }

    public required init() {
        id = Entity.nextID
        Entity.nextID += 1
        name = ""
        storage[Transform.componentID] = Transform.identity
    }

    /// An entity that takes over an ID saved in a snapshot. Later entities get higher IDs.
    init(restoringID id: ID) {
        self.id = id
        Entity.nextID = max(Entity.nextID, id &+ 1)
        name = ""
        storage[Transform.componentID] = Transform.identity
    }

    public convenience init(name: String = "", components: [any Component]) {
        self.init()
        self.name = name
        self.components.set(components)
    }

    public convenience init(name: String = "", components: any Component...) {
        self.init(name: name, components: components)
    }

    // Reserve file-supplied IDs before assigning replacement IDs, so an early
    // root collision cannot consume a saved ID that appears later in the file.
    static func reserveIDs(through id: ID) {
        if id < ID.max { nextID = max(nextID, id + 1) }
    }

    // MARK: Transform shortcuts

    public var transform: Transform {
        get { components[Transform.self] ?? .identity }
        set { components.set(newValue) }
    }

    public var position: SIMD2<Float> {
        get { transform.translation }
        set { transform.translation = newValue }
    }

    // MARK: Hierarchy

    public func addChild(_ child: Entity) {
        do { try child.setParent(self) }
        catch { preconditionFailure("Invalid entity hierarchy: \(error)") }
    }

    // Called only after setParent has validated the whole operation.
    func adopt(_ child: Entity) {
        let previous = child.activationStates()
        children.append(child)
        child.parent = self
        child.activationDidChange(from: previous)
        world?.attach(child)
    }

    public func removeFromParent() {
        guard let parent else { return }
        let previous = activationStates()
        world?.detach(self)
        parent.children.removeAll { $0 === self }
        self.parent = nil
        activationDidChange(from: previous)
    }

    /// Finds the first entity with the given name in this entity's subtree, depth first.
    /// Checks this entity before its descendants, like RealityKit.
    public func findEntity(named name: String) -> Entity? {
        if self.name == name { return self }
        for child in children {
            if let match = child.findEntity(named: name) { return match }
        }
        return nil
    }

    /// Whether `ancestor` is this entity's parent, grandparent, and so on.
    public func isDescendant(of ancestor: Entity) -> Bool {
        var current = parent
        while let entity = current {
            if entity === ancestor { return true }
            current = entity.parent
        }
        return false
    }

    /// Calls `body` on this entity and all of its descendants, parents first.
    public func visit(_ body: (Entity) -> Void) {
        body(self)
        for child in children { child.visit(body) }
    }

    // MARK: Component storage

    func setComponent<T: Component>(_ component: T) {
        let key = ObjectIdentifier(T.self)
        let isNew = storage[key] == nil
        storage[key] = component
        world?.componentDidChange(on: self, type: T.self, added: isNew)
    }

    func removeComponent<T: Component>(_ type: T.Type) {
        let key = ObjectIdentifier(type)
        guard storage[key] != nil else { return }
        world?.componentWillRemove(from: self, type: type)
        storage[key] = nil
        world?.componentDidChange(on: self, type: type, added: false)
    }

    /// Identifiers of the component types currently on this entity.
    /// The component stored under a type's `ObjectIdentifier`.
    @_spi(Backend)
    public func component(forKey key: ObjectIdentifier) -> (any Component)? { storage[key] }

    @_spi(Backend)
    public var componentKeys: Dictionary<ObjectIdentifier, any Component>.Keys { storage.keys }

    /// Writes a component without notifying the world or backend.
    ///
    /// Backends use this to copy simulation results (such as physics positions)
    /// back into components without marking them dirty again.
    @_spi(Backend)
    public func _setWithoutNotifying<T: Component>(_ component: T) {
        storage[ObjectIdentifier(T.self)] = component
    }
}
