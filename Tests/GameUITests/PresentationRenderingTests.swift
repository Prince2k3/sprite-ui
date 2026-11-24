import ECSCore
import Foundation
@testable import GameUI
import Metal
@_spi(Backend) import SpriteBackend
import SpriteKit
import SwiftUI
import Testing

@MainActor @Suite struct PresentationRenderingTests {
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Metal device unavailable"),
          arguments: ["left", "right"])
    func selectedCameraExportsCompletedPixelsWithoutAdditionalSimulation(viewportID: String) async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = makeScene()
        let frames = try ViewportFrameRenderer(scene: fixture.scene, device: device)
        let output = try makeTexture(device: device, size: fixture.scene.size)
        let source = GamePresentationSource(viewportID: viewportID), owner = UUID()
        try #require(source.attach(owner: owner))
        defer { source.detach(owner: owner) }
        var updates = 0
        let token = fixture.world.subscribe(to: WorldEvents.Update.self) { _ in updates += 1 }
        defer { token.cancel() }

        // SpriteKit warms its offscreen resources before pixel assertions.
        try await render(frames, at: 100, into: output)
        #expect(updates == 1)
        #expect(source.acquireFrame() == nil)
        for index in 1...2 {
            try await render(frames, at: 100 + Double(index) / 60, into: output,
                             source: source, owner: owner)
            #expect(updates == index + 1, "Each primary frame must deliver exactly one World.Update")
            let read = try await acquireCompletedFrame(source, number: frames.frameNumber)
            defer { read.release() }
            #expect(source.pixelSize == CGSize(width: 128, height: 128))
            #expect(read.width == 128 && read.height == 128)
            #expect(source.publishedFrameCount == UInt64(index))
            let exported = try await pixel(read.texture, x: read.width / 2, y: read.height / 2,
                                           queue: frames.commandQueue)
            expectColor(exported, green: viewportID == "right")
            let left = try await pixel(output, x: 64, y: 64, queue: frames.commandQueue)
            let right = try await pixel(output, x: 192, y: 64, queue: frames.commandQueue)
            expectColor(left, green: false)
            expectColor(right, green: true)

            let beforeReads = updates
            let actionNode = try #require(fixture.scene.node(for: fixture.sprites[0]))
            actionNode.run(.moveBy(x: 10, y: 0, duration: 1), withKey: "read-does-not-tick")
            let position = actionNode.position
            let clock = fixture.scene.presentationClockTime
            let capture = try frames.capturePresentation()
            #expect(capture.width == output.width && capture.height == output.height)
            #expect(try frames.capturePresentation() == capture)
            let secondRead = try #require(source.acquireFrame())
            defer { secondRead.release() }
            let repeated = try await pixel(secondRead.texture, x: secondRead.width / 2,
                                           y: secondRead.height / 2, queue: frames.commandQueue)
            #expect(repeated == exported)
            #expect(updates == beforeReads)
            #expect(actionNode.position == position)
            #expect(fixture.scene.presentationClockTime == clock)
            #expect(source.frameNumber == frames.frameNumber)
            actionNode.removeAction(forKey: "read-does-not-tick")
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Metal device unavailable"))
    func reducedPixelBudgetPreservesLogicalCameraProjectionAndOnlyUpdatesOnce() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = makeScene(), logicalSize = CGSize(width: 256, height: 128)
        let frames = try ViewportFrameRenderer(scene: fixture.scene, device: device)
        let nativeOutput = try makeTexture(device: device, size: logicalSize)
        let source = GamePresentationSource(viewportID: "right"), owner = UUID()
        try #require(source.attach(owner: owner))
        defer { source.detach(owner: owner) }
        var updates = 0
        let token = fixture.world.subscribe(to: WorldEvents.Update.self) { _ in updates += 1 }
        defer { token.cancel() }
        try await render(frames, at: 100, into: nativeOutput)
        #expect(updates == 1)

        let ids = ["left", "right"]
        let rects = try ids.map { try #require(fixture.scene.viewportRect(id: $0)) }
        let cameraPositions = fixture.cameras.map(\.position)
        let scenePoints = cameraPositions.map { $0 + SIMD2<Float>(20, 12) }
        let projections = try ids.indices.map { index in
            try #require(fixture.scene.viewPoint(from: scenePoints[index], inViewport: ids[index]))
        }
        let configuration = GameRenderConfiguration(maximumRenderPixels: 6000)
        let plan = GameRenderPlan(logicalSize: logicalSize, displayScale: 2, viewportRects: rects,
            configuration: configuration, presentationViewportIndex: 1, presentationCopies: 3)
        try #require(plan.isValid)
        #expect(plan.totalRenderPixels <= configuration.maximumRenderPixels)
        #expect(plan.drawableSize.width < logicalSize.width)
        #expect(plan.effectiveResolutionScale < 1)
        let reducedOutput = try makeTexture(device: device, size: plan.drawableSize)

        // Match the primary host: update once before sizing, then encode without
        // asking the encoder to update the world a second time.
        frames.advanceScene(atTime: 100 + 1.0 / 60, logicalSize: logicalSize)
        #expect(updates == 2)
        try await render(frames, at: 100 + 1.0 / 60, into: reducedOutput, plan: plan,
                         updatesScene: false, source: source, owner: owner)
        #expect(updates == 2)
        #expect(frames.lastPlan?.drawableSize == plan.drawableSize)
        #expect(frames.lastPlan?.totalRenderPixels == plan.totalRenderPixels)
        #expect(fixture.scene.size == logicalSize)
        #expect(fixture.cameras.map(\.position) == cameraPositions)
        for index in ids.indices {
            let id = ids[index], rect = rects[index]
            #expect(fixture.scene.viewportRect(id: id) == rect)
            #expect(fixture.scene.scenePoint(fromView: CGPoint(x: rect.midX, y: rect.midY), inViewport: id)
                == cameraPositions[index])
            #expect(fixture.scene.viewPoint(from: scenePoints[index], inViewport: id) == projections[index])
            #expect(fixture.scene.scenePoint(fromView: projections[index], inViewport: id) == scenePoints[index])
            #expect(fixture.scene.viewport(at: projections[index])?.id == id)
            #expect(projections[index] == CGPoint(x: rect.midX + 20, y: rect.midY - 12))
            let pixels = plan.panePixelRects[index]
            let color = try await pixel(reducedOutput, x: Int(pixels.midX), y: Int(pixels.midY),
                                        queue: frames.commandQueue)
            expectColor(color, green: index == 1)
        }
        let read = try await acquireCompletedFrame(source, number: frames.frameNumber)
        defer { read.release() }
        #expect(source.pixelSize == plan.panePixelRects[1].size)
        let exported = try await pixel(read.texture, x: read.width / 2, y: read.height / 2,
                                       queue: frames.commandQueue)
        expectColor(exported, green: true)
        _ = try frames.capturePresentation()
        #expect(updates == 2)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Metal device unavailable"))
    func disappearingSelectedViewportInvalidatesSourceWhileExistingLeaseStaysReadable() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = makeScene()
        let frames = try ViewportFrameRenderer(scene: fixture.scene, device: device)
        let output = try makeTexture(device: device, size: fixture.scene.size)
        let source = GamePresentationSource(viewportID: "right"), owner = UUID()
        try #require(source.attach(owner: owner))
        defer { source.detach(owner: owner) }
        var updates = 0
        let token = fixture.world.subscribe(to: WorldEvents.Update.self) { _ in updates += 1 }
        defer { token.cancel() }
        try await render(frames, at: 100, into: output)
        try await render(frames, at: 100 + 1.0 / 60, into: output, source: source, owner: owner)
        let previous = try await acquireCompletedFrame(source, number: frames.frameNumber)
        defer { previous.release() }
        #expect(source.isAvailable)
        #expect(updates == 2)

        fixture.scene.viewports.removeAll { $0.id == "right" }
        try await render(frames, at: 100 + 2.0 / 60, into: output, source: source, owner: owner)
        #expect(updates == 3)
        #expect(fixture.scene.viewportRect(id: "left") != nil)
        #expect(fixture.scene.viewportRect(id: "right") == nil)
        #expect(!source.isAvailable)
        #expect(source.pixelSize == .zero)
        #expect(source.frameNumber == 0)
        #expect(source.acquireFrame() == nil, "A missing pane must not fall back to the canvas or a stale frame")
        let retained = try await pixel(previous.texture, x: previous.width / 2, y: previous.height / 2,
                                       queue: frames.commandQueue)
        expectColor(retained, green: true)
        _ = try frames.capturePresentation()
        #expect(updates == 3)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Metal device unavailable"))
    func legacyClockTakeoverStartsAtZeroDeltaThenAdvancesNormally() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = makeScene()
        fixture.scene.scaleMode = .fill
        let legacy = SKRenderer(device: device)
        legacy.scene = fixture.scene
        var deltas: [TimeInterval] = []
        let token = fixture.world.subscribe(to: WorldEvents.Update.self) { deltas.append($0.deltaTime) }
        defer { token.cancel() }
        legacy.update(atTime: 1000)
        legacy.update(atTime: 1000 + 1.0 / 60)
        try #require(deltas.count == 2)
        #expect(abs(deltas[1] - 1.0 / 60) < 0.000001)
        let inheritedTime = try #require(fixture.scene.presentationClockTime)

        let frames = try ViewportFrameRenderer(scene: fixture.scene, device: device)
        let output = try makeTexture(device: device, size: fixture.scene.size)
        deltas.removeAll()
        try await render(frames, at: 500_000, into: output)
        #expect(deltas == [0], "Replacing the display driver must not inject a stale or negative delta")
        #expect(fixture.scene.presentationClockTime == inheritedTime)
        try await render(frames, at: 500_000 + 1.0 / 60, into: output)
        try #require(deltas.count == 2)
        #expect(abs(deltas[1] - 1.0 / 60) < 0.000001)
        let advancedTime = try #require(fixture.scene.presentationClockTime)
        #expect(abs(advancedTime - inheritedTime - 1.0 / 60) < 0.000001)
        _ = try frames.capturePresentation()
        #expect(deltas.count == 2)
    }

    private struct Fixture {
        let world: World
        let scene: SpriteRenderer
        let cameras: [Entity]
        let sprites: [Entity]
    }

    private func makeScene() -> Fixture {
        let world = World()
        let scene = SpriteRenderer(world: world, size: CGSize(width: 256, height: 128))
        var cameras: [Entity] = [], sprites: [Entity] = []
        for x: Float in [-250, 250] {
            let camera = Entity(components: CameraComponent(smoothing: 0))
            camera.position = [x, 0]
            world.addEntity(camera)
            cameras.append(camera)
            let color = x < 0 ? Color(red: 1, green: 0, blue: 0) : Color(red: 0, green: 1, blue: 0)
            let sprite = Entity(components: SpriteComponent(color: color, size: [400, 400]))
            sprite.position = [x, 0]
            world.addEntity(sprite)
            sprites.append(sprite)
        }
        scene.viewports = [
            .init(id: "left", camera: cameras[0].id, frame: .init(x: 0, y: 0, width: 0.5, height: 1)),
            .init(id: "right", camera: cameras[1].id, frame: .init(x: 0.5, y: 0, width: 0.5, height: 1))
        ]
        return Fixture(world: world, scene: scene, cameras: cameras, sprites: sprites)
    }

    private func makeTexture(device: any MTLDevice, size: CGSize) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: Int(size.width), height: Int(size.height), mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    private func render(_ frames: ViewportFrameRenderer, at time: TimeInterval, into output: any MTLTexture,
                        plan: GameRenderPlan? = nil, updatesScene: Bool = true,
                        source: GamePresentationSource? = nil, owner: UUID? = nil) async throws {
        let command = try #require(frames.commandQueue.makeCommandBuffer())
        try frames.encodeFrame(atTime: time, logicalSize: frames.scene.size, into: output, commandBuffer: command,
            plan: plan, updatesScene: updatesScene, presentation: source, presentationOwner: owner)
        try await execute(command)
    }

    private func execute(_ command: any MTLCommandBuffer) async throws {
        await withCheckedContinuation { continuation in
            command.addCompletedHandler { _ in continuation.resume() }
            command.commit()
        }
        try #require(command.status == .completed, "GPU error: \(String(describing: command.error))")
    }

    private func acquireCompletedFrame(_ source: GamePresentationSource,
                                       number: UInt64) async throws -> GamePresentationReadLease {
        // GPU completion queues publication back to the main actor. Yield to
        // that task instead of assuming command completion published inline.
        let deadline = ContinuousClock.now + .seconds(5)
        while (!source.isAvailable || source.frameNumber != number), ContinuousClock.now < deadline {
            await Task.yield()
        }
        try #require(source.isAvailable && source.frameNumber == number,
                     "Completed presentation frame did not reach the main actor")
        return try #require(source.acquireFrame())
    }

    private func pixel(_ texture: any MTLTexture, x: Int, y: Int,
                       queue: any MTLCommandQueue) async throws -> [UInt8] {
        // Presentation leases use private textures. Blit one pixel to shared
        // storage, and wait for the consumer GPU command before reading it.
        let readable = try makeTexture(device: texture.device, size: CGSize(width: 1, height: 1))
        let command = try #require(queue.makeCommandBuffer())
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
            sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: readable,
            destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        try await execute(command)
        var bytes = [UInt8](repeating: 0, count: 4)
        readable.getBytes(&bytes, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        return bytes
    }

    private func expectColor(_ bytes: [UInt8], green: Bool) {
        #expect(bytes[0] < 10 && bytes[3] > 240, "BGRA: \(bytes)")
        #expect(bytes[green ? 1 : 2] > 240 && bytes[green ? 2 : 1] < 10, "BGRA: \(bytes)")
    }
}
