import ECSCore
@testable import SpriteBackend
import SpriteKit
import Testing

private func close(_ a: SIMD2<Float>?, _ b: SIMD2<Float>, _ tolerance: Float = 1e-3) -> Bool {
    guard let a else { return false }
    return abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
}

@Suite struct CameraMathTests {
    @Test func boundsKeepTheViewInside() {
        let camera = CameraComponent(bounds: .init(min: [-500, -300], max: [500, 300]))
        let view: SIMD2<Float> = [200, 100]
        #expect(camera.clamped([0, 0], viewSize: view) == [0, 0])
        #expect(camera.clamped([1000, 1000], viewSize: view) == [400, 250])
        #expect(camera.clamped([-1000, -1000], viewSize: view) == [-400, -250])
    }

    @Test func zoomChangesHowMuchTheBoundsAllow() {
        var camera = CameraComponent(zoom: 2, bounds: .init(min: [-500, -300], max: [500, 300]))
        #expect(camera.visibleSize(in: [200, 100]) == [100, 50])
        #expect(camera.clamped([1000, 0], viewSize: [200, 100]) == [450, 0])
        // Zoomed out past the bounds on x: centered on them along x, still clamped along y.
        camera.zoom = 0.1
        #expect(camera.clamped([300, 1000], viewSize: [200, 20]) == [0, 200])
    }

    @Test func smoothingEasesTowardTheTarget() {
        let camera = CameraComponent(smoothing: 0.5)
        let first = camera.step(from: .zero, toward: [100, 0], viewSize: [10, 10], deltaTime: 0.5)
        #expect(close(first, [100 * (1 - exp(-1)), 0]))
        // Two half steps land where one full step does: frame-rate independent.
        let half = camera.step(from: .zero, toward: [100, 0], viewSize: [10, 10], deltaTime: 0.25)
        let twice = camera.step(from: half, toward: [100, 0], viewSize: [10, 10], deltaTime: 0.25)
        #expect(close(twice, first))
        #expect(CameraComponent(smoothing: 0).step(from: .zero, toward: [7, 8], viewSize: [1, 1], deltaTime: 0) == [7, 8])
        #expect(CameraComponent(offset: [0, 50], smoothing: 0).step(from: .zero, toward: [7, 8], viewSize: [1, 1], deltaTime: 0) == [7, 58])
        #expect(camera.step(from: [3, 4], toward: nil, viewSize: [1, 1], deltaTime: 1) == [3, 4])
    }

    @Test func shakeGrowsWithTraumaAndStaysInReach() {
        var camera = CameraComponent(maxShake: 10)
        #expect(camera.shakeOffset(at: 1.23) == .zero)
        camera.shake(0.5)
        camera.shake(0.8)
        #expect(camera.trauma == 1)
        camera.shake(-2)
        #expect(camera.trauma == 0)

        camera.trauma = 1
        var largest: Float = 0
        for i in 0..<500 {
            let offset = camera.shakeOffset(at: Double(i) * 0.013)
            #expect(abs(offset.x) <= 10.001 && abs(offset.y) <= 10.001)
            largest = max(largest, abs(offset.x), abs(offset.y))
        }
        #expect(largest > 5)
        let full = camera.shakeOffset(at: 0.4)
        camera.trauma = 0.5
        #expect(close(camera.shakeOffset(at: 0.4), full * 0.25))
    }

    @Test func roundTripsThroughCodable() throws {
        let camera = CameraComponent(target: .named("player"), offset: [0, 20], zoom: 1.5,
                                     bounds: .init(center: [0, 0], size: [100, 80]), trauma: 0.3)
        let data = try JSONEncoder().encode(camera)
        #expect(try JSONDecoder().decode(CameraComponent.self, from: data) == camera)
        #expect(CameraComponent.Bounds(center: [10, 0], size: [100, 80]) == .init(min: [-40, -40], max: [60, 40]))
    }
}

@MainActor @Suite struct CameraRendererTests {
    private func setUp(_ camera: CameraComponent) -> (World, SpriteRenderer, Entity) {
        let world = World()
        let renderer = SpriteRenderer(world: world, size: CGSize(width: 200, height: 100))
        let entity = Entity(name: "camera", components: camera)
        world.addEntity(entity)
        return (world, renderer, entity)
    }

