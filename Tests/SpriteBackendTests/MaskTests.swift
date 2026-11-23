import CoreImage
import ECSCore
import Foundation
import SpriteKit
import SwiftUI
import Testing
@testable import SpriteBackend

@MainActor @Suite struct MaskTests {
    private func crop(_ renderer: SpriteRenderer, _ entity: Entity) throws -> MaskCropNode {
        let node = try #require(renderer.node(for: entity))
        return try #require(SpriteRenderer.contentRoot(node) as? MaskCropNode)
    }

    private func pixels(_ view: SKView, node: SKNode) throws -> CIImage {
        let texture = try #require(view.texture(from: node, crop: CGRect(x: -32, y: -32, width: 64, height: 64)))
        return CIImage(cgImage: texture.cgImage())
    }

    private func pixel(_ image: CIImage, x: CGFloat = 0, y: CGFloat = 0) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes {
            CIContext(options: [.useSoftwareRenderer: true]).render(image, toBitmap: $0.baseAddress!, rowBytes: 4,
                bounds: CGRect(x: image.extent.minX + (x + 32) * image.extent.width / 64,
                               y: image.extent.minY + (y + 32) * image.extent.height / 64, width: 1, height: 1), format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        return bytes
    }

    private func alphaTexture(smooth: Bool = false) -> TextureResource {
        TextureResource(image: SpriteImage(width: 2, height: 2,
            pixels: [255, 255, 255, 255, 255, 255, 255, 0,
                     255, 255, 255, 64, 255, 255, 255, 0], smoothsScaling: smooth))
    }

    @Test func shapeTextSpriteAndExplicitColliderSubtreesObeyWorldMask() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let parent = Entity(components: MaskComponent(shape: .rectangle(size: [20, 80])))
        let sprite = Entity(components: SpriteComponent(color: .white, size: [60, 60]))
        let shape = Entity(components: ShapeComponent(.circle(radius: 30), fill: .white))
        let text = Entity(components: TextComponent("MMMM", font: .named("Helvetica", size: 32)))
        let collider = Entity(components: CollisionComponent(shape: .circle(radius: 30)), InputTargetComponent())
        for child in [sprite, shape, text, collider] { parent.addChild(child) }
        world.addEntity(parent); renderer.flush()
        let hits = Set(renderer.entities(at: .zero).map(\.id))
        #expect(hits == Set([sprite, shape, text, collider].map(\.id)))
        #expect(renderer.entities(at: CGPoint(x: 20, y: 0)).isEmpty)
        #expect(renderer.inputTarget(at: .zero)?.id == collider.id)
        world.root.components.set(MaskComponent(shape: .circle(radius: 2), transform: Transform(translation: [8, 0])))
        renderer.flush()
        #expect(renderer.entities(at: .zero).isEmpty)
        #expect(!renderer.isPointVisible(.zero, throughMasksOf: collider))
        #expect(renderer.isPointVisible([8, 0], throughMasksOf: collider))
        #expect(renderer.inputTarget(at: CGPoint(x: 8, y: 0))?.id == collider.id)
        #expect(try crop(renderer, world.root).artwork.parent == nil)
    }

