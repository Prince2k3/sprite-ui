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
    /// Scene simulation settings changed.
    func worldSimulationDidChange(_ world: World)
    func world(_ world: World, activationDidChange entity: Entity)
    func worldActiveCamera(_ world: World) -> Entity?
    /// Restores transient draw state before typed event handlers inspect the world.
    func worldWillPublishEvent(_ world: World)

    /// The value of a component as currently shown on screen, mid-animation.
    /// Return `nil` when it matches the model value or the backend can't tell.
    func world(_ world: World, presentationValueOf componentType: any Component.Type, for entity: Entity) -> (any Component)?
}

extension WorldObserver {
    public func world(_ world: World, activationDidChange entity: Entity) {}
    public func worldSimulationDidChange(_ world: World) {}
    public func worldActiveCamera(_ world: World) -> Entity? { nil }
    public func worldWillPublishEvent(_ world: World) {}
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
    private var installedSystems: [SystemEntry] = []
    var scheduledSystems: [SystemEntry] = []
    var isRunningSystems = false

    /// Fixed simulation is opt-in; variable systems retain their display-frame cadence.
    public var fixedStep: FixedStepConfiguration? {
        didSet {
            if oldValue != fixedStep {
                resetFixedStepClock()
                simulationDidChange()
            }
        }
    }
    public internal(set) var fixedStepState = FixedStepState()
    @_spi(Backend) public internal(set) var isFixedUpdating = false
    var fixedAccumulator: TimeInterval = 0
    var fixedStepEpoch: UInt64 = 0
    var fixedFrameEpoch: UInt64 = 0
    var fixedTransformHistory: [Entity.ID: FixedTransformHistory] = [:]
    var fixedTickStart: [Entity.ID: FixedTransformHistory] = [:]

    /// Collects wall-clock durations for systems that actually run in a frame.
    /// Turning profiling off immediately discards the previous measurements.
    public var isProfilingEnabled = false {
        didSet {
            if !isProfilingEnabled {
                lastSystemTimings = []
                profilingRevision &+= 1
            }
        }
    }
    public internal(set) var lastSystemTimings: [SystemTiming] = []
    var profilingRevision: UInt64 = 0

    /// True from a paused debug frame's update event through its completion.
    @_spi(Backend) public internal(set) var isDebugStepping = false

    /// Whether simulation, backend physics, and actions are paused. Component edits
    /// still render while paused. User interface updates are not scene simulation.
    public var isPaused = false { didSet { if oldValue != isPaused { resetFixedStepClock(); simulationDidChange() } } }
    /// Scene time multiplier. Zero freezes simulation. Values must be finite and
    /// nonnegative; invalid assignments are ignored.
    public var timeScale: Double {
        get { storedTimeScale }
        set {
            guard newValue.isFinite, newValue >= 0, newValue != storedTimeScale else { return }
            resetFixedStepClock()
            storedTimeScale = newValue
            simulationDidChange()
        }
    }
    private var storedTimeScale: Double = 1
    /// Physics settings are available before a renderer is created.
    public var physics = PhysicsSimulationSettings() { didSet { if oldValue != physics { simulationDidChange() } } }
    /// World-scoped resource components, independent of any rendered entity.
    public var resources: ComponentSet { root.components }
    /// Installed systems, including dependency-aware installation and enablement.
    public var systems: SystemCollection { SystemCollection(world: self) }

    /// The explicitly selected camera, or the backend's automatic camera. Assign
    /// an entity with a CameraComponent in this world; `nil` restores automatic
    /// selection. Selection can be configured before the renderer exists.
    public var activeCamera: Entity? {
        get {
            if let observer { return observer.worldActiveCamera(self) }
            return selectedCameraID.flatMap { entity(withID: $0) }.flatMap { $0.isActive ? $0 : nil }
        }
        set {
            precondition(newValue == nil || newValue?.world === self, "A camera must belong to this world.")
            selectedCameraID = newValue?.id
            observer?.worldSimulationDidChange(self)
        }
    }
    @_spi(Backend) public private(set) var selectedCameraID: Entity.ID?
    private var events = EventBus()

    @_spi(Backend)
    public weak var observer: (any WorldObserver)?

    /// Creates a world that runs every system registered with `registerSystem()`.
    public init() {
        root = Entity()
        root.name = "root"
        root.world = self
        for type in SystemRegistry.types {
            do { try installSystem(type) }
            catch { preconditionFailure("Invalid registered system schedule: \(error)") }
        }
    }

    private func simulationDidChange() {
        observer?.worldSimulationDidChange(self)
        publish(WorldEvents.SimulationDidChange(world: self))
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
        id == root.id ? root : index[id]
    }

    public func performQuery(_ query: EntityQuery) -> [Entity] {
        index.values.filter { (query.includingDisabled || $0.isActive) && query.predicate.evaluate($0) }
    }

    // MARK: Systems

    /// Adds a system to this world only, retaining the original setup API.
    /// Invalid dependencies are programmer errors here; use `try systems.add(...)`
    /// to handle schedule errors explicitly.
    public func addSystem<S: System>(_ type: S.Type) {
        do { try installSystem(type) }
        catch { preconditionFailure("Invalid system schedule: \(error)") }
    }

    func systemEntry(_ type: any System.Type) -> SystemEntry? {
        installedSystems.first { ObjectIdentifier($0.type) == ObjectIdentifier(type) }
    }

    func installSystem(_ type: any System.Type) throws {
        guard systemEntry(type) == nil else { return }
        let types = installedSystems.map(\.type) + [type]
        let order = try SystemSchedule.ordered(types)
        // Validate before initializing a system, which may subscribe to events.
        installedSystems.append(SystemEntry(type, world: self))
        scheduledSystems = order.compactMap(systemEntry)
    }

    func uninstallSystem(_ type: any System.Type) {
        installedSystems.removeAll { ObjectIdentifier($0.type) == ObjectIdentifier(type) }
        let order = (try? SystemSchedule.ordered(installedSystems.map(\.type))) ?? []
        scheduledSystems = order.compactMap(systemEntry)
    }

    /// Advances a complete headless frame, including simulation and presentation.
    /// Paused scenes do not advance. A zero delta still delivers an update event.
    public func update(deltaTime: TimeInterval) {
        guard let frame = beginFrame(deltaTime: deltaTime) else { return }
        finishFrame(frame)
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
        if let activation = event as? WorldEvents.DidChangeEntityActivation {
            if activation.entity === root { resetFixedStepClock() }
            invalidateFixedTransform(for: activation.entity)
        }
        observer?.worldWillPublishEvent(self)
        for handler in events.handlers(for: E.self, sources: sources) {
            handler(event)
        }
    }

    // MARK: Called by Entity

    func attach(_ subtree: Entity) {
        subtree.visit { entity in
            entity.invalidateActivation()
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
            invalidateFixedTransform(for: entity)
            index[entity.id] = nil
            entity.invalidateActivation()
            entity.world = nil
        }
    }

    func componentDidChange(on entity: Entity, type: any Component.Type, added: Bool) {
        if type == TransformInterpolationComponent.self || (type == Transform.self && !isFixedUpdating) {
            invalidateFixedTransform(for: entity)
        }
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
