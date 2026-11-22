import ECSCore
import SpriteBackend
import SpriteKit
import Testing

@MainActor
@Suite struct SpriteRendererTests {
    @Test func addingAnEntityCreatesANodeWithItsTransform() {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        let entity = Entity(components: Transform(translation: [10, 20], rotation: 1, zPosition: 3))
        world.addEntity(entity)

        let node = try! #require(renderer.node(for: entity))
        #expect(node.parent === renderer)
        #expect(node.position == CGPoint(x: 10, y: 20))
        #expect(node.zRotation == 1)
        #expect(node.zPosition == 3)
    }

    @Test func entitiesAddedBeforeTheRendererAreMirrored() {
        let world = World()
        let entity = Entity()
        world.addEntity(entity)
        let renderer = SpriteRenderer(world: world)
        #expect(renderer.node(for: entity) != nil)
    }

    @Test func changesAreBatchedUntilFlush() {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        let entity = Entity()
        world.addEntity(entity)
        let node = renderer.node(for: entity)!

        entity.position = [5, 5]
        #expect(node.position == .zero)

        renderer.flush()
        #expect(node.position == CGPoint(x: 5, y: 5))
    }

    @Test func childEntitiesGetChildNodes() {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        let parent = Entity(), child = Entity()
        parent.addChild(child)
        world.addEntity(parent)
        #expect(renderer.node(for: child)?.parent === renderer.node(for: parent))
    }

    @Test func spriteComponentAddsAndRemovesASpriteNode() {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        let entity = Entity(components: SpriteComponent(color: .red, size: [40, 20], opacity: 0.5))
        world.addEntity(entity)
        let node = renderer.node(for: entity)!

        let sprite = try! #require(node.children.first as? SKSpriteNode)
        #expect(sprite.size == CGSize(width: 40, height: 20))
        #expect(sprite.alpha == 0.5)

        entity.components[SpriteComponent.self]?.size = [80, 80]
        renderer.flush()
        #expect(sprite.size == CGSize(width: 80, height: 80))

        entity.components[SpriteComponent.self] = nil
        renderer.flush()
        #expect(node.children.isEmpty)
    }

    @Test func removingAnEntityRemovesItsNode() {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        let entity = Entity()
        world.addEntity(entity)
        let node = renderer.node(for: entity)!

        world.removeEntity(entity)
        #expect(node.parent == nil)
        #expect(renderer.node(for: entity) == nil)
    }

    @Test func updateRunsSystemsThenFlushes() {
        struct Drift: Component {}
        struct DriftSystem: System {
            init(world: World) {}
            func update(context: UpdateContext) {
                for e in context.entities(matching: .init(where: .has(Drift.self))) {
                    e.position.x += 1
                }
            }
        }
        let world = World()
        world.addSystem(DriftSystem.self)
        let renderer = SpriteRenderer(world: world)
        let entity = Entity(components: Drift())
        world.addEntity(entity)

        renderer.update(0)
        renderer.update(1.0 / 60)
        #expect(renderer.node(for: entity)?.position.x == 2)
    }
}