    @Test func nestedMasksIntersectAndCompoundLayersUnionInheritedAlpha() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let outer = Entity(components: MaskComponent(shape: .rectangle(size: [20, 80])))
        let inner = Entity(components: MaskComponent(shape: .rectangle(size: [80, 20])))
        outer.addChild(inner); world.addEntity(outer)
        #expect(renderer.isPointVisible([8, 8], throughMasksOf: inner))
        #expect(!renderer.isPointVisible([12, 0], throughMasksOf: inner))
        #expect(!renderer.isPointVisible([0, 12], throughMasksOf: inner))
        let layers = [MaskLayer(.shape(.circle(radius: 4)), transform: Transform(translation: [-2, 0])),
                      MaskLayer(.shape(.circle(radius: 4)), transform: Transform(translation: [2, 0]))]
        inner.components.set(MaskComponent(.group(layers), opacity: 0.03)); renderer.flush()
        let drawing = try crop(renderer, inner).artwork
        // Parent alpha multiplies each leaf BEFORE source-over: .03 + .03 * .97.
        #expect(abs(drawing.coverage(at: .zero) - 0.0591) < 0.00001)
        #expect(renderer.isPointVisible(.zero, throughMasksOf: inner))
        #expect(!renderer.isPointVisible([-5, 0], throughMasksOf: inner))
        inner.components.set(MaskComponent(shape: .circle(radius: 4), opacity: 0.05)); renderer.flush()
        #expect(renderer.isPointVisible(.zero, throughMasksOf: inner))
        inner.components[MaskComponent.self]?.opacity = 0.049; renderer.flush()
        #expect(!renderer.isPointVisible(.zero, throughMasksOf: inner))
        inner.components.set(MaskComponent(.group([MaskLayer(.group(layers), opacity: 0.5)]), opacity: 0.06)); renderer.flush()
        #expect(abs(drawing.coverage(at: .zero) - 0.0591) < 0.00001)
    }

    @Test func textureAlphaUsesTopRowFirstNearestAndLinearSampling() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let entity = Entity(components: MaskComponent(texture: alphaTexture(), size: [20, 20]))
        world.addEntity(entity)
        let drawing = try crop(renderer, entity).artwork
        #expect(drawing.coverage(at: [-5, 5]) == 1)
        #expect(drawing.coverage(at: [5, 5]) == 0)
        #expect(abs(drawing.coverage(at: [-5, -5]) - 64.0 / 255) < 0.00001)
        #expect(drawing.coverage(at: [5, -5]) == 0)
        #expect(!renderer.isPointVisible([0.2, 5], throughMasksOf: entity))
        entity.components.set(MaskComponent(texture: alphaTexture(smooth: true), size: [20, 20])); renderer.flush()
        #expect(abs(drawing.coverage(at: [0, 5]) - 0.5) < 0.00001)
        #expect(renderer.isPointVisible([0.2, 5], throughMasksOf: entity))
        #expect(drawing.coverage(at: [10, 0]) == 0)
        entity.components.set(MaskComponent(texture: alphaTexture(), size: [20, 20], anchorPoint: [0, 0])); renderer.flush()
        #expect(drawing.coverage(at: [5, 15]) == 1)
        #expect(drawing.coverage(at: [-5, 15]) == 0)
    }

    @Test func presentedMaskPoseDrivesInputBeforeFlushAndDuringAnimation() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let entity = Entity(components: MaskComponent(shape: .rectangle(size: [20, 4])),
                            CollisionComponent(shape: .circle(radius: 100)), InputTargetComponent())
        world.addEntity(entity)
        let artwork = try crop(renderer, entity).artwork
        let target = Transform(translation: [30, 10], rotation: .pi / 2, scale: [2, 0.5])
        withAnimation(.linear(duration: 10)) {
            entity.components[MaskComponent.self]?.transform = target
            entity.components[MaskComponent.self]?.opacity = 0.2
        }
        #expect(entity.presentation[MaskComponent.self]?.transform == .identity)
        #expect(renderer.inputTarget(at: .zero)?.id == entity.id)
        renderer.flush()
        for key in ["mask.position", "mask.rotation", "mask.scale", "mask.opacity"] {
            #expect(artwork.action(forKey: key) != nil)
        }
        #expect(entity.presentation[MaskComponent.self]?.transform == .identity)
        #expect(entity.components[MaskComponent.self]?.transform == target)
        // Set the native presentation deterministically, without waiting for wall-clock frames.
        artwork.position = CGPoint(x: 30, y: 10); artwork.zRotation = CGFloat(target.rotation)
        artwork.xScale = 2; artwork.yScale = 0.5; artwork.alpha = 0.2
        #expect(entity.presentation[MaskComponent.self]?.transform == target)
        #expect(entity.presentation[MaskComponent.self]?.opacity == 0.2)
        #expect(renderer.inputTarget(at: CGPoint(x: 30, y: 25))?.id == entity.id)
        #expect(renderer.inputTarget(at: CGPoint(x: 32, y: 10)) == nil)
        #expect(renderer.inputTarget(at: .zero) == nil)
        entity.components.set(MaskComponent(.group([MaskLayer(.shape(.circle(radius: 2)))]))); renderer.flush()
        withAnimation(.linear(duration: 10)) {
            entity.components[MaskComponent.self]?.content = .group([
                MaskLayer(.shape(.circle(radius: 2)), transform: Transform(translation: [15, 0]))])
        }
        renderer.flush()
        let layer = try #require(artwork.children.first as? MaskDrawingNode)
        #expect(layer.position == CGPoint(x: 15, y: 0) && !layer.hasActions())
    }

    @Test func emptyInvalidAndSingularMasksFailClosedButDisabledAndRemovedBypass() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let entity = Entity(components: CollisionComponent(shape: .circle(radius: 10)), InputTargetComponent())
        world.addEntity(entity)
        let invalid: [MaskComponent] = [MaskComponent(.empty), MaskComponent(.group([])),
            MaskComponent(shape: .circle(radius: -1)), MaskComponent(shape: .rectangle(size: [.nan, 10])),
            MaskComponent(texture: alphaTexture(), size: [0, 10]),
            MaskComponent(shape: .circle(radius: 10), transform: Transform(scale: [0, 1])),
            MaskComponent(shape: .circle(radius: 10), transform: Transform(translation: [.infinity, 0])),
            MaskComponent(shape: .circle(radius: 10), opacity: .nan)]
        for value in invalid {
            entity.components.set(value); renderer.flush()
            #expect(!renderer.isPointVisible(.zero, throughMasksOf: entity))
            #expect(renderer.inputTarget(at: .zero) == nil)
            entity.components[MaskComponent.self]?.isEnabled = false; renderer.flush()
            #expect(renderer.isPointVisible(.zero, throughMasksOf: entity))
            #expect(renderer.inputTarget(at: .zero)?.id == entity.id)
        }
        entity.components.remove(MaskComponent.self); renderer.flush()
        #expect(renderer.inputTarget(at: .zero)?.id == entity.id)
        let node = try #require(renderer.node(for: entity))
        #expect(SpriteRenderer.contentRoot(node) === node)
    }

    @Test func wrappingAndUnwrappingPreserveStableNodesBodiesAndActions() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let parent = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 4)), SpriteComponent(color: .white, size: [8, 8]))
        let child = Entity(components: SpriteComponent(color: .white, size: [4, 4]))
        parent.addChild(child); world.addEntity(parent)
        let node = try #require(renderer.node(for: parent)), body = try #require(node.physicsBody)
        let childNode = try #require(renderer.node(for: child))
        let visual = try #require(node.childNode(withName: SpriteRenderer.spriteNodeName))
        #expect((node as? SKEffectNode)?.shouldEnableEffects == false)
        withAnimation(.linear(duration: 10)) { parent.position = [50, 0] }
        renderer.flush()
        parent.components.set(MaskComponent(shape: .circle(radius: 20))); renderer.flush()
        let wrapper = try crop(renderer, parent)
        #expect(renderer.node(for: parent) === node && node.physicsBody === body)
        #expect(childNode.parent === wrapper && visual.parent === wrapper)
        #expect(wrapper.artwork.parent == nil && wrapper.maskNode === wrapper.artwork)
        #expect(node.action(forKey: "transform.position") != nil)
        parent.components.remove(MaskComponent.self); renderer.flush()
        #expect(renderer.node(for: parent) === node && node.physicsBody === body)
        #expect(renderer.node(for: child) === childNode && childNode.parent === node && visual.parent === node)
        #expect(node.action(forKey: "transform.position") != nil && wrapper.parent == nil)
    }

    @Test func maskReparentRebuildsJointsWhilePhysicsQueriesIgnoreClipping() throws {
        let world = World(), renderer = SpriteRenderer(world: world), parent = Entity()
        let a = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 3), isDynamic: false))
        let b = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 3)), InputTargetComponent())
        a.position = [-20, 0]; b.position = [20, 0]; parent.addChild(a); parent.addChild(b)
        let owner = Entity(components: PhysicsJointComponent(bodyA: a.id, bodyB: b.id, constraint: .spring()))
        world.addEntity(parent); world.addEntity(owner); renderer.flush()
        let first = try #require(renderer.jointEntries[owner.id]?.joint)
        let node = try #require(renderer.node(for: b)), body = try #require(node.physicsBody)
        parent.components.set(MaskComponent(.empty)); renderer.flush()
        let second = try #require(renderer.jointEntries[owner.id]?.joint)
        #expect(second !== first && owner.physicsJointStatus == .active)
        #expect(node.physicsBody === body && second.bodyB === body)
        #expect(body.joints.count == 1)
        #expect(renderer.inputTarget(at: CGPoint(x: 20, y: 0)) == nil)
        #expect(world.raycast(from: [10, 0], to: [30, 0]).first?.entity.id == b.id)
        parent.components.remove(MaskComponent.self); renderer.flush()
        let third = try #require(renderer.jointEntries[owner.id]?.joint)
        #expect(third !== second && third.bodyB === body && body.joints.count == 1)
        #expect(owner.physicsJointStatus == .active)
    }

    @Test func addedAndReparentedChildrenUseWrapperAndPhysicsCopybackStaysLocal() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let parent = Entity(components: MaskComponent(shape: .circle(radius: 200)))
        parent.position = [50, 70]; parent.rotation = 0.3; parent.scale = [2, 1.5]; world.addEntity(parent)
        let child = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 3)))
        parent.addChild(child)
        let moved = Entity(components: SpriteComponent(color: .white, size: [4, 4]))
        world.addEntity(moved); parent.addChild(moved); renderer.flush()
        let wrapper = try crop(renderer, parent), node = try #require(renderer.node(for: child))
        #expect(node.parent === wrapper && renderer.node(for: moved)?.parent === wrapper)
        #expect(wrapper.position == .zero && wrapper.xScale == 1 && wrapper.yScale == 1)
        node.position = CGPoint(x: 30, y: -20); node.zRotation = 0.7
        node.physicsBody?.velocity = CGVector(dx: 10, dy: 15); renderer.didSimulatePhysics()
        #expect(child.position == [30, -20] && abs(child.rotation - 0.7) < 0.00001)
        let velocity = try #require(child.components[PhysicsBodyComponent.self]?.velocity)
        #expect(abs(velocity.x - 10) < 0.001 && abs(velocity.y - 15) < 0.001)
        parent.components.remove(MaskComponent.self); renderer.flush()
        #expect(renderer.node(for: child) === node && child.position == [30, -20])
    }

    @Test func renderGroupCoexistsWithOwnSpriteTextOpacityAndPresentationRouting() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let entity = Entity(components: MaskComponent(shape: .circle(radius: 30)), RenderGroupComponent(opacity: 0.6),
                            SpriteComponent(color: .white, size: [20, 20]), TextComponent("Mask"))
        world.addEntity(entity); renderer.flush()
        let node = try #require(renderer.node(for: entity) as? SKEffectNode), wrapper = try crop(renderer, entity)
        let sprite = try #require(wrapper.childNode(withName: SpriteRenderer.spriteNodeName))
        let text = try #require(wrapper.childNode(withName: SpriteRenderer.textNodeName))
        #expect(node.shouldEnableEffects && abs(node.alpha - 0.6) < 0.00001)
        withAnimation(.linear(duration: 10)) {
            entity.components[SpriteComponent.self]?.opacity = 0.2
            entity.components[TextComponent.self]?.opacity = 0.3
            entity.components[MaskComponent.self]?.opacity = 0.4
            entity.components[RenderGroupComponent.self]?.opacity = 0.5
        }
        renderer.flush()
        #expect(sprite.action(forKey: "sprite.opacity") != nil && text.action(forKey: "text.opacity") != nil)
        #expect(wrapper.artwork.action(forKey: "mask.opacity") != nil && node.action(forKey: "renderGroup.opacity") != nil)
        #expect(entity.presentation[SpriteComponent.self]?.opacity == 1 && entity.presentation[TextComponent.self]?.opacity == 1)
        sprite.alpha = 0.7; text.alpha = 0.8; wrapper.artwork.alpha = 0.9
        #expect(entity.presentation[SpriteComponent.self]?.opacity == 0.7)
        #expect(entity.presentation[TextComponent.self]?.opacity == 0.8)
        #expect(entity.presentation[MaskComponent.self]?.opacity == 0.9)
        entity.components.remove(MaskComponent.self); renderer.flush()
        #expect(node.shouldEnableEffects && node.action(forKey: "renderGroup.opacity") != nil)
        #expect(sprite.parent === node && text.parent === node)
        #expect(entity.presentation[TextComponent.self]?.opacity == 0.8)
    }

    @Test func clonesSnapshotsPrefabsAndPoolLeasesOwnIndependentMaskTrees() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let config = MaskComponent(.group([MaskLayer(.texture(alphaTexture(), size: [20, 20], anchorPoint: [0.5, 0.5]))]))
        let original = Entity(name: "masked", components: config, SpriteComponent(color: .white, size: [20, 20]))
        world.addEntity(original)
        let clone = original.clone(), prefab = PrefabResource(root: original)
        let instance = prefab.instantiate(); world.addEntity(clone); world.addEntity(instance); renderer.flush()
        let first = try crop(renderer, original), second = try crop(renderer, clone), third = try crop(renderer, instance)
        #expect(first !== second && second !== third && first.artwork !== third.artwork)
        #expect(first.artwork.children.first !== second.artwork.children.first)
        clone.components[MaskComponent.self]?.content = .empty; renderer.flush()
        #expect(renderer.isPointVisible([-5, 5], throughMasksOf: original))
        #expect(!renderer.isPointVisible([-5, 5], throughMasksOf: clone))
        let saved = try WorldSnapshot(data: world.snapshot().jsonData()); world.restore(saved); renderer.flush()
        let restored = try #require(world.entity(withID: original.id)), restoredCrop = try crop(renderer, restored)
        #expect(restored.components[MaskComponent.self] == config && restoredCrop !== first && first.parent == nil)
        let pool = try EntityPool(prefab: prefab, scene: world, capacity: 2, onAcquire: { $0.components.set(config) })
        let a = try #require(try pool.acquire()), b = try #require(try pool.acquire()); renderer.flush()
        let aCrop = try crop(renderer, a), bCrop = try crop(renderer, b)
        #expect(aCrop !== bCrop && aCrop.artwork !== bCrop.artwork)
        withAnimation(.linear(duration: 10)) { a.components[MaskComponent.self]?.transform.translation = [20, 0] }
        renderer.flush(); #expect(aCrop.artwork.hasActions() && !bCrop.artwork.hasActions())
        try pool.release(a); let reused = try #require(try pool.acquire()); renderer.flush()
        #expect(reused.id == a.id && !aCrop.artwork.hasActions())
        #expect(try crop(renderer, reused) === aCrop && aCrop.artwork.position == .zero)
        #expect(b.components[MaskComponent.self] == config)
    }

    @Test func realPixelsMatchShapeAndTextureMasksWithBinaryCutoff() throws {
        let world = World(), renderer = SpriteRenderer(world: world, size: CGSize(width: 64, height: 64))
        let entity = Entity(components: SpriteComponent(color: .white, size: [64, 64]), MaskComponent(shape: .circle(radius: 12)))
        world.addEntity(entity); renderer.flush()
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 64, height: 64)); view.presentScene(renderer)
        defer { view.presentScene(nil) }
        let node = try #require(renderer.node(for: entity))
        let shape = try pixels(view, node: node)
        #expect(pixel(shape)[3] > 240 && pixel(shape, x: 24)[3] == 0)
        entity.components.set(MaskComponent(texture: alphaTexture(), size: [64, 64])); renderer.flush()
        let texture = try pixels(view, node: node)
        #expect(pixel(texture, x: -16, y: 16)[3] > 240)
        #expect(pixel(texture, x: 16, y: 16)[3] == 0)
        #expect(pixel(texture, x: -16, y: -16)[3] > 240, "64/255 mask alpha reveals full content, without fading it")
        #expect(pixel(texture, x: 16, y: -16)[3] == 0)
        entity.components[MaskComponent.self]?.opacity = 0.01; renderer.flush()
        #expect(pixel(try pixels(view, node: node), x: -16, y: 16)[3] == 0)
    }

    @Test func cropLayerPixelOrderAgreesWithTargetedInput() throws {
        let world = World(), renderer = SpriteRenderer(world: world, size: CGSize(width: 64, height: 64))
        let parent = Entity(components: MaskComponent(shape: .rectangle(size: [64, 64])))
        let child = Entity(components: SpriteComponent(color: Color(.sRGB, red: 1, green: 0, blue: 0), size: [32, 32]), InputTargetComponent())
        child.zPosition = 100; parent.addChild(child)
        let sibling = Entity(components: SpriteComponent(color: Color(.sRGB, red: 0, green: 0, blue: 1), size: [32, 32]), InputTargetComponent())
        sibling.zPosition = 5; world.addEntity(parent); world.addEntity(sibling); renderer.flush()
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 64, height: 64)); view.ignoresSiblingOrder = false
        view.presentScene(renderer)
        defer { view.presentScene(nil) }
        let root = try #require(renderer.node(for: world.root))
        let center = pixel(try pixels(view, node: root))
        #expect(center[2] > 240 && center[0] < 10 && center[3] > 240,
                "SKCropNode should composite its z=100 child at the parent's z=0, behind the z=5 sibling")
        #expect(renderer.inputTarget(at: .zero)?.id == sibling.id,
                "Input order must agree with the rendered crop layer")
        parent.components[MaskComponent.self]?.isEnabled = false; renderer.flush()
        #expect(try crop(renderer, parent).maskNode == nil)
        let disabledCenter = pixel(try pixels(view, node: root))
        #expect(disabledCenter[0] > 240 && disabledCenter[2] < 10 && disabledCenter[3] > 240,
                "Retained crop with nil mask passes through global child z")
        #expect(renderer.inputTarget(at: .zero)?.id == child.id, "Bypassed crop input must match native ordering")
        parent.components.remove(MaskComponent.self); renderer.flush()
        #expect(SpriteRenderer.contentRoot(try #require(renderer.node(for: parent))) === renderer.node(for: parent))
        let removedCenter = pixel(try pixels(view, node: root))
        #expect(removedCenter[0] > 240 && removedCenter[2] < 10 && removedCenter[3] > 240,
                "Unwrapped child z=100 draws over sibling z=5")
        #expect(renderer.inputTarget(at: .zero)?.id == child.id)
    }
}
