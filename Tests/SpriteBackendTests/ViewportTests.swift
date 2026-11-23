@_spi(Backend) import ECSCore
@_spi(Backend) @testable import SpriteBackend
import Foundation
import SpriteKit
import Testing

@Suite struct ViewportGeometryTests {
    @Test func normalizedRectanglesClipWithoutOverflow() {
        #expect(ViewportRect.full.rect(in: CGSize(width: 400, height: 300)) == CGRect(x: 0, y: 0, width: 400, height: 300))
        let clipped = ViewportRect(x: -0.5, y: 0.25, width: 1, height: 2).rect(in: CGSize(width: 400, height: 300))
        #expect(clipped == CGRect(x: 0, y: 75, width: 200, height: 225))
        #expect(ViewportRect(x: 0, y: 0, width: .nan, height: 1).rect(in: CGSize(width: 100, height: 100)).isEmpty)
        #expect(ViewportRect(x: 0, y: 0, width: -1, height: 1).rect(in: CGSize(width: 100, height: 100)).isEmpty)
        #expect(ViewportRect.full.rect(in: CGSize(width: CGFloat.infinity, height: 1)).isEmpty)
        #expect(ViewportRect(x: 2, y: 0, width: 1, height: 1).rect(in: CGSize(width: 100, height: 100)).isEmpty)
        #expect(ViewportRect(x: -.greatestFiniteMagnitude, y: 0, width: .greatestFiniteMagnitude, height: 1).rect(in: CGSize(width: 100, height: 100)).isEmpty)
    }
    @Test func rectanglesAndDescriptorsHaveValueSemantics() throws {
        let frame = ViewportRect(x: 0.5, y: 0.25, width: 0.5, height: 0.5)
        #expect(try JSONDecoder().decode(ViewportRect.self, from: JSONEncoder().encode(frame)) == frame)
        #expect(GameViewport(id: "left") == GameViewport(id: "left"))
        #expect(GameViewport(id: "left") != GameViewport(id: "right"))
        let invalid = ViewportRect(x: .nan, y: 0, width: 1, height: 1)
        #expect(invalid == invalid)
        #expect(try JSONEncoder().encode(invalid).isEmpty == false)
    }
}

