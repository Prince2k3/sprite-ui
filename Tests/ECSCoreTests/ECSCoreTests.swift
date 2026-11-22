@_spi(Backend) import ECSCore
import Testing

struct Health: Component { var hp: Int }
struct Dead: Component {}
struct Velocity: Component { var value: SIMD2<Float> }

struct MoveSystem: System {
    static let query = EntityQuery(where: .has(Velocity.self))
    init(world: World) {}
    func update(context: UpdateContext) {
        for entity in context.entities(matching: Self.query) {
            let v = entity.components[Velocity.self]!.value
            entity.position += v * Float(context.deltaTime)
        }
    }
}

struct CountingSystem: System {
    var frames = 0
    init(world: World) {}
    mutating func update(context: UpdateContext) { frames += 1 }
}

@MainActor
final class RecordingObserver: WorldObserver {
    var added: [Entity.ID] = []
    var removed: [Entity.ID] = []
    var changed: [(Entity.ID, ObjectIdentifier)] = []

    func world(_ world: World, didAdd entity: Entity) { added.append(entity.id) }
    func world(_ world: World, willRemove entity: Entity) { removed.append(entity.id) }
    func world(_ world: World, entity: Entity, didChange componentType: any Component.Type, transaction: ActionTransaction?) {
        changed.append((entity.id, ObjectIdentifier(componentType)))
    }
}

@MainActor
@Suite struct EntityTests {
    @Test func entitiesStartWithIdentityTransform() {
        let entity = Entity()
        #expect(entity.transform == .identity)
        #expect(entity.components.has(Transform.self))
    }

    @Test func componentsCanBeSetMutatedAndRemoved() {
        let entity = Entity(components: Health(hp: 3))
        entity.components[Health.self]?.hp -= 1
        #expect(entity.components[Health.self]?.hp == 2)

        entity.components[Health.self] = nil
        #expect(!entity.components.has(Health.self))
    }

    @Test func idsAreUnique() {
        #expect(Entity().id != Entity().id)
    }

    @Test func childrenTrackParent() {
        let parent = Entity(), child = Entity()
        parent.addChild(child)
        #expect(child.parent === parent)
        #expect(parent.children.count == 1)

        child.removeFromParent()
        #expect(child.parent == nil)
        #expect(parent.children.isEmpty)
    }

    @Test func reparentingMovesTheChild() {
        let a = Entity(), b = Entity(), child = Entity()
        a.addChild(child)
        b.addChild(child)
        #expect(a.children.isEmpty)
        #expect(child.parent === b)
    }
}

@MainActor
@Suite struct WorldTests {
    @Test func queriesCombinePredicates() {
        let world = World()
        let alive = Entity(components: Health(hp: 1))
        let dead = Entity(components: Health(hp: 0), Dead())
        world.addEntity(alive)
        world.addEntity(dead)

        let living = world.performQuery(EntityQuery(where: .has(Health.self) && !.has(Dead.self)))
        #expect(living.map(\.id) == [alive.id])
        #expect(world.performQuery(EntityQuery()).count == 2)
    }

    @Test func nestedEntitiesJoinAndLeaveWithTheirParent() {
        let world = World()
        let parent = Entity(), child = Entity(components: Health(hp: 1))
        parent.addChild(child)
        world.addEntity(parent)
        #expect(child.world === world)
        #expect(world.performQuery(EntityQuery(where: .has(Health.self))).count == 1)

        world.removeEntity(parent)
        #expect(child.world == nil)
        #expect(world.allEntities.isEmpty)
    }

    @Test func systemsRunWithDeltaTime() {
        let world = World()
        world.addSystem(MoveSystem.self)
        let entity = Entity(components: Velocity(value: [10, 0]))
        world.addEntity(entity)

        world.update(deltaTime: 0.5)
        #expect(entity.position == [5, 0])
    }

    @Test func updateEventFiresOncePerFrame() {
        let world = World()
        world.addSystem(CountingSystem.self)
        var seen = 0
        let sub = world.subscribe(to: WorldEvents.Update.self) { _ in seen += 1 }
        world.update(deltaTime: 0.016)
        world.update(deltaTime: 0.016)
        #expect(seen == 2)
        _ = sub
    }

    @Test func componentEventsFireAndCanBeFilteredByEntity() {
        let world = World()
        let a = Entity(), b = Entity()
        world.addEntity(a)
        world.addEntity(b)

        var addedToA = 0
        let sub = world.subscribe(to: ComponentEvents.DidAdd.self, on: a) { _ in addedToA += 1 }
        a.components.set(Health(hp: 1))
        b.components.set(Health(hp: 1))
        a.components[Health.self]?.hp = 5   // a change, not an add
        #expect(addedToA == 1)
        _ = sub
    }

    @Test func droppedSubscriptionsStopReceiving() {
        let world = World()
        var count = 0
        var sub: EventSubscription? = world.subscribe(to: WorldEvents.Update.self) { _ in count += 1 }
        world.update(deltaTime: 0)
        sub = nil
        world.update(deltaTime: 0)
        #expect(count == 1)
        _ = sub
    }

    @Test func cancelledSubscriptionsStopReceiving() {
        let world = World()
        var count = 0
        let sub = world.subscribe(to: WorldEvents.Update.self) { _ in count += 1 }
        sub.cancel()
        world.update(deltaTime: 0)
        #expect(count == 0)
    }

    @Test func handlersCanPublishSubscribeAndRemoveEntities() {
        // Removing an entity publishes WillRemoveEntity from inside this handler, and
        // subscribing mutates the bus — neither may conflict with the publish in flight.
        let world = World()
        let doomed = Entity()
        world.addEntity(doomed)
        var removed = 0, late: EventSubscription?
        let onRemove = world.subscribe(to: WorldEvents.WillRemoveEntity.self) { _ in removed += 1 }
        let onUpdate = world.subscribe(to: WorldEvents.Update.self) { _ in
            world.removeEntity(doomed)
            late = world.subscribe(to: WorldEvents.Update.self) { _ in }
        }
        world.update(deltaTime: 0)
        #expect(removed == 1)
        #expect(doomed.world == nil)
        _ = (onRemove, onUpdate, late)
    }

    @Test func observerSeesAddsChangesAndRemovesInOrder() {
        let world = World()
        let observer = RecordingObserver()
        world.observer = observer

        let parent = Entity(), child = Entity()
        parent.addChild(child)
        world.addEntity(parent)
        #expect(observer.added == [parent.id, child.id])

        child.position = [1, 2]
        #expect(observer.changed.last?.0 == child.id)
        #expect(observer.changed.last?.1 == ObjectIdentifier(Transform.self))

        world.removeEntity(parent)
        #expect(observer.removed == [child.id, parent.id])
    }

    @Test func silentWritesDoNotNotify() {
        let world = World()
        let observer = RecordingObserver()
        world.observer = observer
        let entity = Entity()
        world.addEntity(entity)

        var t = entity.transform
        t.translation = [3, 3]
        entity._setWithoutNotifying(t)
        #expect(observer.changed.isEmpty)
        #expect(entity.position == [3, 3])
    }
}
