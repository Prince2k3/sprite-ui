import Foundation

/// Receives world changes. Rendering backends implement this; games don't need it.
@MainActor
public protocol WorldObserver: AnyObject {
    /// Called after an entity joins the world. Parents are reported before children.
    func world(_ world: World, didAdd entity: Entity)
    /// Called before an entity leaves the world. Children are reported before parents.
    func world(_ world: World, willRemove entity: Entity)
    /// Called when a component is added, changed or removed.
    /// Check `entity.components` to tell whether it is still present.
    /// `transaction` is the innermost `withAnimation` active when the change was made.
    func world(
        _ world: World,
        entity: Entity,
        didChange componentType: any Component.Type,
        transaction: ActionTransaction?
    )
    /// The value of a component as currently shown on screen, mid-animation.
    /// Return `nil` when it matches the model value or the backend can't tell.
    func world(_ world: World, presentationValueOf componentType: any Component.Type, for entity: Entity) -> (any Component)?
}

extension WorldObserver {
    public func world(_ world: World, presentationValueOf componentType: any Component.Type, for entity: Entity) -> (any Component)? {
        nil
    }
}

/// Holds entities and runs systems over them.
@MainActor
public final class World {
    /// Hidden parent of every top-level entity.
    public let root: Entity

    private var index: [Entity.ID: Entity] = [:]
    private var systems: [any System] = []
    private var events = EventBus()

    @_spi(Backend)
    public weak var observer: (any WorldObserver)?

    /// Creates a world that runs every system registered with `registerSystem()`.
    public init() {
        root = Entity()
        root.name = "root"
        root.world = self
        for type in SystemRegistry.types {
            systems.append(type.init(world: self))
        }
    }

    // MARK: Entities

    /// Top-level entities.
    public var entities: [Entity] { root.children }

    /// Every entity in the world, at any depth.
    public var allEntities: some Collection<Entity> { index.values }

    public func addEntity(_ entity: Entity) {
        root.addChild(entity)
    }

    public func removeEntity(_ entity: Entity) {
        guard entity.world === self else { return }
        entity.removeFromParent()
    }

    public func entity(withID id: Entity.ID) -> Entity? {
        index[id]
    }

    public func performQuery(_ query: EntityQuery) -> [Entity] {
        index.values.filter { query.predicate.evaluate($0) }
    }

    // MARK: Systems

    /// Adds a system to this world only.
    public func addSystem<S: System>(_ type: S.Type) {
        guard !systems.contains(where: { Swift.type(of: $0) == type }) else { return }
        systems.append(type.init(world: self))
    }

    /// Advances the world by one frame: publishes ``WorldEvents/Update`` and runs systems in order.
    public func update(deltaTime: TimeInterval) {
        publish(WorldEvents.Update(world: self, deltaTime: deltaTime))
        let context = UpdateContext(world: self, deltaTime: deltaTime)
        for i in systems.indices {
            systems[i].update(context: context)
        }
    }

    // MARK: Events

    /// Subscribes to an event, optionally only those published for a specific entity.
    public func subscribe<E: Event>(
        to type: E.Type,
        on entity: Entity? = nil,
        _ handler: @escaping @MainActor (E) -> Void
    ) -> EventSubscription {
        events.subscribe(to: type, on: entity, handler)
    }

    public func publish<E: Event>(_ event: E, from source: Entity? = nil) {
        publish(event, from: source.map { [$0] } ?? [])
    }

    /// Publishes an event that involves several entities, such as a contact between two
    /// bodies. Subscribers on any of them get it, and each subscriber gets it once.
    public func publish<E: Event>(_ event: E, from sources: [Entity]) {
        for handler in events.handlers(for: E.self, sources: sources) {
            handler(event)
        }
    }

    // MARK: Called by Entity

    func attach(_ subtree: Entity) {
        subtree.visit { entity in
            entity.world = self
            index[entity.id] = entity
            observer?.world(self, didAdd: entity)
            publish(WorldEvents.DidAddEntity(entity: entity), from: entity)
        }
    }

    func detach(_ subtree: Entity) {
        var order: [Entity] = []
        subtree.visit { order.append($0) }
        for entity in order.reversed() {
            publish(WorldEvents.WillRemoveEntity(entity: entity), from: entity)
            observer?.world(self, willRemove: entity)
            index[entity.id] = nil
            entity.world = nil
        }
    }

    func componentDidChange(on entity: Entity, type: any Component.Type, added: Bool) {
        if added {
            publish(ComponentEvents.DidAdd(entity: entity, componentType: type), from: entity)
        }
        observer?.world(self, entity: entity, didChange: type, transaction: ActionTransaction.current)
    }

    func presentationValue<T: Component>(of type: T.Type, for entity: Entity) -> T? {
        observer?.world(self, presentationValueOf: type, for: entity) as? T
    }

    func componentWillRemove(from entity: Entity, type: any Component.Type) {
        publish(ComponentEvents.WillRemove(entity: entity, componentType: type), from: entity)
    }
}