@MainActor @Suite struct ViewportRendererTests {
    private func fixture() -> (World, SpriteRenderer, Entity, Entity) {
        let world = World()
        let a = Entity(name: "A", components: CameraComponent(smoothing: 0))
        let b = Entity(name: "B", components: CameraComponent(zoom: 2, smoothing: 0))
        a.position = [-100, 0]; b.position = [200, 50]
        world.addEntity(a); world.addEntity(b)
        let renderer = SpriteRenderer(world: world, size: CGSize(width: 400, height: 300))
        renderer.viewports = [
            .init(id: "left", camera: a.id, frame: .init(x: 0, y: 0, width: 0.5, height: 1)),
            .init(id: "right", camera: b.id, frame: .init(x: 0.5, y: 0, width: 0.5, height: 1))
        ]
        return (world, renderer, a, b)
    }
    private func close(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Bool { abs(a.x - b.x) < 0.001 && abs(a.y - b.y) < 0.001 }

    @Test func eachViewportUsesItsOwnCameraAndPointSize() throws {
        let (_, renderer, _, _) = fixture()
        #expect(renderer.scenePoint(fromView: CGPoint(x: 100, y: 150), inViewport: "left") == [-100, 0])
        #expect(renderer.scenePoint(fromView: CGPoint(x: 300, y: 150), inViewport: "right") == [200, 50])
        #expect(renderer.scenePoint(fromView: CGPoint(x: 320, y: 130), inViewport: "right") == [210, 60])
        #expect(renderer.viewPoint(from: [200, 50], inViewport: "right") == CGPoint(x: 300, y: 150))
        #expect(renderer.scenePoint(fromView: CGPoint(x: 320, y: 130)) == [210, 60])
        #expect(renderer.viewport(at: CGPoint(x: 200, y: 150))?.id == "right")
        #expect(renderer.scenePoint(fromView: .zero, inViewport: "missing") == nil)
    }

    @Test func projectionsRoundTripThroughRotatedScaledParentAndCameraShake() throws {
        let (world, renderer, a, _) = fixture()
        let parent = Entity(); parent.position = [50, -20]
        parent.transform.rotation = 0.4; parent.transform.scale = [1.2, 0.8]
        world.addEntity(parent); parent.addChild(a)
        let target = Entity(); target.position = [15, 25]; parent.addChild(target)
        renderer.flush()
        let camera = try #require(renderer.node(for: a)?.childNode(withName: SpriteRenderer.cameraNodeName))
        camera.position = CGPoint(x: 5, y: -3); camera.zRotation = 0.25
        for id in ["left", "right"] {
            let view = try #require(renderer.viewPoint(from: [3, 9], relativeTo: target, inViewport: id))
            let scene = try #require(renderer.scenePoint(fromView: view, inViewport: id))
            let native = try #require(renderer.node(for: target)).convert(CGPoint(x: 3, y: 9), to: renderer)
            #expect(close(scene, [Float(native.x), Float(native.y)]))
        }
    }

    @Test func gapsAndNoninteractiveOverlayDoNotPassThrough() {
        let (_, renderer, a, _) = fixture()
        renderer.viewports = [
            .init(id: "game", camera: a.id, frame: .init(x: 0, y: 0, width: 0.9, height: 1)),
            .init(id: "map", camera: a.id, frame: .init(x: 0.5, y: 0, width: 0.25, height: 0.5), isInteractive: false)
        ]
        #expect(renderer.viewport(at: CGPoint(x: 220, y: 30)) == nil)
        #expect(renderer.viewport(at: CGPoint(x: 220, y: 30), interactiveOnly: false)?.id == "map")
        #expect(renderer.viewport(at: CGPoint(x: 390, y: 30)) == nil)
        #expect(renderer.viewport(at: CGPoint(x: CGFloat.nan, y: 30)) == nil)
        #expect(renderer.viewport(at: CGPoint(x: 50, y: 30))?.id == "game")
    }

    @Test func duplicatesInvalidGeometryAndMissingCamerasAreOmitted() {
        let (_, renderer, a, _) = fixture()
        renderer.viewports = [
            .init(id: ""), .init(id: "first", camera: a.id),
            .init(id: "first", camera: 0), .init(id: "missing", camera: 0),
            .init(id: "empty", frame: .init(x: 0, y: 0, width: 0, height: 1))
        ]
        #expect(renderer.resolvedViewports.map(\.id) == ["first"])
        a.isEnabled = false
        #expect(renderer.resolvedViewports.isEmpty)
        #expect(renderer.viewportRect(id: "first") == nil)
        #expect(renderer.scenePoint(fromView: .zero, inViewport: "first") == nil)
    }

    @Test func renderedScopeRestoresCameraSizeListenerAndDoesNotAdvanceWorld() throws {
        let (world, renderer, _, _) = fixture()
        let camera = renderer.camera, listener = renderer.listener
        var updates = 0
        let token = world.subscribe(to: WorldEvents.Update.self) { _ in updates += 1 }
        let result = renderer.renderViewport("right") {
            #expect(renderer.size == CGSize(width: 200, height: 300))
            #expect(renderer.viewportRect(id: "right") == CGRect(x: 200, y: 0, width: 200, height: 300))
            #expect(renderer.camera !== camera)
            #expect(renderer.listener === listener)
            return 42
        }
        #expect(result == 42)
        #expect(renderer.size == CGSize(width: 400, height: 300))
        #expect(renderer.camera === camera && renderer.listener === listener)
        #expect(updates == 0)
        #expect(world.observer === renderer)
        token.cancel()
    }

    @Test func allCamerasUpdateOnceWithFirstAssignedViewportBounds() {
        let (world, renderer, a, b) = fixture()
        let target = Entity(); target.position = [500, 500]; world.addEntity(target)
        let bounds = CameraComponent.Bounds(center: .zero, size: [1000, 1000])
        a.components[CameraComponent.self]?.target = .entity(target.id)
        a.components[CameraComponent.self]?.bounds = bounds
        a.components[CameraComponent.self]?.trauma = 1
        a.components[CameraComponent.self]?.traumaDecay = 1
        b.components[CameraComponent.self]?.target = .entity(target.id)
        b.components[CameraComponent.self]?.bounds = bounds
        renderer.viewports.append(.init(id: "map", camera: a.id, frame: .init(x: 0, y: 0, width: 0.25, height: 0.25)))
        renderer.flush()
        renderer.updateCameras(deltaTime: 0.1, time: 1)
        #expect(a.position == [400, 350])
        #expect(b.position == [450, 425])
        #expect(abs((a.components[CameraComponent.self]?.trauma ?? 0) - 0.9) < 0.001)
    }

    @Test func legacyAutomaticCameraAndUnavailableExplicitCameraStayDistinct() {
        let (world, renderer, a, b) = fixture()
        renderer.viewports = []
        #expect(renderer.resolvedViewports.map(\.id) == ["main"])
        #expect(renderer.scenePoint(fromView: CGPoint(x: 200, y: 150), inViewport: "main") == a.position)
        world.activeCamera = b
        #expect(renderer.scenePoint(fromView: CGPoint(x: 200, y: 150), inViewport: "main") == b.position)
        renderer.viewports = [.init(id: "fixed", camera: a.id)]
        a.removeFromParent()
        #expect(renderer.resolvedViewports.isEmpty)
        #expect(renderer.scenePoint(fromView: .zero, inViewport: "fixed") == nil)
    }

    @Test func invalidRelativeEntityCannotProjectAndNestedScopesRestore() {
        let (_, renderer, _, _) = fixture()
        let foreign = Entity()
        #expect(renderer.viewPoint(from: .zero, relativeTo: foreign, inViewport: "left") == nil)
        renderer.renderViewport("left") {
            let camera = renderer.camera
            renderer.renderViewport("right") {
                #expect(renderer.size == CGSize(width: 200, height: 300))
            }
            #expect(renderer.camera === camera)
        }
        #expect(renderer.size == CGSize(width: 400, height: 300))
    }

    @Test func debugPickingUsesThePaneAndNeverSelectsOriginThroughAGap() {
        let (world, renderer, a, _) = fixture()
        let sprite = Entity(components: SpriteComponent(color: .red, size: [30, 30]))
        sprite.position = a.position; world.addEntity(sprite)
        let debug = SceneDebugController()
        #expect(renderer.setDebugController(debug))
        #expect(debug.select(atView: CGPoint(x: 100, y: 150)) == sprite.id)
        renderer.viewports = [.init(id: "left", camera: a.id, frame: .init(x: 0, y: 0, width: 0.4, height: 1))]
        #expect(debug.select(atView: CGPoint(x: 300, y: 150)) == nil)
        #expect(debug.selectedEntityID == nil)
    }
}
