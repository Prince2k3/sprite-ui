@_spi(Backend) import ECSCore
import Foundation
@_spi(Backend) @testable import SpriteBackend
import SpriteKit
import Testing

@MainActor @Suite struct ParallaxTests {
    @Test func defaultsAndIndependentAxisFactorsHaveConcreteOffsets() {
        let defaults = ParallaxComponent()
        #expect(defaults.scrollFactor == [0.5, 0.5])
        #expect(defaults.referencePosition == .zero && defaults.isEnabled)
        #expect(defaults.offset(forCameraPosition: [80, -40]) == [40, -20])
        #expect(ParallaxComponent(scrollFactor: [1, 1]).offset(forCameraPosition: [80, -40]) == .zero)
        #expect(ParallaxComponent(scrollFactor: .zero).offset(forCameraPosition: [80, -40]) == [80, -40])
        let mixed = ParallaxComponent(scrollFactor: [0.25, 0.75], referencePosition: [20, -12])
        #expect(mixed.offset(forCameraPosition: [100, 28]) == [60, 10])
        #expect(mixed.offset(forCameraPosition: [20, -12]) == .zero)
        #expect(mixed.offset(forCameraPosition: [-60, -52]) == [-60, -10])
        #expect(ParallaxComponent(scrollFactor: [-1, 2]).offset(forCameraPosition: [30, -20]) == [60, 20])
    }

    @Test func disabledAndNonfiniteInputsNeverProducePresentationOffsets() {
        let disabled = ParallaxComponent(scrollFactor: [-2, 3], referencePosition: [4, 5], isEnabled: false)
        #expect(disabled.offset(forCameraPosition: [100, -100]) == .zero)
        for invalid: Float in [.nan, .infinity, -.infinity] {
            #expect(ParallaxComponent().offset(forCameraPosition: [invalid, 1]) == .zero)
            #expect(ParallaxComponent().offset(forCameraPosition: [1, invalid]) == .zero)
            #expect(ParallaxComponent(scrollFactor: [invalid, 0]).offset(forCameraPosition: [10, 20]) == .zero)
            #expect(ParallaxComponent(referencePosition: [0, invalid]).offset(forCameraPosition: [10, 20]) == .zero)
        }
    }