    @Test func anActiveCameraBecomesTheScenesCamera() throws {
        let (world, renderer, entity) = setUp(CameraComponent(zoom: 2))
        let node = try #require(renderer.camera)
        #expect(node.parent === renderer.node(for: entity))
        #expect(node.xScale == 0.5)
        #expect(renderer.activeCamera === entity)

        entity.components[CameraComponent.self]?.isActive = false
        renderer.flush()
        #expect(renderer.camera == nil)
        entity.components[CameraComponent.self]?.isActive = true
        renderer.flush()
        #expect(renderer.camera === node)

        world.removeEntity(entity)
        #expect(renderer.camera == nil)
    }

    @Test func removingTheComponentFallsBackToAnotherCamera() throws {
        let (world, renderer, first) = setUp(CameraComponent())
        let second = Entity(components: CameraComponent(zoom: 3))
        world.addEntity(second)
        #expect(renderer.camera?.parent === renderer.node(for: first))
        first.components[CameraComponent.self] = nil
        renderer.flush()
        #expect(renderer.camera?.parent === renderer.node(for: second))
        #expect(renderer.node(for: first)?.childNode(withName: SpriteRenderer.cameraNodeName) == nil)
    }

    @Test func followsItsTargetWithinBounds() throws {
        let (world, renderer, camera) = setUp(CameraComponent(
            target: .named("player"), smoothing: 0, bounds: .init(min: [-300, -100], max: [300, 100])
        ))
        let parent = Entity()
        parent.position = [50, 0]
        let player = Entity(name: "player")
        player.position = [100, 80]
        parent.addChild(player)
        world.addEntity(parent)

        renderer.updateCameras(deltaTime: 1.0 / 60, time: 0)
        renderer.flush()
        // Follows the scene position, but the view (200 × 100) can't go past y = 100 - 50.
        #expect(camera.position == [150, 50])
        #expect(renderer.node(for: camera)?.position == CGPoint(x: 150, y: 50))

        camera.components[CameraComponent.self]?.target = .entity(parent.id)
        renderer.updateCameras(deltaTime: 1.0 / 60, time: 0)
        #expect(camera.position == [50, 0])
    }

    @Test func shakeDecaysAndOnlyMovesTheView() throws {
        let (_, renderer, camera) = setUp(CameraComponent(trauma: 1, traumaDecay: 2, maxShake: 10))
        camera.position = [20, 0]
        renderer.updateCameras(deltaTime: 0.25, time: 0.4)
        renderer.flush()
        let component = try #require(camera.components[CameraComponent.self])
        #expect(component.trauma == 0.5)
        // The entity stays put; only the camera node wobbles.
        #expect(camera.position == [20, 0])
        let node = try #require(renderer.camera)
        let expected = component.shakeOffset(at: 0.4)
        #expect(close([Float(node.position.x), Float(node.position.y)], expected))
        #expect(expected != .zero)

        renderer.updateCameras(deltaTime: 1, time: 1)
        #expect(camera.components[CameraComponent.self]?.trauma == 0)
        #expect(node.position == .zero)
    }

    @Test func viewPointsMapThroughTheCamera() {
        let world = World()
        let renderer = SpriteRenderer(world: world, size: CGSize(width: 200, height: 100))
        // No camera: the view's center is the origin, +y up.
        #expect(renderer.scenePoint(fromView: CGPoint(x: 150, y: 25)) == [50, 25])

        let camera = Entity(components: CameraComponent(zoom: 2))
        camera.position = [300, -40]
        world.addEntity(camera)
        #expect(renderer.scenePoint(fromView: CGPoint(x: 100, y: 50)) == [300, -40])
        #expect(renderer.scenePoint(fromView: CGPoint(x: 200, y: 0)) == [350, -15])
    }

    @Test func zoomAnimates() async throws {
        let (_, renderer, camera) = setUp(CameraComponent(zoom: 1))
        withAnimation(.linear(duration: 1)) {
            camera.components[CameraComponent.self]?.zoom = 4
        }
        renderer.flush()
        let node = try #require(renderer.camera)
        #expect(node.action(forKey: SpriteRenderer.cameraZoomKey) != nil)
        #expect(node.xScale == 1)
    }
}
