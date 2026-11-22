import ECSCore
import Foundation
@testable import SpriteBackend
import SpriteKit
import SwiftUI
import Testing

private func roundTrip<T: Codable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

private func rgba(_ color: Color) -> [Float] {
    ColorCoding.components(of: color).map { ($0 * 255).rounded() }
}

@MainActor @Suite struct BackendSnapshotTests {
    @Test func spritesKeepTheirLook() throws {
        let image = SpriteImage(width: 1, height: 2, pixels: [1, 2, 3, 4, 5, 6, 7, 8], smoothsScaling: false)
        var sprite = SpriteComponent(image: image, size: [10, 20], tint: .red, tintAmount: 0.5, opacity: 0.25)
        sprite.anchorPoint = [0, 1]
        let copy = try roundTrip(sprite)
        #expect(copy.image == image)
        #expect(copy.size == [10, 20] && copy.anchorPoint == [0, 1])
        #expect(copy.colorBlendFactor == 0.5 && copy.opacity == 0.25)
        #expect(rgba(copy.color) == rgba(.red))

        let plain = try roundTrip(SpriteComponent(color: .blue, size: [3, 4]))
        #expect(plain.image == nil && plain.imageName == nil && rgba(plain.color) == rgba(.blue))
        let named = try roundTrip(SpriteComponent(imageName: "hero"))
        #expect(named.imageName == "hero" && named.size == nil)
    }

    @Test func badPixelDataIsAnError() {
        let json = #"{"width":2,"height":2,"pixels":"AAAA","smoothsScaling":true}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(SpriteImage.self, from: Data(json.utf8)) }
    }

    @Test func physicsAndSceneDataRoundTrip() throws {
        let body = PhysicsBodyComponent(shape: .polygon([[0, 0], [1, 0], [0, 1]]), mass: 2,
                                        contactTestBitMask: 3, velocity: [5, 6], angularVelocity: 1)
        #expect(try roundTrip(body) == body)
        #expect(try roundTrip(PhysicsShape.circle(radius: 4)) == .circle(radius: 4))
        let data = SceneUserDataComponent(["a": .int(1), "b": .double(1.5), "c": .bool(true), "d": .string("x")])
        #expect(try roundTrip(data) == data)
    }

    @Test func tileMapsRoundTrip() throws {
        let floor = TileMapComponent.Tile(name: "Floor", color: .gray, userData: ["cost": .int(1)])
        let wall = TileMapComponent.Tile(name: "Wall", imageName: "wall")
        let map = TileMapComponent(tileSize: [16, 16], tiles: [floor, wall], legend: [".": 0, "#": 1],
                                   rows: ["#.#", "..."])
        let copy = try roundTrip(map)
        #expect(copy.cells == map.cells && copy.columns == 3 && copy.rows == 2)
        #expect(copy.tiles.map(\.name) == ["Floor", "Wall"])
        #expect(copy.tiles[0]["cost"] == .int(1) && copy.tiles[1].imageName == "wall")
        #expect(rgba(copy.tiles[0].color) == rgba(.gray))
    }

    @Test func rendererRegistersItsComponents() {
        _ = SpriteRenderer(world: World())
        #expect(ComponentRegistry.isRegistered(SpriteComponent.self))
        #expect(ComponentRegistry.isRegistered(PhysicsBodyComponent.self))
        #expect(ComponentRegistry.isRegistered(CameraComponent.self))
        #expect(ComponentRegistry.isRegistered(TileMapComponent.self))
        #expect(!ComponentRegistry.isRegistered(ParticleEmitterComponent.self))
    }

    @Test func restoredWorldGetsNewNodes() throws {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        let ball = Entity(name: "ball", components:
            SpriteComponent(color: .orange, size: [8, 8]),
            PhysicsBodyComponent(shape: .circle(radius: 4)))
        ball.position = [30, 40]
        let camera = Entity(name: "camera", components: CameraComponent(target: .entity(ball.id)))
        world.addEntity(ball)
        world.addEntity(camera)
        renderer.flush()
        let oldNode = try #require(renderer.node(for: ball))

        let saved = try WorldSnapshot(data: world.snapshot().jsonData())
        ball.position = [0, 0]
        world.restore(saved)
        renderer.flush()

        let newBall = try #require(world.entity(withID: ball.id))
        let node = try #require(renderer.node(for: newBall))
        #expect(node !== oldNode && oldNode.parent == nil)
        #expect(node.position == CGPoint(x: 30, y: 40))
        #expect(node.physicsBody != nil)
        // The camera still points at the ball, because restored IDs are kept.
        let target = world.entities.first { $0.name == "camera" }?.components[CameraComponent.self]?.target
        #expect(target == .entity(newBall.id))
    }
}