    @Test func repeatingConfigurationAndAxesHaveValueSemantics() throws {
        let defaults = RepeatingBackgroundComponent()
        #expect(defaults.axes == .both && defaults.maximumTileCount == 1024 && defaults.isEnabled)
        let horizontal = RepeatingBackgroundComponent.Axes.horizontal
        let vertical = RepeatingBackgroundComponent.Axes.vertical
        #expect(horizontal.union(vertical) == .both)
        #expect(horizontal.intersection(vertical).isEmpty)
        #expect(RepeatingBackgroundComponent.Axes.both.subtracting(horizontal) == vertical)
        #expect(horizontal.rawValue.nonzeroBitCount == 1 && vertical.rawValue.nonzeroBitCount == 1)
        let values = [defaults, RepeatingBackgroundComponent(axes: [], maximumTileCount: 7),
                      RepeatingBackgroundComponent(axes: .horizontal, maximumTileCount: 27, isEnabled: false)]
        #expect(Set(values).count == 3)
        for value in values {
            #expect(try JSONDecoder().decode(RepeatingBackgroundComponent.self,
                                            from: JSONEncoder().encode(value)) == value)
        }
        let parallax = ParallaxComponent(scrollFactor: [-0.5, 1.5], referencePosition: [-123, 456], isEnabled: false)
        #expect(try JSONDecoder().decode(ParallaxComponent.self, from: JSONEncoder().encode(parallax)) == parallax)
        #expect(Set([parallax, parallax, ParallaxComponent()]).count == 2)
    }

    @Test func registeredComponentsSurviveCloneAndWorldSnapshotRestoration() throws {
        SpriteRenderer.registerComponents()
        #expect(ComponentRegistry.isRegistered(ParallaxComponent.self))
        #expect(ComponentRegistry.isRegistered(RepeatingBackgroundComponent.self))
        let world = World()
        let renderer = SpriteRenderer(world: world)
        let original = Entity(name: "sky", components:
            SpriteComponent(color: .red, size: [32, 24]),
            ParallaxComponent(scrollFactor: [0.2, 1.3], referencePosition: [-40, 60]),
            RepeatingBackgroundComponent(axes: .horizontal, maximumTileCount: 73))
        original.position = [5, -7]
        let child = Entity(name: "cloud", components: ParallaxComponent(isEnabled: false),
                           RepeatingBackgroundComponent(axes: .vertical, maximumTileCount: 11, isEnabled: false))
        original.addChild(child)
        world.addEntity(original)
        renderer.flush()
        let originalNode = try #require(renderer.node(for: original))
        let clone = original.clone()
        #expect(clone.id != original.id && clone.children.first?.id != child.id)
        #expect(clone.components[ParallaxComponent.self] == original.components[ParallaxComponent.self])
        #expect(clone.components[RepeatingBackgroundComponent.self] == original.components[RepeatingBackgroundComponent.self])
        #expect(clone.children.first?.components[ParallaxComponent.self] == child.components[ParallaxComponent.self])
        #expect(clone.children.first?.components[RepeatingBackgroundComponent.self] == child.components[RepeatingBackgroundComponent.self])
        let saved = try WorldSnapshot(data: world.snapshot().jsonData())
        original.components.remove(ParallaxComponent.self)
        world.restore(saved)
        renderer.flush()
        let restored = try #require(world.entity(withID: original.id))
        #expect(restored.transform == clone.transform)
        #expect(restored.components[ParallaxComponent.self] == clone.components[ParallaxComponent.self])
        #expect(restored.components[RepeatingBackgroundComponent.self] == clone.components[RepeatingBackgroundComponent.self])
        #expect(restored.children.first?.components[RepeatingBackgroundComponent.self] == child.components[RepeatingBackgroundComponent.self])
        #expect(renderer.node(for: restored) !== originalNode && originalNode.parent == nil)
    }

    @Test func cameraScopesMoveOnlyOwnArtworkThroughTransformedParentsAndRestoreNestedState() throws {
        let world = World()
        let renderer = SpriteRenderer(world: world, size: CGSize(width: 256, height: 128))
        let parent = Entity()
        parent.position = [17, -9]
        parent.transform.rotation = 0.4
        parent.transform.scale = [1.5, 0.75]
        let art = Entity(components: SpriteComponent(color: .red, size: [32, 24]),
                         ParallaxComponent(scrollFactor: [0.5, 0.25], referencePosition: [8, -4]),
                         PhysicsBodyComponent(shape: .rectangle(size: [32, 24]), isDynamic: false))
        art.position = [11, 13]
        let child = Entity(components: SpriteComponent(color: .green, size: [6, 6]))
        child.position = [3, 7]
        art.addChild(child)
        parent.addChild(art)
        world.addEntity(parent)
        let left = Entity(components: CameraComponent(smoothing: 0))
        let right = Entity(components: CameraComponent(zoom: 2, smoothing: 0))
        left.position = [40, -20]; right.position = [-80, 60]
        world.addEntity(left); world.addEntity(right)
        world.activeCamera = left
        renderer.viewports = [.init(id: "left", camera: left.id), .init(id: "right", camera: right.id)]
        renderer.flush()
        let node = try #require(renderer.node(for: art))
        let childNode = try #require(renderer.node(for: child))
        let sprite = try #require(node.childNode(withName: "//__sprite") as? SKSpriteNode)
        let body = try #require(node.physicsBody)
        let nativePose = (node.position, node.zRotation, node.xScale, node.yScale)
        let childAnchor = childNode.convert(.zero, to: renderer)
        let modelAnchor = node.convert(.zero, to: renderer)
        let snapshot = try world.snapshot().jsonData()
        var updates = 0
        let token = world.subscribe(to: WorldEvents.Update.self) { _ in updates += 1 }
        defer { token.cancel() }
        renderer.didFinishUpdate()
        let primaryPosition = sprite.position
        renderer.renderViewport("left") {
            let actual = sprite.convert(.zero, to: renderer)
            #expect(abs(actual.x - modelAnchor.x - 16) < 0.001)
            #expect(abs(actual.y - modelAnchor.y + 12) < 0.001)
            let outerPosition = sprite.position
            renderer.renderViewport("right") {
                let actual = sprite.convert(.zero, to: renderer)
                #expect(abs(actual.x - modelAnchor.x + 44) < 0.001)
                #expect(abs(actual.y - modelAnchor.y - 48) < 0.001)
                #expect(childNode.convert(.zero, to: renderer) == childAnchor)
                #expect(node.physicsBody === body && !body.isDynamic)
            }
            #expect(sprite.position == outerPosition)
        }
        #expect(sprite.position == primaryPosition)
        #expect(node.position == nativePose.0 && node.zRotation == nativePose.1)
        #expect(node.xScale == nativePose.2 && node.yScale == nativePose.3)
        #expect(childNode.convert(.zero, to: renderer) == childAnchor)
        #expect(node.physicsBody === body && body.node === node)
        #expect(try world.snapshot().jsonData() == snapshot)
        #expect(updates == 0)
    }

    @Test func decorativeOwnerDoesNotStealPickingFromOrdinaryChildOrModelRaycasts() {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        let background = Entity(components: SpriteComponent(color: .red, size: [100, 100]),
                                ParallaxComponent(), RepeatingBackgroundComponent(),
                                CollisionComponent(shape: .rectangle(size: [100, 100])), InputTargetComponent())
        let child = Entity(components: SpriteComponent(color: .green, size: [10, 10]),
                           CollisionComponent(shape: .rectangle(size: [10, 10])), InputTargetComponent())
        child.position = [20, 0]
        background.addChild(child)
        world.addEntity(background)
        renderer.flush()
        #expect(renderer.entities(at: .zero).isEmpty)
        #expect(renderer.inputTarget(at: .zero) == nil)
        #expect(renderer.inputTarget(at: CGPoint(x: 20, y: 0)) === child)
        #expect(world.raycast(from: [-60, 0], to: [60, 0]).contains { $0.entity === background })
    }

    @Test func lifecycleAndTypedCallbacksSeeRestoredArtworkBeforeTheyRun() throws {
        struct Probe: Component {}
        struct Ping: Event {}
        let world = World()
        let renderer = SpriteRenderer(world: world, size: CGSize(width: 200, height: 100))
        let camera = Entity(components: CameraComponent(smoothing: 0)); camera.position = [80, 0]
        let art = Entity(components: SpriteComponent(color: .red, size: [20, 20]),
                         ParallaxComponent(scrollFactor: .zero))
        world.addEntity(camera); world.addEntity(art)
        let sprite = try #require(renderer.node(for: art)?.childNode(withName: "__sprite"))
        var callbacks = 0
        func inspect() { #expect(sprite.position == .zero); callbacks += 1 }
        let tokens = [
            world.subscribe(to: ComponentEvents.DidAdd.self) { _ in inspect() },
            world.subscribe(to: ComponentEvents.WillRemove.self) { _ in inspect() },
            world.subscribe(to: WorldEvents.WillRemoveEntity.self) { _ in inspect() },
            world.subscribe(to: WorldEvents.SimulationDidChange.self) { _ in inspect() },
            world.subscribe(to: Ping.self) { _ in inspect() }
        ]
        func present() { renderer.didFinishUpdate(); #expect(sprite.position == CGPoint(x: 80, y: 0)) }
        present(); art.components.set(Probe())
        present(); art.components.remove(Probe.self)
        present(); world.publish(Ping())
        present(); world.isPaused = true
        present()
        withAnimation(ActionAnimation.linear(duration: 0.1), {}) { inspect() }
        renderer.flush()
        present(); art.removeFromParent()
        #expect(callbacks == 6 && art.world == nil)
        withExtendedLifetime(tokens) {}
    }
}
