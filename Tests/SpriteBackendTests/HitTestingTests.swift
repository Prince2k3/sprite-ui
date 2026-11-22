import ECSCore
import SpriteBackend
import SpriteKit
import Testing

@MainActor
@Suite struct HitTestingTests {
    private func square(_ name: String, at position: SIMD2<Float>, size: Float = 40, z: Float = 0) -> Entity {
        let entity = Entity(name: name, components: SpriteComponent(color: .red, size: [size, size]))
        entity.position = position
        entity.transform.zPosition = z
        return entity
    }

    @Test func hitsSpritesContainingThePoint() {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        world.addEntity(square("a", at: [0, 0]))
        world.addEntity(square("b", at: [100, 0]))
        renderer.flush()

        #expect(renderer.entities(at: CGPoint(x: 10, y: -10)).map(\.name) == ["a"])
        #expect(renderer.entities(at: CGPoint(x: 110, y: 15)).map(\.name) == ["b"])
        #expect(renderer.entities(at: CGPoint(x: 50, y: 0)).isEmpty)
    }

    @Test func frontMostComesFirst() {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        world.addEntity(square("back", at: .zero, z: 1))
        world.addEntity(square("front", at: .zero, z: 2))
        world.addEntity(square("later", at: .zero, z: 1))
        renderer.flush()

        #expect(renderer.entities(at: .zero).map(\.name) == ["front", "later", "back"])
    }

    @Test func childrenAreHitInTheirParentsSpace() {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        let parent = Entity(name: "parent")
        parent.position = [100, 100]
        parent.transform.rotation = .pi / 2
        let child = square("child", at: [50, 0], size: 20)
        parent.addChild(child)
        world.addEntity(parent)
        renderer.flush()

        // Rotated a quarter turn, the child's +x offset points up in the scene.
        #expect(renderer.entities(at: CGPoint(x: 100, y: 150)).map(\.name) == ["child"])
        #expect(renderer.entities(at: CGPoint(x: 150, y: 100)).isEmpty)
    }

    @Test func inputTargetSkipsEntitiesWithoutTheComponent() {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        let target = square("target", at: .zero, z: 1)
        target.components.set(InputTargetComponent())
        world.addEntity(target)
        world.addEntity(square("cover", at: .zero, z: 2))
        renderer.flush()

        #expect(renderer.entities(at: .zero).first?.name == "cover")
        #expect(renderer.inputTarget(at: .zero) === target)
    }

    @Test func hiddenAndTransparentSpritesAreSkipped() {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        let faded = square("faded", at: .zero)
        faded.components[SpriteComponent.self]?.opacity = 0
        world.addEntity(faded)
        renderer.flush()

        #expect(renderer.entities(at: .zero).isEmpty)
    }
}
