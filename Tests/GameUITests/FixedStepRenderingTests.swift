import ECSCore
import Foundation
@testable import GameUI
import Metal
@_spi(Backend) import SpriteBackend
import SpriteKit
import SwiftUI
import Testing

private struct FixedRenderMover: Component { var speed: Float = 60 }

@MainActor private struct FixedRenderSystem: System {
    static var phase: SystemPhase { .fixedSimulation }
    init(world: World) {}
    mutating func update(context: UpdateContext) {
        for entity in context.entities(matching: EntityQuery(where: .has(FixedRenderMover.self))) {
            entity.position.x += entity.components[FixedRenderMover.self]!.speed * Float(context.deltaTime)
        }
    }
}

@MainActor @Suite struct FixedStepRenderingTests {
    @MainActor private final class Fixture {
        let world = World()
        let scene: SpriteRenderer
        let frames: ViewportFrameRenderer
        let actor: Entity
        let output: any MTLTexture

        init(rate: Double = 60, speed: Float = 60) throws {
            let device = try #require(MTLCreateSystemDefaultDevice())
            world.fixedStep = .init(stepsPerSecond: rate)
            world.addSystem(FixedRenderSystem.self)
            scene = SpriteRenderer(world: world, size: CGSize(width: 128, height: 128))
            actor = Entity(components: SpriteComponent(color: Color(red: 1, green: 0, blue: 0), size: [4, 4]),
                           FixedRenderMover(speed: speed), TransformInterpolationComponent())
            world.addEntity(actor)
            frames = try ViewportFrameRenderer(scene: scene, device: device)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: 128, height: 128, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.renderTarget, .shaderRead]
            output = try #require(device.makeTexture(descriptor: descriptor))
        }

        func frame(_ time: TimeInterval, source: GamePresentationSource? = nil, owner: UUID? = nil) throws {
            let command = try #require(frames.commandQueue.makeCommandBuffer())
            try frames.encodeFrame(atTime: time, logicalSize: CGSize(width: 128, height: 128),
                into: output, commandBuffer: command, presentation: source, presentationOwner: owner)
            command.commit(); command.waitUntilCompleted()
            try #require(command.status == .completed)
        }

        func pixel(_ x: Int, _ y: Int = 64) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            output.getBytes(&bytes, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            return bytes
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil), arguments: [30, 60, 120])
    func displayCadenceDoesNotChangeCustomSimulationRate(fps: Int) throws {
        let f = try Fixture()
        var updates = 0, finishes = 0
        let update = f.world.subscribe(to: WorldEvents.Update.self) { _ in updates += 1 }
        let finish = f.world.subscribe(to: RenderingEvents.DidUpdate.self) { _ in finishes += 1 }
        defer { update.cancel(); finish.cancel() }
        try f.frame(100)
        for frame in 1...fps { try f.frame(100 + Double(frame) / Double(fps)) }
        #expect(f.world.fixedStepState.tick == 60)
        #expect(abs(f.world.fixedStepState.simulationTime - 1) < 0.000_001)
        #expect(abs(f.actor.position.x - 60) < 0.001)
        #expect(updates == fps + 1 && finishes == fps + 1)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func fixedCatchUpUsesWallTimeWhileNativeFrameDeltaRemainsCapped() throws {
        let f = try Fixture()
        var frameDeltas: [TimeInterval] = []
        let update = f.world.subscribe(to: WorldEvents.Update.self) { frameDeltas.append($0.deltaTime) }
        defer { update.cancel() }
        try f.frame(100)
        try f.frame(100.5)
        #expect(f.world.fixedStepState.tick == 8)
        #expect(f.world.fixedStepState.ticksThisFrame == 8)
        #expect(abs(f.actor.position.x - 8) < 0.001)
        #expect(abs(f.world.fixedStepState.droppedTime - (0.5 - 8.0 / 60)) < 0.000_001)
        #expect(frameDeltas.count == 2)
        #expect(abs((frameDeltas.last ?? 0) - 1.0 / 15) < 0.000_001)
        // Rebase, preserving elapsed ticks while rejecting background debt.
        f.frames.resetClock()
        try f.frame(10_000)
        #expect(f.world.fixedStepState.tick == 8 && f.world.fixedStepState.ticksThisFrame == 0)
        try f.frame(10_000 + 1.0 / 60)
        #expect(f.world.fixedStepState.tick == 9)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func actualEncoderAndCachedCaptureShowInterpolatedPixelsWithoutChangingTheModel() throws {
        let f = try Fixture(rate: 10, speed: 120)
        try f.frame(100)
        try f.frame(100.15)
        #expect(f.world.fixedStepState.tick == 1)
        #expect(abs(f.world.fixedStepState.interpolationAlpha - 0.5) < 0.000_001)
        #expect(abs(f.actor.position.x - 12) < 0.001)
        #expect(abs(f.actor.presentation.position.x - 6) < 0.001)
        let displayed = f.pixel(70), canonical = f.pixel(76)
        let redColumns = (0..<128).filter { f.pixel($0)[2] > 240 }
        #expect(displayed[2] > 240 && displayed[0] < 10 && displayed[1] < 10,
                "BGRA at displayed pose: \(displayed); red columns: \(redColumns)")
        #expect(canonical.prefix(3).allSatisfy { $0 < 10 })
        let before = f.world.fixedStepState
        let capture = try f.frames.capturePresentation()
        let offset = (64 * capture.width + 70) * 4
        #expect(capture.pixels[offset] > 240 && capture.pixels[offset + 1] < 10)
        #expect(f.world.fixedStepState == before && abs(f.actor.position.x - 12) < 0.001)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func passivePublicationAndReadbackNeverRunAnotherFixedTick() async throws {
        let f = try Fixture()
        let source = GamePresentationSource(), owner = UUID()
        try #require(source.attach(owner: owner))
        defer { source.detach(owner: owner) }
        try f.frame(100)
        try f.frame(100 + 1.0 / 30, source: source, owner: owner)
        let deadline = ContinuousClock.now + .seconds(5)
        while !source.isAvailable && ContinuousClock.now < deadline { await Task.yield() }
        try #require(source.isAvailable)
        let before = f.world.fixedStepState
        #expect(before.tick == 2)
        for _ in 0..<3 {
            let read = try #require(source.acquireFrame())
            #expect(read.width == 128 && read.height == 128)
            read.release()
            _ = try f.frames.capturePresentation()
        }
        #expect(f.world.fixedStepState == before && abs(f.actor.position.x - 2) < 0.001)
    }
}
