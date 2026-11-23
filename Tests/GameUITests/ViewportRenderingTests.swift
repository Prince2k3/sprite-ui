import ECSCore
@testable import GameUI
import Metal
import SpriteBackend
import SpriteKit
import SwiftUI
import Testing

@MainActor @Suite struct ViewportRenderingTests {
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Metal device unavailable"))
    func actualEncoderRendersLateECSEntitiesThroughTwoCamerasWithOneUpdate() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let world = World()
        let scene = SpriteRenderer(world: world, size: CGSize(width: 256, height: 128))
        let frames = try ViewportFrameRenderer(scene: scene, device: device)
        var cameras: [Entity] = []
        for x: Float in [-250, 250] {
            let camera = Entity(components: CameraComponent(smoothing: 0))
            camera.position = [x, 0]
            world.addEntity(camera)
            cameras.append(camera)
            let color = x < 0 ? Color(red: 1, green: 0, blue: 0) : Color(red: 0, green: 1, blue: 0)
            let sprite = Entity(components: SpriteComponent(color: color, size: [400, 400]))
            sprite.position = [x, 0]
            world.addEntity(sprite)
        }
        scene.viewports = [
            GameViewport(id: "left", camera: cameras[0].id,
                         frame: .init(x: 0, y: 0.125, width: 0.375, height: 0.75)),
            GameViewport(id: "right", camera: cameras[1].id,
                         frame: .init(x: 0.625, y: 0.25, width: 0.375, height: 0.5))
        ]
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 256, height: 128, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        let output = try #require(device.makeTexture(descriptor: descriptor))
        var updates = 0
        let subscription = world.subscribe(to: WorldEvents.Update.self) { _ in updates += 1 }
        func frame(_ time: TimeInterval) throws {
            let command = try #require(frames.commandQueue.makeCommandBuffer())
            try frames.encodeFrame(atTime: time, logicalSize: scene.size,
                                   into: output, commandBuffer: command)
            command.commit()
            command.waitUntilCompleted()
            try #require(command.status == .completed, "GPU error: \(String(describing: command.error))")
        }
        // SpriteKit's first offscreen render warms its draw resources.
        try frame(100)
        updates = 0
        try frame(100 + 1.0 / 60)
        func pixel(_ x: Int, _ y: Int = 64) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            output.getBytes(&bytes, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            return bytes
        }
        let left = pixel(64), right = pixel(192)
        #expect(left[2] > 240 && left[1] < 10 && left[0] < 10, "left BGRA: \(left)")
        #expect(right[1] > 240 && right[2] < 10 && right[0] < 10, "right BGRA: \(right)")
        #expect(pixel(128).prefix(3).allSatisfy { $0 == 0 })
        #expect(pixel(64, 0).prefix(3).allSatisfy { $0 == 0 })
        #expect(pixel(192, 120).prefix(3).allSatisfy { $0 == 0 })
        #expect(updates == 1)
        #expect(scene.size == CGSize(width: 256, height: 128))
        #expect(scene.scaleMode == .resizeFill)
        withExtendedLifetime(subscription) {}
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Metal device unavailable"))
    func resumingAfterAHundredSecondsDoesNotAdvanceActionsOrPhysics() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let world = World()
        world.physics.gravity = .zero
        let scene = SpriteRenderer(world: world, size: CGSize(width: 128, height: 128))
        let frames = try ViewportFrameRenderer(scene: scene, device: device)
        let actor = Entity()
        let body = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 4),
            linearDamping: 0, affectedByGravity: false, velocity: [60, 0]))
        world.addEntity(actor)
        world.addEntity(body)
        // Three camera draws must still share one action/physics clock.
        scene.viewports = [
            GameViewport(id: "left", frame: .init(x: 0, y: 0, width: 0.5, height: 1)),
            GameViewport(id: "right", frame: .init(x: 0.5, y: 0, width: 0.5, height: 1)),
            GameViewport(id: "map", frame: .init(x: 0.75, y: 0, width: 0.25, height: 0.25))
        ]
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 128, height: 128, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        let output = try #require(device.makeTexture(descriptor: descriptor))
        var deltas: [TimeInterval] = []
        var changeSettingsOnResume = false
        let subscription = world.subscribe(to: WorldEvents.Update.self) { event in
            deltas.append(event.deltaTime)
            if changeSettingsOnResume && event.deltaTime == 0 {
                // Settings callbacks must not re-enable native physics inside
                // the suspended resume update.
                world.physics.gravity = .zero
                world.timeScale = 2
                world.timeScale = 1
            }
        }
        func frame(_ time: TimeInterval) throws {
            let command = try #require(frames.commandQueue.makeCommandBuffer())
            try frames.encodeFrame(atTime: time, logicalSize: CGSize(width: 128, height: 128),
                                   into: output, commandBuffer: command)
            command.commit()
            command.waitUntilCompleted()
            try #require(command.status == .completed)
        }
        try frame(100)
        let node = try #require(scene.node(for: actor))
        node.run(.moveBy(x: 60, y: 0, duration: 1))
        try frame(100 + 1.0 / 60)
        try frame(100 + 2.0 / 60)
        let actionBefore = node.position.x, physicsBefore = body.position.x
        let physicsNode = try #require(scene.node(for: body))
        let nativePhysicsBefore = physicsNode.position.x
        #expect(actionBefore > 0 && physicsBefore > 0)
        frames.resetClock()
        changeSettingsOnResume = true
        deltas.removeAll()
        try frame(200 + 2.0 / 60)
        #expect(abs(node.position.x - actionBefore) < 0.0001)
        #expect(abs(body.position.x - physicsBefore) < 0.0001)
        #expect(abs(physicsNode.position.x - nativePhysicsBefore) < 0.0001)
        #expect(deltas == [0])
        try frame(200 + 3.0 / 60)
        #expect(node.position.x > actionBefore)
        #expect(body.position.x > physicsBefore)
        #expect(body.position.x - physicsBefore < 1.1)
        #expect(deltas.count == 2)
        #expect(abs((deltas.last ?? 0) - 1.0 / 60) < 0.00001)
        let actionAfter = node.position.x
        // Active stalls use the same 1/15 cap as the ECS, not a wall-clock jump.
        try frame(300)
        #expect(node.position.x - actionAfter < 4.1)
        #expect(abs((deltas.last ?? 0) - 1.0 / 15) < 0.00001)
        withExtendedLifetime(subscription) {}
    }
}
