import ECSCore
import Foundation
@testable import SpriteBackend
import SpriteKit
import Testing

private struct Health: Component, Equatable { var hp: Int }
private struct Coin: Component, Equatable { var points: Int }

/// A scene like one made in the editor: a ground, a crate with a body, a coin with
/// User Data, and a group node with a child.
@MainActor
private func makeScene() -> SKScene {
    let scene = SKScene(size: CGSize(width: 400, height: 300))
    scene.name = "level"
    scene.anchorPoint = .zero
    scene.backgroundColor = .blue

    let ground = SKSpriteNode(color: .green, size: CGSize(width: 400, height: 20))
    ground.name = "ground"
    ground.position = CGPoint(x: 200, y: 10)
    ground.physicsBody = SKPhysicsBody(rectangleOf: ground.size)
    ground.physicsBody!.isDynamic = false
    ground.physicsBody!.friction = 0.8
    scene.addChild(ground)

    let crate = SKSpriteNode(texture: SKTexture(imageNamed: "crate"), size: CGSize(width: 30, height: 30))
    crate.name = "crate"
    crate.position = CGPoint(x: 120, y: 80)
    crate.zRotation = 0.3
    crate.zPosition = 2
    crate.physicsBody = SKPhysicsBody(rectangleOf: crate.size)
    crate.setScale(1.5)
    crate.color = .red
    crate.colorBlendFactor = 0.25
    crate.anchorPoint = CGPoint(x: 0.5, y: 0)
    crate.physicsBody!.restitution = 0.4
    crate.physicsBody!.categoryBitMask = 0b10
    crate.physicsBody!.contactTestBitMask = 0b100
    crate.userData = ["hp": 3]
    scene.addChild(crate)

    let group = SKNode()
    group.name = "coins"
    group.position = CGPoint(x: 300, y: 150)
    let coin = SKSpriteNode(color: .yellow, size: CGSize(width: 16, height: 16))
    coin.name = "coin"
    coin.alpha = 0.5
    coin.physicsBody = SKPhysicsBody(circleOfRadius: 8)
    coin.physicsBody!.affectedByGravity = false
    coin.userData = ["points": 25, "spin": 1.5, "rare": true, "label": "gold"]
    group.addChild(coin)
    scene.addChild(group)

    let label = SKLabelNode(text: "hi")
    label.name = "label"
    label.position = CGPoint(x: 5, y: 6)
    label.addChild(SKNode())
    scene.addChild(label)
    return scene
}

/// Writes a node the way Xcode saves an `.sks` file.
@MainActor
private func write(_ node: SKNode) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SceneLoadingTests-\(UUID().uuidString).sks")
    try NSKeyedArchiver.archivedData(withRootObject: node, requiringSecureCoding: false).write(to: url)
    return url
}

@MainActor @Suite struct SceneLoadingTests {
    @Test func nodesBecomeEntitiesWithTheSameTree() throws {
        let root = try Entity.load(contentsOf: write(makeScene()))
        #expect(root.name == "level")
        #expect(root.children.map(\.name) == ["ground", "crate", "coins", "label"])
        #expect(root.findEntity(named: "coins")?.children.map(\.name) == ["coin"])
        #expect(root.findEntity(named: "label")?.children.count == 1)

        let scene = try #require(root.components[SceneComponent.self])
        #expect(scene.size == [400, 300])
        // An anchor of (0, 0) puts the scene's origin at the bottom left of a centered view.
        #expect(root.position == [-200, -150])
        #expect(root.findEntity(named: "ground")?.scenePosition == [0, -140])
    }

    @Test func transformsComeFromNodes() throws {
        let root = try Entity.load(contentsOf: write(makeScene()))
        let crate = try #require(root.findEntity(named: "crate"))
        #expect(crate.position == [120, 80])
        #expect(abs(crate.transform.rotation - 0.3) < 1e-6)
        #expect(crate.transform.scale == [1.5, 1.5])
        #expect(crate.transform.zPosition == 2)
        #expect(root.findEntity(named: "label")?.position == [5, 6])
    }

    @Test func spritesKeepTheirLook() throws {
        let root = try Entity.load(contentsOf: write(makeScene()))
        let crate = try #require(root.findEntity(named: "crate")?.components[SpriteComponent.self])
        #expect(crate.imageName == "crate")
        #expect(crate.size == [30, 30])
        #expect(crate.anchorPoint == [0.5, 0])
        #expect(crate.colorBlendFactor == 0.25)

        let coin = try #require(root.findEntity(named: "coin")?.components[SpriteComponent.self])
        #expect(coin.imageName == nil && coin.image == nil)
        #expect(coin.size == [16, 16])
        #expect(coin.opacity == 0.5)
        #expect(root.findEntity(named: "label")?.components.has(SpriteComponent.self) == false)
    }

