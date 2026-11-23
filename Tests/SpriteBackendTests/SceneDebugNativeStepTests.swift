import ECSCore
import Foundation
import Metal
import SpriteKit
import Testing
@testable import SpriteBackend

@MainActor @Suite struct SceneDebugNativeStepTests {
    @Test func aNativeStepAdvancesActionsAndPhysicsThenFreezesBoth() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let world = World(), scene = SpriteRenderer(world: world, size: CGSize(width: 300, height: 300))
        world.physics.gravity = .zero
        let actor = Entity(), body = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 4),
            linearDamping: 0, affectedByGravity: false, velocity: [60, 0]))
        world.addEntity(actor); world.addEntity(body)
        let debug = SceneDebugController(options: [.statistics]); scene.setDebugController(debug)
        let native = SKRenderer(device: device); native.scene = scene
        let queue = try #require(device.makeCommandQueue())
        let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 300, height: 300, mipmapped: false)
        description.usage = [.renderTarget, .shaderRead]
        let target = try #require(device.makeTexture(descriptor: description))
        var time = ProcessInfo.processInfo.systemUptime
        func frame() throws {
            native.update(atTime: time)
            let buffer = try #require(queue.makeCommandBuffer())
            let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            native.render(withViewport: CGRect(x: 0, y: 0, width: 300, height: 300), commandBuffer: buffer, renderPassDescriptor: pass)
            buffer.commit(); buffer.waitUntilCompleted()
            #expect(buffer.status == .completed)
            time += 1.0 / 60
        }
        try frame()
        withAnimation(.linear(duration: 5)) { actor.position = [300, 0] }
        for _ in 0..<12 { try frame() }
        let actorNode = try #require(scene.node(for: actor))
        #expect(actorNode.position.x > 0)
        debug.isPaused = true
        for _ in 0..<5 { try frame() }
        let startAction = actorNode.position.x, startBody = body.position.x
        debug.refresh(); let startFrame = debug.snapshot.simulationFrameNumber
        #expect(debug.stepFrame())
        for _ in 0..<3 { try frame() }
        debug.refresh()
        #expect(debug.snapshot.simulationFrameNumber == startFrame + 1)
        #expect(actorNode.position.x > startAction)
        #expect(body.position.x > startBody)
        #expect(world.isPaused && !debug.isStepPending)
        let steppedAction = actorNode.position.x, steppedBody = body.position
        for _ in 0..<5 { try frame() }
        #expect(actorNode.position.x == steppedAction)
        #expect(body.position == steppedBody)
    }
}
