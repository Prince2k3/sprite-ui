import ECSCore
@testable import GameUI
import Metal
@_spi(Backend) import SpriteBackend
import SpriteKit
import SwiftUI
import Testing

@MainActor @Suite struct VisibilityRenderingTests {
    private static let worldLayer = RenderLayer(rawValue: 1 << 1)
    private static let mapLayer = RenderLayer(rawValue: 1 << 2)

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Metal device unavailable"))
    func cameraFiltersDoNotLeakAcrossPanesOrInheritPrimaryHiddenFlags() throws {
        let fixture = try Fixture()
        let red = fixture.art(Color(red: 1, green: 0, blue: 0), layers: Self.worldLayer)
        let green = fixture.art(Color(red: 0, green: 1, blue: 0), layers: Self.mapLayer)
        green.transform.zPosition = 1
        // A native escape-hatch flag must survive every temporary camera filter.
        let blue = fixture.art(Color(red: 0, green: 0, blue: 1), layers: .all)
        blue.transform.zPosition = 2
        fixture.scene.flush()
        let redNode = try #require(fixture.scene.node(for: red))
        let greenNode = try #require(fixture.scene.node(for: green))
        let blueNode = try #require(fixture.scene.node(for: blue))
        blueNode.isHidden = true

        var updates = 0
        let subscription = fixture.world.subscribe(to: WorldEvents.Update.self) { _ in updates += 1 }
        try fixture.frame() // Warm SpriteKit's offscreen draw resources once.
        updates = 0
        try fixture.frame()
        fixture.expectPixel(64, .red)
        fixture.expectPixel(192, .green)
        #expect(updates == 1)
        #expect(!redNode.isHidden && greenNode.isHidden && blueNode.isHidden)
        #expect(!fixture.scene.isPresentationHidden(greenNode))
        #expect(fixture.scene.isPresentationHidden(blueNode))
        #expect(!fixture.scene.isVisible(green))
        #expect(fixture.scene.isVisible(green, inViewport: "map"))

        // Draw the same rectangles in the opposite order to expose leaked masks.
        fixture.scene.viewports.reverse()
        try fixture.frame()
        fixture.expectPixel(64, .red)
        fixture.expectPixel(192, .green)
        #expect(!redNode.isHidden && greenNode.isHidden && blueNode.isHidden)

        fixture.world.activeCamera = fixture.mapCamera
        try fixture.frame()
        fixture.expectPixel(64, .red)
        fixture.expectPixel(192, .green)
        #expect(redNode.isHidden && !greenNode.isHidden && blueNode.isHidden)
        #expect(!fixture.scene.isPresentationHidden(redNode))

        // The implicit legacy pane uses the selected primary camera's mask too.
        fixture.scene.viewports = []
        try fixture.frame()
        fixture.expectPixel(64, .green)
        fixture.expectPixel(192, .green)
        #expect(redNode.isHidden && !greenNode.isHidden && blueNode.isHidden)
        #expect(red.isActive && green.isActive && blue.isActive)
        withExtendedLifetime(subscription) {}
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Metal device unavailable"))
    func viewportRestrictionsIntersectCameraMasksAndNeverBroadenThem() throws {
        let fixture = try Fixture()
        fixture.art(Color(red: 1, green: 0, blue: 0), layers: Self.worldLayer)
        let green = fixture.art(Color(red: 0, green: 1, blue: 0), layers: Self.mapLayer)
        green.transform.zPosition = 1
        fixture.mapCamera.components[CameraComponent.self]?.cullingMask = .all
        fixture.scene.viewports[0].cullingMask = Self.mapLayer
        fixture.scene.viewports[1].cullingMask = Self.mapLayer
        fixture.scene.viewports[1].isInteractive = false

        try fixture.frame()
        try fixture.frame()
        fixture.expectPixel(64, .black) // world camera intersect map viewport = empty.
        fixture.expectPixel(192, .green)
        #expect(fixture.scene.visibilityMask(inViewport: "world") == RenderLayer.none)
        #expect(fixture.scene.visibilityMask(inViewport: "map") == Self.mapLayer)
        #expect(fixture.scene.isVisible(green, inViewport: "map"))

        fixture.mapCamera.components[CameraComponent.self]?.cullingMask = Self.worldLayer
        fixture.scene.viewports[0].cullingMask = nil
        try fixture.frame()
        fixture.expectPixel(64, .red)
        fixture.expectPixel(192, .black)

        fixture.scene.viewports[1].cullingMask = nil
        try fixture.frame()
        fixture.expectPixel(64, .red)
        fixture.expectPixel(192, .red)

        fixture.worldCamera.components[CameraComponent.self]?.cullingMask = .none
        fixture.scene.viewports[1].cullingMask = RenderLayer.none
        try fixture.frame()
        fixture.expectPixel(64, .black)
        fixture.expectPixel(192, .black)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Metal device unavailable"))
    func ancestorGatesSurviveFilteredMaskedSubtreesAndVisibilityEdits() throws {
        let fixture = try Fixture()
        let parent = Entity(components:
            VisibilityComponent(layers: [Self.worldLayer, Self.mapLayer]),
            MaskComponent(shape: .rectangle(size: [80, 80])),
            RenderGroupComponent(effects: [.colorAdjustment()]))
        fixture.world.addEntity(parent)
        let red = fixture.art(Color(red: 1, green: 0, blue: 0), layers: Self.worldLayer, parent: parent)
        let green = fixture.art(Color(red: 0, green: 1, blue: 0), layers: Self.mapLayer, parent: parent)
        green.transform.zPosition = 1

        try fixture.frame()
        try fixture.frame()
        fixture.expectPixel(64, .red)
        fixture.expectPixel(192, .green)
        fixture.expectPixel(8, .black)
        fixture.expectPixel(136, .black)
        let parentNode = try #require(fixture.scene.node(for: parent))
        let greenNode = try #require(fixture.scene.node(for: green))
        #expect(!parentNode.isHidden && greenNode.isHidden)

        parent.components[VisibilityComponent.self]?.isVisible = false
        #expect(!fixture.scene.isVisible(red, inViewport: "world"))
        #expect(!fixture.scene.isVisible(green, inViewport: "map"))
        try fixture.frame()
        fixture.expectPixel(64, .black)
        fixture.expectPixel(192, .black)
        #expect(parentNode.isHidden)

        parent.components[VisibilityComponent.self]?.isVisible = true
        parent.components[VisibilityComponent.self]?.layers = Self.worldLayer
        try fixture.frame()
        fixture.expectPixel(64, .red)
        fixture.expectPixel(192, .black) // A matching child cannot escape its ancestor.
        #expect(!parentNode.isHidden && greenNode.isHidden)

        parent.components.remove(VisibilityComponent.self)
        try fixture.frame()
        fixture.expectPixel(64, .red)
        fixture.expectPixel(192, .green) // An unannotated container is unrestricted.
        #expect(!parentNode.isHidden && greenNode.isHidden)

        green.components[VisibilityComponent.self]?.isVisible = false
        try fixture.frame()
        fixture.expectPixel(64, .red)
        fixture.expectPixel(192, .black)
        green.components[VisibilityComponent.self]?.isVisible = true
        try fixture.frame()
        fixture.expectPixel(64, .red)
        fixture.expectPixel(192, .green)
        #expect(!fixture.scene.isPresentationHidden(parentNode))
        #expect(!fixture.scene.isPresentationHidden(greenNode))
        #expect(parent.isActive && red.isActive && green.isActive)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Metal device unavailable"))
    func visuallyHiddenPhysicsAndActionsKeepOneClockAndRemainInModelQueries() throws {
        let fixture = try Fixture()
        fixture.world.physics.gravity = .zero
        let body = Entity(components:
            SpriteComponent(color: Color(red: 1, green: 0, blue: 0), size: [16, 16]),
            VisibilityComponent(layers: .all),
            PhysicsBodyComponent(shape: .circle(radius: 4), linearDamping: 0,
                                 affectedByGravity: false, collisionBitMask: 0, velocity: [60, 0]))
        let control = Entity(components:
            PhysicsBodyComponent(shape: .circle(radius: 4), linearDamping: 0,
                                 affectedByGravity: false, collisionBitMask: 0, velocity: [60, 0]))
        control.position = [0, 40]
        let actor = Entity(components: VisibilityComponent(isVisible: false))
        fixture.world.addEntity(body)
        fixture.world.addEntity(control)
        fixture.world.addEntity(actor)
        try fixture.frame()
        let actorNode = try #require(fixture.scene.node(for: actor))
        actorNode.run(.moveBy(x: 60, y: 0, duration: 1))
        try fixture.frame()

        let query = EntityQuery(where: .has(PhysicsBodyComponent.self))
        let entitiesBefore = Set(fixture.world.performQuery(query).map(\.id))
        let hitsBefore = fixture.world.raycast(from: [-100, 0], to: [100, 0], query: .all).map { $0.entity.id }
        #expect(hitsBefore == [body.id])
        body.components[VisibilityComponent.self]?.isVisible = false
        #expect(Set(fixture.world.performQuery(query).map(\.id)) == entitiesBefore)
        #expect(fixture.world.raycast(from: [-100, 0], to: [100, 0], query: .all).map { $0.entity.id } == hitsBefore)

        var deltas: [TimeInterval] = []
        var activations = 0
        let updates = fixture.world.subscribe(to: WorldEvents.Update.self) { deltas.append($0.deltaTime) }
        let activation = fixture.world.subscribe(to: WorldEvents.DidChangeEntityActivation.self) { _ in activations += 1 }
        // Prime the action before measuring its advancement.
        try fixture.frame()
        deltas.removeAll()
        let bodyBefore = body.position.x
        let controlBefore = control.position.x
        let actionBefore = actorNode.position.x
        for _ in 0..<3 { try fixture.frame() }

        fixture.expectPixel(64, .black)
        fixture.expectPixel(192, .black)
        #expect(deltas.count == 3)
        #expect(deltas.allSatisfy { abs($0 - 1.0 / 60) < 0.00001 })
        #expect(body.position.x - bodyBefore > 2.5 && body.position.x - bodyBefore < 3.1)
        #expect(abs((body.position.x - bodyBefore) - (control.position.x - controlBefore)) < 0.01)
        #expect(actorNode.position.x - actionBefore > 2.5 && actorNode.position.x - actionBefore < 3.1)
        #expect(body.isActive && control.isActive && actor.isActive && fixture.world.root.isActive)
        #expect(activations == 0)
        #expect(Set(fixture.world.performQuery(query).map(\.id)) == entitiesBefore)
        #expect(fixture.world.raycast(from: [-100, 0], to: [100, 0], query: .all).map { $0.entity.id } == hitsBefore)
        let bodyNode = try #require(fixture.scene.node(for: body))
        #expect(bodyNode.isHidden && actorNode.isHidden)
        #expect(!fixture.scene.isPresentationHidden(bodyNode))
        #expect(bodyNode.physicsBody != nil)
        withExtendedLifetime((updates, activation)) {}
    }

    @MainActor private final class Fixture {
        let world = World()
        let scene: SpriteRenderer
        let frames: ViewportFrameRenderer
        let output: any MTLTexture
        let worldCamera: Entity
        let mapCamera: Entity
        private var time: TimeInterval = 100

        init() throws {
            let device = try #require(MTLCreateSystemDefaultDevice())
            scene = SpriteRenderer(world: world, size: CGSize(width: 256, height: 128))
            scene.backgroundColor = .black
            frames = try ViewportFrameRenderer(scene: scene, device: device)
            worldCamera = Entity(components: CameraComponent(smoothing: 0, cullingMask: VisibilityRenderingTests.worldLayer))
            mapCamera = Entity(components: CameraComponent(smoothing: 0, cullingMask: VisibilityRenderingTests.mapLayer))
            world.addEntity(worldCamera)
            world.addEntity(mapCamera)
            world.activeCamera = worldCamera
            scene.viewports = [
                GameViewport(id: "world", camera: worldCamera.id,
                             frame: .init(x: 0, y: 0, width: 0.5, height: 1)),
                GameViewport(id: "map", camera: mapCamera.id,
                             frame: .init(x: 0.5, y: 0, width: 0.5, height: 1))
            ]
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: 256, height: 128, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.renderTarget, .shaderRead]
            output = try #require(device.makeTexture(descriptor: descriptor))
        }

        @discardableResult
        func art(_ color: Color, layers: RenderLayer, parent: Entity? = nil) -> Entity {
            let entity = Entity(components: SpriteComponent(color: color, size: [400, 400]),
                                VisibilityComponent(layers: layers))
            if let parent { parent.addChild(entity) } else { world.addEntity(entity) }
            return entity
        }

        func frame() throws {
            let command = try #require(frames.commandQueue.makeCommandBuffer())
            try frames.encodeFrame(atTime: time, logicalSize: CGSize(width: 256, height: 128),
                                   into: output, commandBuffer: command)
            command.commit()
            command.waitUntilCompleted()
            try #require(command.status == .completed, "GPU error: \(String(describing: command.error))")
            time += 1.0 / 60
        }

        enum Pixel { case red, green, black }

        func expectPixel(_ x: Int, _ expected: Pixel, y: Int = 64,
                         sourceLocation: SourceLocation = #_sourceLocation) {
            var bgra = [UInt8](repeating: 0, count: 4)
            output.getBytes(&bgra, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            let matches: Bool
            switch expected {
            case .red: matches = bgra[2] > 240 && bgra[1] < 10 && bgra[0] < 10
            case .green: matches = bgra[1] > 240 && bgra[2] < 10 && bgra[0] < 10
            case .black: matches = bgra.prefix(3).allSatisfy { $0 < 10 }
            }
            #expect(matches, "Pixel (\(x), \(y)) expected \(expected), BGRA: \(bgra)", sourceLocation: sourceLocation)
        }
    }
}
