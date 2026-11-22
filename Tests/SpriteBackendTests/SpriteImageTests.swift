import ECSCore
import SpriteBackend
import SpriteKit
import Testing

@MainActor
@Suite struct SpriteImageTests {
    private let red2x1 = SpriteImage(width: 2, height: 1, pixels: [255, 0, 0, 255, 255, 0, 0, 255], smoothsScaling: false)

    @Test func imagesBecomeTexturesAtTheirOwnSize() throws {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        let entity = Entity(components: SpriteComponent(image: red2x1))
        world.addEntity(entity)
        renderer.flush()

        let sprite = try #require(renderer.node(for: entity)?.childNode(withName: "__sprite") as? SKSpriteNode)
        let texture = try #require(sprite.texture)
        #expect(texture.size() == CGSize(width: 2, height: 1))
        #expect(texture.filteringMode == .nearest)
        #expect(sprite.size == CGSize(width: 2, height: 1))
    }

    @Test func changingTheImageSwapsTheTexture() throws {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        let entity = Entity(components: SpriteComponent(image: red2x1, size: [40, 20]))
        world.addEntity(entity)
        renderer.flush()
        let sprite = try #require(renderer.node(for: entity)?.childNode(withName: "__sprite") as? SKSpriteNode)
        let first = sprite.texture

        entity.components[SpriteComponent.self]?.image = SpriteImage(width: 1, height: 1, pixels: [0, 0, 255, 255])
        renderer.flush()
        #expect(sprite.texture !== first)
        #expect(sprite.texture?.size() == CGSize(width: 1, height: 1))
        #expect(sprite.size == CGSize(width: 40, height: 20))
    }
}
