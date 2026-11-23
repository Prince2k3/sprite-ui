import CoreImage
import ECSCore
import Foundation
import SpriteKit
import SwiftUI
import Testing
@testable import SpriteBackend

@MainActor @Suite struct RenderGroupTests {
    func group(_ renderer: SpriteRenderer, _ entity: Entity) throws -> SKEffectNode { try #require(renderer.node(for: entity) as? SKEffectNode) }
    func pixel(_ image: CIImage, at point: CGPoint = CGPoint(x: 4, y: 4)) -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        pixel.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: 4, bounds: CGRect(origin: point, size: CGSize(width: 1, height: 1)),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        return pixel
    }
    func image() -> CIImage { CIImage(color: CIColor(red: 0.3, green: 0.5, blue: 0.7)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8)) }

    @Test func legacyEntitiesBypassCompositing() throws {
        let world = World(), renderer = SpriteRenderer(world: world), entity = Entity()
        world.addEntity(entity); let node = try group(renderer, entity)
        #expect(!node.shouldEnableEffects && !node.shouldRasterize && node.filter == nil && node.alpha == 1)
    }

    @Test func filteringBypassAndRemovalPreserveNodesBodiesAndActions() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let parent = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 8)))
        let child = Entity(components: SpriteComponent(color: .cyan, size: [20, 20])); parent.addChild(child); world.addEntity(parent)
        let node = try group(renderer, parent), body = try #require(node.physicsBody), childNode = try #require(renderer.node(for: child))
        withAnimation(.linear(duration: 10)) { parent.position = [100, 50] }; renderer.flush()
        parent.components.set(RenderGroupComponent(effects: [.blur(radius: 8)], opacity: 0.6, blendMode: .screen)); renderer.flush()
        #expect(try group(renderer, parent) === node && node.physicsBody === body && childNode.parent === node)
        #expect(node.shouldEnableEffects && node.blendMode == .screen && abs(node.alpha - 0.6) < 0.00001 && node.hasActions())
        #expect((node.filter as? RenderGroupFilter)?.effects == [.blur(radius: 8)] && !node.shouldRasterize)
        parent.components[RenderGroupComponent.self]?.isEnabled = false; renderer.flush()
        #expect(!node.shouldEnableEffects && node.alpha == 1 && node.filter == nil && node.blendMode == .alpha)
        #expect(node.physicsBody === body && node.hasActions())
        parent.components[RenderGroupComponent.self]?.isEnabled = true; renderer.flush()
        #expect(node.shouldEnableEffects && node.filter != nil)
        parent.components.remove(RenderGroupComponent.self); renderer.flush()
        #expect(!node.shouldEnableEffects && node.alpha == 1 && node.filter == nil && node.physicsBody === body && node.hasActions())
    }

    @Test func effectParametersAreFiniteAndBoundedAtTheBackend() {
        let blur = PostProcessEffect.blur(radius: .infinity).filter
        let bloom = PostProcessEffect.bloom(radius: 500, intensity: -2).filter
        let color = PostProcessEffect.colorAdjustment(saturation: .nan, brightness: -5, contrast: .infinity).filter
        #expect((blur.value(forKey: kCIInputRadiusKey) as? NSNumber)?.floatValue == 0)
        #expect((bloom.value(forKey: kCIInputRadiusKey) as? NSNumber)?.floatValue == 128)
        #expect((bloom.value(forKey: kCIInputIntensityKey) as? NSNumber)?.floatValue == 0)
        #expect((color.value(forKey: kCIInputSaturationKey) as? NSNumber)?.floatValue == 1)
        #expect((color.value(forKey: kCIInputBrightnessKey) as? NSNumber)?.floatValue == -1)
        #expect((color.value(forKey: kCIInputContrastKey) as? NSNumber)?.floatValue == 1)
    }

    @Test func chainRendersRealPixelsInDeclaredOrder() throws {
        let a = RenderGroupFilter(effects: [.colorAdjustment(brightness: 0.2), .colorAdjustment(contrast: 0.5)])
        let b = RenderGroupFilter(effects: [.colorAdjustment(contrast: 0.5), .colorAdjustment(brightness: 0.2)])
        a.inputImage = image(); b.inputImage = image()
        let first = pixel(try #require(a.outputImage)), second = pixel(try #require(b.outputImage))
        #expect(first != second && first[3] == 255 && second[3] == 255)
        let gray = RenderGroupFilter(effects: [.colorAdjustment(saturation: 0)])
        gray.inputImage = image(); let rgb = pixel(try #require(gray.outputImage))
        #expect(abs(Int(rgb[0]) - Int(rgb[1])) <= 1 && abs(Int(rgb[1]) - Int(rgb[2])) <= 1)
    }

    @Test func blurAndBloomProduceFiniteExpandedOutputAndCopiesOwnTheirInput() throws {
        let filter = RenderGroupFilter(effects: [.blur(radius: 2), .bloom(radius: 3, intensity: 0.7)])
        #expect(filter.outputImage == nil)
        filter.inputImage = image(); let output = try #require(filter.outputImage)
        #expect(!output.extent.isInfinite && output.extent.contains(image().extent) && output.extent.width > 8)
        let copy = try #require(filter.copy() as? RenderGroupFilter)
        copy.inputImage = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        #expect(pixel(try #require(copy.outputImage)) != pixel(output))
        copy.setDefaults(); #expect(copy.outputImage == nil && filter.outputImage != nil)
    }

    @Test func nestedGroupsKeepTheirHierarchyAndIndependentFilters() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let outer = Entity(components: RenderGroupComponent(effects: [.blur(radius: 5)]))
        let inner = Entity(components: RenderGroupComponent(effects: [.bloom(radius: 8)]))
        outer.addChild(inner); world.addEntity(outer)
        let a = try group(renderer, outer), b = try group(renderer, inner)
        #expect(b.parent === a && a.filter !== b.filter)
        inner.components[RenderGroupComponent.self]?.effects = [.colorAdjustment(saturation: 0)]; renderer.flush()
        #expect((a.filter as? RenderGroupFilter)?.effects == [.blur(radius: 5)])
        #expect((b.filter as? RenderGroupFilter)?.effects == [.colorAdjustment(saturation: 0)])
    }

    @Test func groupOpacityIsAppliedOnceToOverlappingChildren() throws {
        let world = World(), renderer = SpriteRenderer(world: world, size: CGSize(width: 64, height: 64))
        let entity = Entity(components: RenderGroupComponent(opacity: 0.5))
        entity.addChild(Entity(components: SpriteComponent(color: .red, size: [32, 32])))
        let front = Entity(components: SpriteComponent(color: .blue, size: [32, 32])); front.zPosition = 1; entity.addChild(front)
        world.addEntity(entity)
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 64, height: 64)); view.presentScene(renderer)
        defer { view.presentScene(nil) }
        let node = try group(renderer, entity), texture = try #require(view.texture(from: node))
        let image = texture.cgImage()
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); return true
        }
        #expect(drawn)
        let center = ((image.height / 2) * image.width + image.width / 2) * 4
        #expect((126...129).contains(Int(bytes[center + 3])))
    }

    @Test func hitOrderTreatsCompositedGroupsAsAtomicLayers() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let a = Entity(components: RenderGroupComponent()), child = Entity(components: InputTargetComponent(), SpriteComponent(color: .red, size: [30, 30]))
        child.zPosition = 100; a.addChild(child)
        let b = Entity(components: InputTargetComponent(), SpriteComponent(color: .blue, size: [30, 30])); b.zPosition = 5
        world.addEntity(a); world.addEntity(b)
        #expect(renderer.inputTarget(at: .zero) === b)
        a.components[RenderGroupComponent.self]?.isEnabled = false; renderer.flush()
        #expect(renderer.inputTarget(at: .zero) === child)
        a.components[RenderGroupComponent.self]?.isEnabled = true; a.zPosition = 10; renderer.flush()
        #expect(renderer.inputTarget(at: .zero) === child)
    }

    @Test func nestedGroupHitOrderIsLocalToEachCompositingBoundary() {
        let world = World(), renderer = SpriteRenderer(world: world)
        let root = Entity(components: RenderGroupComponent()), inner = Entity(components: RenderGroupComponent())
        let deep = Entity(components: InputTargetComponent(), CollisionComponent(shape: .circle(radius: 10)))
        let sibling = Entity(components: InputTargetComponent(), CollisionComponent(shape: .circle(radius: 10)))
        inner.zPosition = 2; deep.zPosition = 100; sibling.zPosition = 3
        root.addChild(inner); inner.addChild(deep); root.addChild(sibling); world.addEntity(root)
        #expect(renderer.inputTarget(at: .zero) === sibling)
        inner.zPosition = 4; renderer.flush(); #expect(renderer.inputTarget(at: .zero) === deep)
    }

    @Test func inputCameraAndCollisionCoordinatesDoNotMoveWhenFiltersChange() throws {
        let world = World(), renderer = SpriteRenderer(world: world, size: CGSize(width: 400, height: 300))
        let parent = Entity(); parent.position = [40, 20]; parent.rotation = 0.4; parent.scale = [2, 1.5]
        let child = Entity(components: InputTargetComponent(), CollisionComponent(shape: .circle(radius: 10)))
        child.position = [20, 15]; parent.addChild(child); world.addEntity(parent)
        let camera = Entity(components: CameraComponent(zoom: 1.4)); camera.position = [15, 5]; camera.rotation = 0.2; world.addEntity(camera)
        let screen = try #require(renderer.viewPoint(from: .zero, relativeTo: child)), point = renderer.scenePoint(fromView: screen)
        parent.components.set(RenderGroupComponent(effects: [.blur(radius: 10)], opacity: 0.3)); renderer.flush()
        #expect(renderer.viewPoint(from: .zero, relativeTo: child) == screen)
        #expect(renderer.inputTarget(at: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))) === child)
        #expect(world.raycast(from: point - [100, 0], to: point + [100, 0]).first?.entity === child)
        #expect(renderer.entities(at: CGPoint(x: CGFloat(point.x + 80), y: CGFloat(point.y))).isEmpty)
    }

    @Test func physicsResultsCopyBackInTheSameParentSpaceInsideAGroup() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let parent = Entity(components: RenderGroupComponent(effects: [.blur(radius: 4)])); parent.position = [50, 70]; parent.rotation = 0.3
        let child = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 5)))
        parent.addChild(child); world.addEntity(parent)
        let node = try #require(renderer.node(for: child)); node.position = CGPoint(x: 30, y: -20); node.zRotation = 0.7
        node.physicsBody?.velocity = CGVector(dx: 10, dy: 15); renderer.didSimulatePhysics()
        #expect(child.position == [30, -20] && abs(child.rotation - 0.7) < 0.00001)
        #expect(abs((child.components[PhysicsBodyComponent.self]?.velocity.x ?? 0) - 10) < 0.001)
        parent.components.remove(RenderGroupComponent.self); renderer.flush()
        #expect(child.position == [30, -20] && renderer.node(for: child) === node)
    }

    @Test func opacityAnimatesWithoutReplacingFiltersAndRemovalCancelsOnlyItsOwnAction() throws {
        let world = World(), renderer = SpriteRenderer(world: world), entity = Entity(components: RenderGroupComponent(effects: [.blur(radius: 2)]))
        world.addEntity(entity); let node = try group(renderer, entity), filter = node.filter
        withAnimation(.linear(duration: 5)) {
            entity.position = [50, 0]; entity.components[RenderGroupComponent.self]?.opacity = 0.2
        }
        renderer.flush()
        #expect(node.action(forKey: "renderGroup.opacity") != nil && node.action(forKey: "transform.position") != nil)
        #expect(node.filter === filter && entity.presentation[RenderGroupComponent.self]?.opacity == 1)
        entity.components.remove(RenderGroupComponent.self); renderer.flush()
        #expect(node.action(forKey: "renderGroup.opacity") == nil && node.action(forKey: "transform.position") != nil && node.alpha == 1)
    }

    @Test func editsReachTheRendererWhileSimulationIsPausedAndActivationSuspendsTheGroup() throws {
        let world = World(), renderer = SpriteRenderer(world: world), entity = Entity(components: RenderGroupComponent())
        world.addEntity(entity); world.isPaused = true
        entity.components[RenderGroupComponent.self]?.effects = [.blur(radius: 10)]; renderer.update(1); renderer.didFinishUpdate()
        let node = try group(renderer, entity)
        #expect(node.shouldEnableEffects && (node.filter as? RenderGroupFilter)?.effects == [.blur(radius: 10)])
        entity.isEnabled = false; #expect(node.isHidden && node.isPaused)
        entity.isEnabled = true; #expect(!node.isHidden && world.isPaused)
    }

    @Test func clonesAndPooledEntitiesNeverShareMutableFilters() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let base = RenderGroupComponent(effects: [.bloom(radius: 5)])
        let root = Entity(components: base), child = Entity(components: SpriteComponent(color: .mint, size: [20, 20])); root.addChild(child)
        let pool = try EntityPool(prefab: PrefabResource(root: root), scene: world, capacity: 2, onAcquire: { $0.components.set(base) })
        let a = try #require(try pool.acquire()), b = try #require(try pool.acquire())
        let node = try group(renderer, a), other = try group(renderer, b)
        #expect(node.filter !== other.filter)
        a.components[RenderGroupComponent.self]?.effects = [.blur(radius: 9)]; renderer.flush()
        #expect((other.filter as? RenderGroupFilter)?.effects == base.effects)
        try pool.release(a); let reused = try #require(try pool.acquire()); renderer.flush()
        #expect(reused === a && renderer.node(for: reused) === node && !node.shouldRasterize)
        #expect((node.filter as? RenderGroupFilter)?.effects == base.effects && node.filter !== other.filter)
    }

    @Test func snapshotsAndPrefabFilesKeepNestedGroupSettings() async throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let config = RenderGroupComponent(effects: [.blur(radius: 4), .colorAdjustment(saturation: 0.2)], opacity: 0.7, blendMode: .screen)
        let parent = Entity(name: "group", components: config), child = Entity(components: RenderGroupComponent(effects: [.bloom(radius: 12)]))
        parent.addChild(child); world.addEntity(parent)
        world.restore(try WorldSnapshot(data: world.snapshot().jsonData()))
        let restored = try #require(world.entities.first)
        #expect(restored.components[RenderGroupComponent.self] == config && renderer.node(for: restored) is SKEffectNode)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".prefab")
        defer { try? FileManager.default.removeItem(at: url) }
        try PrefabResource(root: restored).write(to: url)
        let copy = try await ResourceLibrary().prefab(contentsOf: url).instantiate()
        #expect(copy.components[RenderGroupComponent.self] == config && copy.children.first?.components[RenderGroupComponent.self]?.effects == [.bloom(radius: 12)])
    }

    @Test func archivedNativeEffectsImportAsTypedGroups() throws {
        let node = SKEffectNode(); node.name = "effects"; node.shouldEnableEffects = true; node.alpha = 0.4; node.blendMode = .screen
        node.filter = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 8])
        node.addChild(SKSpriteNode(color: .red, size: CGSize(width: 10, height: 10)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sks")
        defer { try? FileManager.default.removeItem(at: url) }
        try NSKeyedArchiver.archivedData(withRootObject: node, requiringSecureCoding: false).write(to: url)
        let loaded = try SceneLoader().load(contentsOf: url), config = try #require(loaded.components[RenderGroupComponent.self])
        #expect(config.effects == [.blur(radius: 8)] && abs(config.opacity - 0.4) < 0.00001 && config.blendMode == .screen)
        #expect(loaded.children.count == 1)
    }
}
