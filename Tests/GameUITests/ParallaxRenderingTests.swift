import ECSCore
import Foundation
@testable import GameUI
import Metal
@_spi(Backend) @testable import SpriteBackend
import SpriteKit
import SwiftUI
import Testing

@MainActor @Suite struct ParallaxRenderingTests {
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func eachCameraGetsItsOwnOffsetAndOrdinaryWorldScrollingCanBeRestored() throws {
        let f = try Fixture()
        f.a.position = [-32, 0]; f.b.position = [32, 0]
        let art = f.art(size: [24, 24], repeatTiles: false)
        art.components.set(ParallaxComponent(scrollFactor: .zero))
        try f.frame(); try f.frame()
        f.pixel(64, .red); f.pixel(192, .red)
        #expect(art.position == .zero && f.scene.node(for: art)?.position == .zero)
        art.components[ParallaxComponent.self]?.scrollFactor = [1, 1]
        try f.frame()
        f.pixel(64, .black); f.pixel(192, .black)
        f.pixel(96, .red); f.pixel(160, .red)
        art.components[ParallaxComponent.self]?.scrollFactor = [0.5, 0]
        f.b.position = [80, 0]
        try f.frame()
        f.pixel(80, .red); f.pixel(152, .red); f.pixel(192, .black)
        f.scene.viewports.reverse()
        try f.frame()
        f.pixel(80, .red); f.pixel(152, .red)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func repeatedCoverageSurvivesZoomRotationParentTransformsAndResize() throws {
        let f = try Fixture()
        let parent = Entity(); parent.position = [13, -7]
        parent.rotation = 0.4; parent.scale = [1.2, 0.7]; f.world.addEntity(parent)
        let art = f.art(size: [24, 24]); parent.addChild(art)
        art.components.set(ParallaxComponent(scrollFactor: [0.3, 0.7]))
        f.a.position = [-1_000_000, 23]; f.b.position = [1_000_000, -19]
        f.a.rotation = -0.25; f.b.rotation = 0.35
        f.a.components[CameraComponent.self]?.zoom = 0.5
        f.b.components[CameraComponent.self]?.zoom = 1.7
        try f.frame(); try f.frame()
        for x in [1, 17, 63, 126, 129, 180, 254] {
            for y in [1, 29, 64, 126] { f.pixel(x, .red, y: y) }
        }
        let pool = try #require(f.scene.backgroundTiles[art.id])
        let retained = pool.sprites.count
        #expect(retained <= 1024)
        try f.frame(size: CGSize(width: 400, height: 180))
        for x in [1, 126, 129, 254] { f.pixel(x, .red, y: 5); f.pixel(x, .red, y: 122) }
        #expect(f.scene.backgroundTiles[art.id] === pool)
        #expect(art.position == .zero && parent.position == [13, -7])
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func negativeAndLargeCoordinatesKeepTexturePhaseRatherThanAccumulatingOffsets() throws {
        let f = try Fixture()
        let pixels = (0..<8).flatMap { x -> [UInt8] in x < 4 ? [255, 0, 0, 255] : [0, 255, 0, 255] }
        let art = Entity(components:
            SpriteComponent(image: SpriteImage(width: 8, height: 1, pixels: pixels, smoothsScaling: false), size: [32, 16]),
            RepeatingBackgroundComponent())
        f.world.addEntity(art)
        try f.frame(); try f.frame()
        f.pixel(66, .green); f.pixel(62, .red)
        f.a.position = [-1_000_000, 0]
        try f.frame()
        f.pixel(66, .green); f.pixel(62, .red)
        f.a.position.x += 16
        try f.frame()
        f.pixel(66, .red); f.pixel(62, .green)
        art.components.set(ParallaxComponent(scrollFactor: .zero))
        try f.frame()
        f.pixel(66, .green); f.pixel(194, .green)
        f.a.position = [1_000_016, 0]
        try f.frame()
        f.pixel(66, .green); f.pixel(194, .green)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func budgetsInvalidGeometryVisibilityAndSpriteReplacementDoNotLeaveStaleTiles() throws {
        let f = try Fixture()
        let art = f.art(size: [16, 16])
        art.components.set(MaskComponent(shape: .rectangle(size: [400, 400])))
        art.components.set(RenderGroupComponent(effects: [.colorAdjustment()]))
        try f.frame(); try f.frame(); f.pixel(1, .red); f.pixel(254, .red)
        art.components[RepeatingBackgroundComponent.self]?.maximumTileCount = 1
        try f.frame(); f.pixel(64, .black); f.pixel(192, .black)
        art.components[RepeatingBackgroundComponent.self]?.maximumTileCount = .max
        art.components[SpriteComponent.self]?.size = [0.001, 0.001]
        try f.frame(); f.pixel(64, .black)
        #expect((f.scene.backgroundTiles[art.id]?.sprites.count ?? 0) <= 16_384)
        art.components[RepeatingBackgroundComponent.self]?.maximumTileCount = 1024
        art.components[SpriteComponent.self]?.size = .zero
        try f.frame(); f.pixel(64, .black)
        art.components.remove(SpriteComponent.self); f.scene.flush()
        #expect(f.scene.backgroundTiles[art.id] == nil)
        art.components.set(SpriteComponent(color: Color(red: 0, green: 1, blue: 0), size: [16, 16]))
        try f.frame(); f.pixel(64, .green); f.pixel(192, .green)
        art.components.set(VisibilityComponent(isVisible: false))
        try f.frame(); f.pixel(64, .black); f.pixel(192, .black)
        art.components[VisibilityComponent.self]?.isVisible = true
        art.components[RepeatingBackgroundComponent.self]?.isEnabled = false
        try f.frame(); f.pixel(64, .green); f.pixel(1, .black)
        art.isEnabled = false
        try f.frame(); f.pixel(64, .black)
        art.isEnabled = true
        try f.frame(); f.pixel(64, .green)
        art.removeFromParent()
        try f.frame(); f.pixel(64, .black)
        #expect(f.scene.backgroundTiles[art.id] == nil && !f.scene.backgroundEntities.contains(art.id))
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func twoCameraDrawsAdvanceOneSimulationAndLeaveBodyTransformsInWorldSpace() throws {
        let f = try Fixture()
        let art = f.art(size: [20, 20], repeatTiles: false)
        art.components.set(ParallaxComponent(scrollFactor: .zero))
        let body = PhysicsBodyComponent(shape: .circle(radius: 5), linearDamping: 0,
                                       affectedByGravity: false, collisionBitMask: 0, velocity: [60, 0])
        art.components.set(body)
        let control = Entity(components: body); control.position.y = 40; f.world.addEntity(control)
        try f.frame(); try f.frame()
        var updates = 0
        let subscription = f.world.subscribe(to: WorldEvents.Update.self) { _ in updates += 1 }
        let before = art.position.x, otherBefore = control.position.x
        for _ in 0..<3 { try f.frame() }
        #expect(updates == 3)
        #expect(abs((art.position.x - before) - 3) < 0.05)
        #expect(abs((art.position.x - before) - (control.position.x - otherBefore)) < 0.01)
        #expect(abs(Float(try #require(f.scene.node(for: art)).position.x) - art.position.x) < 0.001)
        withExtendedLifetime(subscription) {}
    }

    @MainActor private final class Fixture {
        let world = World()
        let scene: SpriteRenderer
        let frames: ViewportFrameRenderer
        let output: any MTLTexture
        let a = Entity(components: CameraComponent(smoothing: 0))
        let b = Entity(components: CameraComponent(smoothing: 0))
        private var time: TimeInterval = 100
        init() throws {
            let device = try #require(MTLCreateSystemDefaultDevice())
            scene = SpriteRenderer(world: world, size: CGSize(width: 256, height: 128))
            frames = try ViewportFrameRenderer(scene: scene, device: device)
            world.addEntity(a); world.addEntity(b); world.activeCamera = a
            scene.viewports = [.init(id: "a", camera: a.id, frame: .init(x: 0, y: 0, width: 0.5, height: 1)),
                               .init(id: "b", camera: b.id, frame: .init(x: 0.5, y: 0, width: 0.5, height: 1))]
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 256, height: 128, mipmapped: false)
            descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
            output = try #require(device.makeTexture(descriptor: descriptor))
        }
        func art(size: SIMD2<Float>, repeatTiles: Bool = true) -> Entity {
            let entity = Entity(components: SpriteComponent(color: Color(red: 1, green: 0, blue: 0), size: size))
            if repeatTiles { entity.components.set(RepeatingBackgroundComponent()) }
            world.addEntity(entity); return entity
        }
        func frame(size: CGSize = CGSize(width: 256, height: 128)) throws {
            let command = try #require(frames.commandQueue.makeCommandBuffer())
            try frames.encodeFrame(atTime: time, logicalSize: size, into: output, commandBuffer: command)
            command.commit(); command.waitUntilCompleted()
            try #require(command.status == .completed)
            time += 1.0 / 60
        }
        enum Pixel { case red, green, black }
        func pixel(_ x: Int, _ expected: Pixel, y: Int = 64, sourceLocation: SourceLocation = #_sourceLocation) {
            var bytes = [UInt8](repeating: 0, count: 4)
            output.getBytes(&bytes, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            let matches: Bool
            switch expected {
            case .red: matches = bytes[2] > 240 && bytes[1] < 10 && bytes[0] < 10
            case .green: matches = bytes[1] > 240 && bytes[2] < 10 && bytes[0] < 10
            case .black: matches = bytes.prefix(3).allSatisfy { $0 < 10 }
            }
            #expect(matches, "Pixel (\(x),\(y)) expected \(expected), got BGRA \(bytes)", sourceLocation: sourceLocation)
        }
    }
}