    @Test func bodiesKeepTheirShapeAndSettings() throws {
        let root = try Entity.load(contentsOf: write(makeScene()))
        let ground = try #require(root.findEntity(named: "ground")?.components[PhysicsBodyComponent.self])
        #expect(ground.shape == .rectangle(size: [400, 20]))
        #expect(!ground.isDynamic)
        #expect(abs(ground.friction - 0.8) < 1e-6)

        let crate = try #require(root.findEntity(named: "crate")?.components[PhysicsBodyComponent.self])
        #expect(crate.shape == .rectangle(size: [30, 30]))
        #expect(crate.isDynamic)
        #expect(abs(crate.restitution - 0.4) < 1e-6)
        #expect(crate.categoryBitMask == 0b10 && crate.contactTestBitMask == 0b100)

        let coin = try #require(root.findEntity(named: "coin")?.components[PhysicsBodyComponent.self])
        #expect(coin.shape == .circle(radius: 8))
        #expect(!coin.affectedByGravity)
    }

    @Test func otherBodiesBecomeCirclesOfTheSameArea() {
        let node = SKNode()
        node.physicsBody = SKPhysicsBody(circleOfRadius: 12)
        guard case .circle(let radius) = SceneLoader.physicsShape(of: node.physicsBody!, on: node) else {
            Issue.record("expected a circle")
            return
        }
        #expect(abs(radius - 12) < 1e-3)

        // A body made after scaling, from the scaled size, keeps that size.
        let sprite = SKSpriteNode(color: .white, size: CGSize(width: 10, height: 20))
        sprite.setScale(2)
        sprite.physicsBody = SKPhysicsBody(rectangleOf: sprite.size)
        #expect(SceneLoader.physicsShape(of: sprite.physicsBody!, on: sprite) == .rectangle(size: [20, 40]))
        #expect(SceneLoader.spriteComponent(from: sprite).size == [10, 20])
    }

    @Test func userDataIsKeptAndTyped() throws {
        let root = try Entity.load(contentsOf: write(makeScene()))
        let data = try #require(root.findEntity(named: "coin")?.components[SceneUserDataComponent.self])
        #expect(data["points"] == .int(25))
        #expect(data["spin"] == .double(1.5))
        #expect(data["rare"] == .bool(true))
        #expect(data["label"] == .string("gold"))
        #expect(data["spin"]?.float == 1.5)
        #expect(data["points"]?.double == 25)
        #expect(root.findEntity(named: "ground")?.components.has(SceneUserDataComponent.self) == false)
    }

    @Test func registeredKeysMakeComponents() throws {
        var loader = SceneLoader()
        loader.register("hp") { Health(hp: $0.int ?? 1) }
        loader.register("points") { value in value.int.map { Coin(points: $0) } }
        loader.register("label") { _ in nil }
        let root = try loader.load(contentsOf: write(makeScene()))
        #expect(root.findEntity(named: "crate")?.components[Health.self] == Health(hp: 3))
        #expect(root.findEntity(named: "coin")?.components[Coin.self] == Coin(points: 25))
        #expect(root.findEntity(named: "ground")?.components.has(Health.self) == false)
    }

    @Test func aPlainNodeFileLoadsToo() throws {
        let node = SKNode()
        node.position = CGPoint(x: 3, y: 4)
        node.addChild(SKSpriteNode(color: .white, size: CGSize(width: 2, height: 2)))
        let url = try write(node)
        let root = try Entity.load(contentsOf: url)
        #expect(root.name == url.deletingPathExtension().lastPathComponent)
        #expect(root.position == [3, 4])
        #expect(!root.components.has(SceneComponent.self))
        #expect(root.children.first?.components[SpriteComponent.self]?.size == [2, 2])
    }

    @Test func missingAndBrokenFilesThrow() throws {
        #expect(throws: SceneLoadingError.notFound("Nope")) {
            try Entity.load(named: "Nope", in: Bundle(for: SKNode.self))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("broken-\(UUID().uuidString).sks")
        try Data("not a scene".utf8).write(to: url)
        #expect(throws: SceneLoadingError.unreadable(url)) { try Entity.load(contentsOf: url) }
    }

    @Test func loadedScenesRender() throws {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        let root = try Entity.load(contentsOf: write(makeScene()))
        world.addEntity(root)
        let crate = try #require(root.findEntity(named: "crate"))
        let node = try #require(renderer.node(for: crate))
        #expect(node.position == CGPoint(x: 120, y: 80))
        #expect(node.physicsBody != nil)
        #expect(node.parent === renderer.node(for: root))
    }

    @Test func texturesWithoutANameKeepTheirPixels() throws {
        let pixels: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 128]
        let image = SpriteImage(width: 2, height: 1, pixels: pixels, smoothsScaling: false)
        let texture = try #require(SpriteRenderer.makeTexture(image))
        #expect(SceneLoader.textureName(texture) == nil)
        let back = try #require(SceneLoader.spriteImage(texture))
        #expect(back.width == 2 && back.height == 1)
        #expect(Array(back.pixels[0..<4]) == [255, 0, 0, 255])
        #expect(back.pixels[7] == 128 && back.pixels[5] >= 254)
        #expect(!back.smoothsScaling)
    }
}
