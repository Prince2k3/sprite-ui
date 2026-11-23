import ECSCore
import SpriteKit
import SwiftUI
import Testing
@testable import SpriteBackend

@MainActor @Suite struct MaskImportTests {
    private func load(_ node: SKNode) throws -> Entity {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sks")
        defer { try? FileManager.default.removeItem(at: url) }
        try NSKeyedArchiver.archivedData(withRootObject: node, requiringSecureCoding: false).write(to: url)
        return try Entity.load(contentsOf: url)
    }

    @Test func archivedCropImportsArtworkSeparatelyFromItsEntityChildren() throws {
        let crop = SKCropNode(); crop.name = "viewport"; crop.position = CGPoint(x: 20, y: 30); crop.alpha = 0.4
        let artwork = SKNode(); artwork.name = "artwork"; artwork.position = CGPoint(x: 10, y: 0)
        let circle = SKShapeNode(circleOfRadius: 12); circle.fillColor = .black; circle.strokeColor = .clear
        artwork.addChild(circle); crop.maskNode = artwork
        let child = SKSpriteNode(color: .red, size: CGSize(width: 80, height: 80)); child.name = "content"; crop.addChild(child)
        let entity = try load(crop)
        #expect(entity.name == "viewport" && entity.position == [20, 30])
        #expect(entity.children.map(\.name) == ["content"] && entity.findEntity(named: "artwork") == nil)
        #expect(entity.components[MaskComponent.self]?.opacity == 1)
        #expect(abs((entity.components[RenderGroupComponent.self]?.opacity ?? 0) - 0.4) < 0.001)
        let world = World(), renderer = SpriteRenderer(world: world)
        world.addEntity(entity)
        let target = try #require(entity.children.first); target.components.set(InputTargetComponent()); renderer.flush()
        #expect(renderer.inputTarget(at: CGPoint(x: 30, y: 30)) === target)
        #expect(renderer.inputTarget(at: CGPoint(x: 0, y: 30)) == nil)
    }

    @Test func strokedArtworkImportsAsAHoleAndUnmaskedCropsPassThrough() throws {
        let crop = SKCropNode(), ring = SKShapeNode(circleOfRadius: 20)
        ring.fillColor = .clear; ring.strokeColor = .black; ring.lineWidth = 6; crop.maskNode = ring
        crop.addChild(SKSpriteNode(color: .cyan, size: CGSize(width: 80, height: 80)))
        let entity = try load(crop), world = World(), renderer = SpriteRenderer(world: world)
        entity.components.set(InputTargetComponent()); world.addEntity(entity)
        #expect(renderer.inputTarget(at: .zero) == nil)
        #expect(renderer.inputTarget(at: CGPoint(x: 20, y: 0)) != nil)
        #expect(renderer.inputTarget(at: CGPoint(x: 30, y: 0)) == nil)
        let plain = SKCropNode(); plain.addChild(SKSpriteNode(color: .green, size: CGSize(width: 10, height: 10)))
        #expect(try load(plain).components[MaskComponent.self] == nil)
    }

    @Test func nestedCropsRemainNestedEntitiesAndIntersect() throws {
        let outer = SKCropNode(), inner = SKCropNode()
        let left = SKShapeNode(rect: CGRect(x: -20, y: -20, width: 20, height: 40)); left.fillColor = .white; left.strokeColor = .clear
        outer.maskNode = left
        let top = SKShapeNode(rect: CGRect(x: -20, y: 0, width: 40, height: 20)); top.fillColor = .white; top.strokeColor = .clear
        inner.maskNode = top; inner.name = "inner"; outer.addChild(inner)
        inner.addChild(SKSpriteNode(color: .orange, size: CGSize(width: 80, height: 80)))
        let entity = try load(outer), world = World(), renderer = SpriteRenderer(world: world)
        entity.components.set(InputTargetComponent()); world.addEntity(entity)
        #expect(entity.components.has(MaskComponent.self) && entity.children.first?.components.has(MaskComponent.self) == true)
        #expect(renderer.inputTarget(at: CGPoint(x: -10, y: 10)) != nil)
        #expect(renderer.inputTarget(at: CGPoint(x: 10, y: 10)) == nil)
        #expect(renderer.inputTarget(at: CGPoint(x: -10, y: -10)) == nil)
    }

    @Test func unsupportedMaskArtworkFailsExplicitlyInsteadOfRevealingContent() throws {
        let crop = SKCropNode(); crop.maskNode = SKLabelNode(text: "Unsupported glyph mask")
        crop.addChild(SKSpriteNode(color: .red, size: CGSize(width: 80, height: 80)))
        #expect(throws: SceneLoadingError.self) { try load(crop) }
        do { _ = try SceneLoader().entity(from: crop); Issue.record("Unsupported mask was accepted") }
        catch SceneLoadingError.unsupportedMask(let reason) { #expect(reason.contains("unsupported node type")) }
        catch { Issue.record("Wrong mask error: \(error)") }
    }

    @Test func stretchedTextureMasksAreRejectedBeforeLosingTheirAlphaLayout() throws {
        let texture = SKTexture(data: Data([UInt8](repeating: 255, count: 16)), size: CGSize(width: 2, height: 2))
        let sprite = SKSpriteNode(texture: texture); sprite.centerRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let crop = SKCropNode(); crop.maskNode = sprite
        do { _ = try SceneLoader().entity(from: crop); Issue.record("Nine-slice mask was accepted") }
        catch SceneLoadingError.unsupportedMask(let reason) { #expect(reason.contains("nine-slice")) }
        catch { Issue.record("Wrong mask error: \(error)") }
    }

    @Test func invalidMaskCornerRadiiFailClosedWithoutChangingShapeRendering() {
        let world = World(), renderer = SpriteRenderer(world: world)
        let entity = Entity(components: SpriteComponent(color: .red, size: [40, 40]), InputTargetComponent())
        world.addEntity(entity)
        for radius: Float in [.nan, .infinity, -1] {
            entity.components.set(MaskComponent(shape: .roundedRectangle(size: [40, 40], cornerRadius: radius)))
            renderer.flush()
            #expect(!renderer.isPointVisible(.zero, throughMasksOf: entity))
            #expect(renderer.inputTarget(at: .zero) == nil)
        }
        entity.components[MaskComponent.self]?.isEnabled = false; renderer.flush()
        #expect(renderer.inputTarget(at: .zero) === entity)
    }
}
