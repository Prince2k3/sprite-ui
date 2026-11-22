@_spi(Backend) import ECSCore
@testable import SpriteBackend
import SpriteKit
import Testing

private struct PresentedPosition: Component { var point = SIMD2<Float>.zero }
private struct PositionPresentationSystem: System {
    static var phase: SystemPhase { .presentation }
    init(world: World) {}
    func update(context: UpdateContext) {
        if let body = context.world.entities.first { context.world.resources.set(PresentedPosition(point: body.position)) }
    }
}

@MainActor @Suite struct SceneLifecycleTests {
    @Test func sceneSettingsApplyBeforeAndAfterRendererCreation() throws {
        let world = World(); world.physics.gravity = [3, -4]; world.timeScale = 0.5; world.isPaused = true
        let renderer = SpriteRenderer(world: world)
        let root = try #require(renderer.node(for: world.root))
        #expect(renderer.physicsWorld.gravity == CGVector(dx: 3, dy: -4))
        #expect(root.isPaused && renderer.physicsWorld.speed == 0)
        world.isPaused = false
        #expect(!root.isPaused && renderer.physicsWorld.speed == 0.5 && root.speed == 0.5)
        renderer.gravity = [0, 2]
        #expect(world.physics.gravity == [0, 2])
        world.timeScale = 0
        #expect(root.isPaused && renderer.physicsWorld.speed == 0)
    }

    @Test func pausedScenesStillFlushExplicitEdits() throws {
        let world = World(); let renderer = SpriteRenderer(world: world)
        let entity = Entity(); world.addEntity(entity)
        world.isPaused = true; entity.position = [10, 20]
        renderer.update(1); renderer.didFinishUpdate()
        #expect(renderer.node(for: entity)?.position == CGPoint(x: 10, y: 20))
        #expect(entity.position == [10, 20])
    }

    @Test func presentationSeesPhysicsResultsInsteadOfThePrePhysicsPosition() throws {
        let world = World(); let renderer = SpriteRenderer(world: world)
        try world.systems.add(PositionPresentationSystem.self)
        let entity = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 5)))
        world.addEntity(entity)
        renderer.update(1)
        #expect(world.resources[PresentedPosition.self] == nil)
        renderer.node(for: entity)?.position = CGPoint(x: 25, y: 50)
        renderer.didSimulatePhysics(); renderer.didFinishUpdate()
        #expect(world.resources[PresentedPosition.self]?.point == [25, 50])
    }

    @Test func rootTransformsAgreeWithBackendCoordinates() throws {
        let world = World(); let renderer = SpriteRenderer(world: world)
        let entity = Entity(); entity.position = [5, 10]; world.addEntity(entity)
        world.root.transform = Transform(translation: [20, 30], rotation: .pi / 2, scale: [2, 3])
        renderer.flush()
        let node = try #require(renderer.node(for: entity))
        let point = node.convert(.zero, to: renderer)
        #expect(abs(Float(point.x) - entity.scenePosition.x) < 0.001)
        #expect(abs(Float(point.y) - entity.scenePosition.y) < 0.001)
    }

    @Test func sceneCameraSelectionDoesNotRequireRendererAccess() throws {
        let world = World()
        let first = Entity(components: CameraComponent()), second = Entity(components: CameraComponent())
        world.addEntity(first); world.addEntity(second)
        world.activeCamera = second
        let renderer = SpriteRenderer(world: world)
        #expect(renderer.activeCamera === second)
        world.activeCamera = nil
        #expect(world.activeCamera === first)
        world.activeCamera = second
        second.components[CameraComponent.self]?.isActive = false
        #expect(world.activeCamera === first)
        second.removeFromParent()
        #expect(renderer.activeCamera === first)
    }

    @Test func cameraFollowUsesSceneSpaceUnderATransformedParent() {
        let world = World(); let renderer = SpriteRenderer(world: world)
        let parent = Entity(); parent.position = [80, 20]; parent.rotation = 0.7; parent.scale = [2, 0.5]
        let target = Entity(); target.position = [120, 90]; world.addEntity(target)
        let camera = Entity(components: CameraComponent(target: .entity(target.id), smoothing: 0))
        parent.addChild(camera); world.addEntity(parent)
        renderer.update(1); renderer.didFinishUpdate()
        #expect(abs(camera.scenePosition.x - 120) < 0.001 && abs(camera.scenePosition.y - 90) < 0.001)
    }

    @Test func cameraPointConversionRespectsRotationAndScale() throws {
        let world = World(); let renderer = SpriteRenderer(world: world, size: CGSize(width: 200, height: 100))
        let camera = Entity(components: CameraComponent(zoom: 2))
        camera.position = [100, 200]; camera.rotation = .pi / 2
        world.addEntity(camera)
        let point = renderer.scenePoint(fromView: CGPoint(x: 200, y: 50))
        #expect(abs(point.x - 100) < 0.001 && abs(point.y - 250) < 0.001)
    }
}
