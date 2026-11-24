import Foundation
@testable import GameUI
import MetalKit
import SwiftUI
import Testing

@MainActor @Suite struct GamePresentationTests {
    private func metal() throws -> (any MTLDevice, any MTLCommandQueue) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        return (device, try #require(device.makeCommandQueue()))
    }

    private func waitFor(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(predicate(), "GPU completion did not reach the main actor")
    }

    private func execute(_ command: any MTLCommandBuffer) async throws {
        await withCheckedContinuation { continuation in
            command.addCompletedHandler { _ in continuation.resume() }
            command.commit()
        }
        try #require(command.status == .completed, "GPU error: \(String(describing: command.error))")
    }

    private func clear(_ texture: any MTLTexture, on command: any MTLCommandBuffer,
                       color: MTLClearColor = MTLClearColorMake(1, 0, 0, 1)) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = color
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
        encoder.endEncoding()
    }

    @discardableResult
    private func publish(_ source: GamePresentationSource, owner: UUID,
                         device: any MTLDevice, queue: any MTLCommandQueue, number: UInt64,
                         width: Int = 8, height: Int = 4) async throws -> GamePresentationWriteLease {
        let lease = try #require(source.beginFrame(owner: owner, device: device, width: width, height: height))
        let command = try #require(queue.makeCommandBuffer())
        try clear(lease.texture, on: command)
        lease.complete(commandBuffer: command, frameNumber: number)
        try await execute(command)
        try await waitFor { lease.isFinished }
        return lease
    }

    @Test func defaultsImmutableSelectionExclusivePublisherAndObserverCleanup() {
        let source = GamePresentationSource(viewportID: "existing-pane")
        let owner = UUID(), other = UUID()
        #expect(source.viewportID == "existing-pane")
        #expect(GamePresentationSource().viewportID == nil)
        #expect(!source.isAvailable && source.pixelSize == .zero && source.frameNumber == 0)
        #expect(source.publishedFrameCount == 0)
        #expect(source.acquireFrame() == nil)
        #expect(source.attach(owner: owner))
        #expect(source.attach(owner: owner))
        #expect(!source.attach(owner: other))
        var invalidations = 0
        let token = source.observeFrames { invalidations += 1 }
        source.detach(owner: other)
        source.suspend(owner: other)
        #expect(invalidations == 0)
        source.suspend(owner: owner)
        #expect(invalidations == 1)
        source.removeFrameObserver(token)
        source.detach(owner: owner)
        #expect(invalidations == 1)
        #expect(source.attach(owner: other))
    }

    @Test func poolReservationIsThreeBGRAFramesAndRejectsOverflow() {
        #expect(GamePresentationSource.texturePoolCapacity == 3)
        #expect(GamePresentationSource.reservationBytes(width: 128, height: 64) == 128 * 64 * 4 * 3)
        #expect(GamePresentationSource.reservationBytes(width: 0, height: 1) == nil)
        #expect(GamePresentationSource.reservationBytes(width: 1, height: -1) == nil)
        #expect(GamePresentationSource.reservationBytes(width: Int.max, height: 2) == nil)
        #expect(GamePresentationSource.reservationBytes(width: Int.max / 4, height: 1) == nil)
    }

    @Test func secondHostCannotClaimOrReleaseTheFirstHostsSource() {
        let first = GameHost(), second = GameHost(), source = GamePresentationSource()
        first.configureRendering(nil, monitor: nil, presentation: source)
        second.configureRendering(nil, monitor: nil, presentation: source)
        #expect(first.activePresentationSource === source)
        #expect(second.requestedPresentationSource === source)
        #expect(second.activePresentationSource == nil)
        second.releasePresentationSource()
        #expect(!source.attach(owner: UUID()))
        first.suspendPresentationSource()
        #expect(!source.attach(owner: UUID()))
        first.releasePresentationSource()
        second.activatePresentationSource()
        #expect(second.activePresentationSource === source)
        #expect(first.activePresentationSource == nil)
        second.releasePresentationSource()
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Metal device unavailable"))
    func rejectedPublisherCannotWriteInvalidateOrDetachTheAttachedSource() async throws {
        let (device, queue) = try metal()
        let source = GamePresentationSource(), owner = UUID(), rejected = UUID()
        #expect(source.beginFrame(owner: owner, device: device, width: 8, height: 4) == nil)
        #expect(source.attach(owner: owner))
        #expect(!source.attach(owner: rejected))
        #expect(source.beginFrame(owner: rejected, device: device, width: 8, height: 4) == nil)
        try await publish(source, owner: owner, device: device, queue: queue, number: 9)
        source.suspend(owner: rejected)
        source.detach(owner: rejected)
        #expect(source.isAvailable && source.frameNumber == 9)
        let read = try #require(source.acquireFrame())
        #expect(read.width == 8 && read.height == 4)
        read.release()
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Metal device unavailable"))
    func onlyCompletedCommandsPublishAndCallbacksCanUnsubscribe() async throws {
        let (device, queue) = try metal()
        let source = GamePresentationSource(), owner = UUID()
        #expect(source.attach(owner: owner))
        let lease = try #require(source.beginFrame(owner: owner, device: device, width: 8, height: 4))
        #expect(lease.texture.storageMode == .private)
        #expect(lease.texture.pixelFormat == .bgra8Unorm)
        #expect(lease.texture.usage.contains([.renderTarget, .shaderRead]))
        let command = try #require(queue.makeCommandBuffer())
        try clear(lease.texture, on: command)
        var notifications = 0
        var token: UUID?
        token = source.observeFrames {
            notifications += 1
            if let token { source.removeFrameObserver(token) }
        }
        lease.complete(commandBuffer: command, frameNumber: 42)
        #expect(!source.isAvailable && source.acquireFrame() == nil && notifications == 0)
        lease.cancel() // A submitted writer remains protected until GPU completion.
        #expect(!lease.isFinished)
        try await execute(command)
        try await waitFor { lease.isFinished }
        #expect(source.isAvailable && source.frameNumber == 42)
        #expect(source.publishedFrameCount == 1)
        #expect(source.pixelSize == CGSize(width: 8, height: 4))
        #expect(notifications == 1)
        source.suspend(owner: owner)
        #expect(notifications == 1)
        #expect(source.publishedFrameCount == 1)
        source.detach(owner: owner)
        #expect(source.publishedFrameCount == 0)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Metal device unavailable"))
    func lateCompletionAfterDetachCannotResurrectEvenForTheSameOwner() async throws {
        let (device, queue) = try metal()
        let source = GamePresentationSource(), owner = UUID()
        #expect(source.attach(owner: owner))
        let old = try #require(source.beginFrame(owner: owner, device: device, width: 8, height: 4))
        let command = try #require(queue.makeCommandBuffer())
        try clear(old.texture, on: command)
        old.complete(commandBuffer: command, frameNumber: 700)
        source.detach(owner: owner)
        #expect(source.attach(owner: owner))
        try await publish(source, owner: owner, device: device, queue: queue, number: 1)
        try await execute(command)
        try await waitFor { old.isFinished }
        #expect(source.isAvailable && source.frameNumber == 1)
        #expect(source.publishedFrameCount == 1)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Metal device unavailable"))
    func publicationValidatorRetiresPendingFramesAndAllowsResumeWithTheSameClaim() async throws {
        let (device, queue) = try metal()
        let source = GamePresentationSource(), owner = UUID()
        #expect(source.attach(owner: owner))
        var visible = true
        var validations = 0
        source.setPublicationValidator(owner: owner) {
            validations += 1
            return visible
        }
        source.setPublicationValidator(owner: UUID()) { false }
        try await publish(source, owner: owner, device: device, queue: queue, number: 1)
        #expect(source.isAvailable && validations == 1)
        var pending: [(GamePresentationWriteLease, any MTLCommandBuffer)] = []
        for number in UInt64(2)...3 {
            let lease = try #require(source.beginFrame(owner: owner, device: device, width: 8, height: 4))
            let command = try #require(queue.makeCommandBuffer())
            try clear(lease.texture, on: command)
            lease.complete(commandBuffer: command, frameNumber: number)
            pending.append((lease, command))
        }
        visible = false
        source.detach(owner: UUID()) // A rejected detach must not remove validation.
        try await execute(pending[0].1)
        try await waitFor { pending[0].0.isFinished }
        #expect(!source.isAvailable && source.pixelSize == .zero && source.frameNumber == 0)
        #expect(source.publishedFrameCount == 1 && validations == 2)
        #expect(!source.attach(owner: UUID()))
        visible = true
        try await execute(pending[1].1)
        try await waitFor { pending[1].0.isFinished }
        #expect(!source.isAvailable && validations == 2) // The old generation stays retired.
        try await publish(source, owner: owner, device: device, queue: queue, number: 4)
        #expect(source.isAvailable && source.frameNumber == 4 && source.publishedFrameCount == 2)
        #expect(validations == 3)
        source.setPublicationValidator(owner: owner) { false }
        source.detach(owner: owner)
        #expect(source.attach(owner: owner))
        try await publish(source, owner: owner, device: device, queue: queue, number: 5)
        #expect(source.isAvailable && source.frameNumber == 5 && source.publishedFrameCount == 1)
        source.detach(owner: owner)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Metal device unavailable"))
    func validatorCannotReviveAGenerationItSynchronouslySuspended() async throws {
        let (device, queue) = try metal()
        let source = GamePresentationSource(), owner = UUID()
        #expect(source.attach(owner: owner))
        source.setPublicationValidator(owner: owner) { [weak source] in
            source?.suspend(owner: owner)
            return true
        }
        try await publish(source, owner: owner, device: device, queue: queue, number: 1)
        #expect(!source.isAvailable && source.publishedFrameCount == 0)
        source.setPublicationValidator(owner: owner) { true }
        try await publish(source, owner: owner, device: device, queue: queue, number: 2)
        #expect(source.isAvailable && source.frameNumber == 2 && source.publishedFrameCount == 1)
        source.detach(owner: owner)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Metal device unavailable"))
    func suspendClearsLiveFrameAndRejectsPendingCompletionThenAllowsResume() async throws {
        let (device, queue) = try metal()
        let source = GamePresentationSource(), owner = UUID()
        #expect(source.attach(owner: owner))
        try await publish(source, owner: owner, device: device, queue: queue, number: 1)
        let reader = try #require(source.acquireFrame())
        let pending = try #require(source.beginFrame(owner: owner, device: device, width: 8, height: 4))
        let command = try #require(queue.makeCommandBuffer())
        try clear(pending.texture, on: command)
        pending.complete(commandBuffer: command, frameNumber: 2)
        var notifications = 0
        let token = source.observeFrames { notifications += 1 }
        source.suspend(owner: owner)
        #expect(notifications == 1)
        #expect(!source.isAvailable && source.pixelSize == .zero && source.frameNumber == 0)
        #expect(source.acquireFrame() == nil)
        #expect(reader.width == 8) // Existing consumer leases remain valid.
        try await execute(command)
        try await waitFor { pending.isFinished }
        #expect(!source.isAvailable && notifications == 1)
        #expect(source.publishedFrameCount == 1)
        reader.release()
        try await publish(source, owner: owner, device: device, queue: queue, number: 3)
        // Resumption invalidates the allocation configuration, then publishes.
        #expect(source.isAvailable && source.frameNumber == 3 && notifications == 3)
        #expect(source.publishedFrameCount == 2)
        source.removeFrameObserver(token)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Metal device unavailable"))
    func olderCompletionCannotReplaceANewerCompletedFrame() async throws {
        let (device, queue) = try metal()
        let source = GamePresentationSource(), owner = UUID()
        #expect(source.attach(owner: owner))
        let older = try #require(source.beginFrame(owner: owner, device: device, width: 8, height: 4))
        let command = try #require(queue.makeCommandBuffer())
        try clear(older.texture, on: command)
        older.complete(commandBuffer: command, frameNumber: 10)
        try await publish(source, owner: owner, device: device, queue: queue, number: 11)
        try await execute(command)
        try await waitFor { older.isFinished }
        #expect(source.frameNumber == 11)
        #expect(source.publishedFrameCount == 1)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Metal device unavailable"))
    func poolDropsWhenWritersAreBusyAndCancelledSlotsAreReusable() throws {
        let (device, _) = try metal()
        let source = GamePresentationSource(), owner = UUID()
        #expect(source.attach(owner: owner))
        let writes = try (0..<3).map { _ in
            try #require(source.beginFrame(owner: owner, device: device, width: 8, height: 4))
        }
        #expect(Set(writes.map { ObjectIdentifier($0.texture) }).count == 3)
        #expect(source.beginFrame(owner: owner, device: device, width: 8, height: 4) == nil)
        writes[1].cancel()
        writes[1].cancel()
        let reused = try #require(source.beginFrame(owner: owner, device: device, width: 8, height: 4))
        #expect(ObjectIdentifier(reused.texture) == ObjectIdentifier(writes[1].texture))
        for write in writes { write.cancel() }
        reused.cancel()
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Metal device unavailable"))
    func readersBlockReuseUntilEveryConsumerHasReleased() async throws {
        let (device, queue) = try metal()
        let source = GamePresentationSource(), owner = UUID()
        #expect(source.attach(owner: owner))
        var readers: [GamePresentationReadLease] = []
        for number in UInt64(1)...3 {
            try await publish(source, owner: owner, device: device, queue: queue, number: number)
            readers.append(try #require(source.acquireFrame()))
        }
        #expect(source.beginFrame(owner: owner, device: device, width: 8, height: 4) == nil)
        readers[0].release()
        readers[0].release()
        let reused = try #require(source.beginFrame(owner: owner, device: device, width: 8, height: 4))
        #expect(ObjectIdentifier(reused.texture) == ObjectIdentifier(readers[0].texture))
        reused.cancel()
        let secondReader = try #require(source.acquireFrame())
        readers[1].release()
        readers[2].release()
        // The current publication cannot be used as a writer even without readers.
        let a = try #require(source.beginFrame(owner: owner, device: device, width: 8, height: 4))
        let b = try #require(source.beginFrame(owner: owner, device: device, width: 8, height: 4))
        #expect(ObjectIdentifier(a.texture) != ObjectIdentifier(secondReader.texture))
        #expect(ObjectIdentifier(b.texture) != ObjectIdentifier(secondReader.texture))
        source.suspend(owner: owner)
        #expect(source.beginFrame(owner: owner, device: device, width: 8, height: 4) == nil)
        secondReader.release()
        let c = try #require(source.beginFrame(owner: owner, device: device, width: 8, height: 4))
        #expect(ObjectIdentifier(c.texture) == ObjectIdentifier(secondReader.texture))
        a.cancel(); b.cancel(); c.cancel()
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Metal device unavailable"))
    func consumerCommandKeepsItsSlotBusyUntilGPUCompletion() async throws {
        let (device, queue) = try metal()
        let source = GamePresentationSource(), owner = UUID()
        #expect(source.attach(owner: owner))
        try await publish(source, owner: owner, device: device, queue: queue, number: 1)
        let first = try #require(source.acquireFrame())
        try await publish(source, owner: owner, device: device, queue: queue, number: 2)
        let second = try #require(source.acquireFrame())
        try await publish(source, owner: owner, device: device, queue: queue, number: 3)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 8, height: 4, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = .renderTarget
        let output = try #require(device.makeTexture(descriptor: descriptor))
        let command = try #require(queue.makeCommandBuffer())
        let blitter = try GamePresentationBlitter(device: device)
        #expect(blitter.encode(frame: first, into: output, commandBuffer: command))
        command.addCompletedHandler { [first] _ in Task { @MainActor in first.release() } }
        #expect(source.beginFrame(owner: owner, device: device, width: 8, height: 4) == nil)
        try await execute(command)
        var recycled: GamePresentationWriteLease?
        try await waitFor {
            recycled = source.beginFrame(owner: owner, device: device, width: 8, height: 4)
            return recycled != nil
        }
        let returned = try #require(recycled)
        #expect(ObjectIdentifier(returned.texture) == ObjectIdentifier(first.texture))
        recycled?.cancel()
        second.release()
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Metal device unavailable"))
    func resizeUsesTheSameThreeSlotsAndRetiresOldPendingPublications() async throws {
        let (device, queue) = try metal()
        let source = GamePresentationSource(), owner = UUID()
        #expect(source.attach(owner: owner))
        var readers: [GamePresentationReadLease] = []
        for number in UInt64(1)...2 {
            try await publish(source, owner: owner, device: device, queue: queue, number: number)
            readers.append(try #require(source.acquireFrame()))
        }
        let pending = try #require(source.beginFrame(owner: owner, device: device, width: 8, height: 4))
        let command = try #require(queue.makeCommandBuffer())
        try clear(pending.texture, on: command)
        pending.complete(commandBuffer: command, frameNumber: 3)
        #expect(source.beginFrame(owner: owner, device: device, width: 16, height: 12) == nil)
        #expect(!source.isAvailable && source.pixelSize == .zero)
        readers[0].release()
        try await publish(source, owner: owner, device: device, queue: queue, number: 4, width: 16, height: 12)
        #expect(readers[1].width == 8 && readers[1].height == 4)
        try await execute(command)
        try await waitFor { pending.isFinished }
        #expect(source.frameNumber == 4 && source.pixelSize == CGSize(width: 16, height: 12))
        #expect(source.publishedFrameCount == 3)
        readers[1].release()
        #expect(source.beginFrame(owner: owner, device: device, width: 0, height: 12) == nil)
        #expect(source.frameNumber == 4)
    }

#if os(macOS)
    @Test(.enabled(if: MTLCopyAllDevices().count > 1, "A second Metal device is required"))
    func changingDevicesRetiresOldWritesAndKeepsOldReadersValid() async throws {
        let (device, queue) = try metal()
        let other = try #require(MTLCopyAllDevices().first { ObjectIdentifier($0) != ObjectIdentifier(device) })
        let otherQueue = try #require(other.makeCommandQueue())
        let source = GamePresentationSource(), owner = UUID()
        #expect(source.attach(owner: owner))
        try await publish(source, owner: owner, device: device, queue: queue, number: 1)
        let oldReader = try #require(source.acquireFrame())
        let oldWriter = try #require(source.beginFrame(owner: owner, device: device, width: 8, height: 4))
        let oldCommand = try #require(queue.makeCommandBuffer())
        try clear(oldWriter.texture, on: oldCommand)
        oldWriter.complete(commandBuffer: oldCommand, frameNumber: 2)
        try await publish(source, owner: owner, device: other, queue: otherQueue, number: 3)
        try await execute(oldCommand)
        try await waitFor { oldWriter.isFinished }
        #expect(source.frameNumber == 3 && source.publishedFrameCount == 2)
        let currentReader = try #require(source.acquireFrame())
        #expect(ObjectIdentifier(currentReader.texture.device) == ObjectIdentifier(other))
        #expect(ObjectIdentifier(oldReader.texture.device) == ObjectIdentifier(device))
        oldReader.release()
        currentReader.release()
    }
#endif

    @Test func aspectFitLetterboxesPortraitLandscapeAndRejectsInvalidSizes() {
        #expect(gamePresentationAspectFit(image: CGSize(width: 200, height: 100), canvas: CGSize(width: 100, height: 100))
            == CGRect(x: 0, y: 25, width: 100, height: 50))
        #expect(gamePresentationAspectFit(image: CGSize(width: 100, height: 200), canvas: CGSize(width: 100, height: 100))
            == CGRect(x: 25, y: 0, width: 50, height: 100))
        #expect(gamePresentationAspectFit(image: CGSize(width: 3, height: 2), canvas: CGSize(width: 6, height: 4))
            == CGRect(x: 0, y: 0, width: 6, height: 4))
        for bad in [CGSize.zero, CGSize(width: -1, height: 1), CGSize(width: CGFloat.infinity, height: 1),
                    CGSize(width: 1, height: CGFloat.nan)] {
            #expect(gamePresentationAspectFit(image: bad, canvas: CGSize(width: 10, height: 10)) == .zero)
            #expect(gamePresentationAspectFit(image: CGSize(width: 10, height: 10), canvas: bad) == .zero)
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Metal device unavailable"))
    func mirrorSamplesCompletedPixelsWithoutFlippingAndClearsBlackAfterInvalidation() async throws {
        let (device, queue) = try metal()
        let source = GamePresentationSource(), owner = UUID()
        #expect(source.attach(owner: owner))
        let lease = try #require(source.beginFrame(owner: owner, device: device, width: 4, height: 2))
        let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 4, height: 2, mipmapped: false)
        inputDescriptor.storageMode = .shared
        let input = try #require(device.makeTexture(descriptor: inputDescriptor))
        let pixels: [UInt8] = [
            0, 0, 255, 255, 0, 0, 255, 255, 0, 255, 0, 255, 0, 255, 0, 255,
            255, 0, 0, 255, 255, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 255
        ]
        pixels.withUnsafeBytes { bytes in
            input.replace(region: MTLRegionMake2D(0, 0, 4, 2), mipmapLevel: 0,
                          withBytes: bytes.baseAddress!, bytesPerRow: 16)
        }
        let producer = try #require(queue.makeCommandBuffer())
        let copy = try #require(producer.makeBlitCommandEncoder())
        copy.copy(from: input, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: 4, height: 2, depth: 1), to: lease.texture,
                  destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        copy.endEncoding()
        lease.complete(commandBuffer: producer, frameNumber: 1)
        try await execute(producer)
        try await waitFor { lease.isFinished }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 8, height: 8, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        let output = try #require(device.makeTexture(descriptor: descriptor))
        let blitter = try GamePresentationBlitter(device: device)
        let read = try #require(source.acquireFrame())
        let consumer = try #require(queue.makeCommandBuffer())
        #expect(blitter.encode(frame: read, into: output, commandBuffer: consumer))
        consumer.addCompletedHandler { [read] _ in Task { @MainActor in read.release() } }
        try await execute(consumer)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            output.getBytes(&bytes, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            return bytes
        }
        #expect(pixel(1, 0) == [0, 0, 0, 255])
        #expect(pixel(1, 2) == [0, 0, 255, 255])
        #expect(pixel(6, 2) == [0, 255, 0, 255])
        #expect(pixel(1, 5) == [255, 0, 0, 255])
        #expect(pixel(6, 5) == [255, 255, 255, 255])
        #expect(pixel(1, 7) == [0, 0, 0, 255])
        source.suspend(owner: owner)
        let black = try #require(queue.makeCommandBuffer())
        #expect(blitter.encode(frame: source.acquireFrame(), into: output, commandBuffer: black))
        try await execute(black)
        #expect(pixel(1, 2) == [0, 0, 0, 255])
        #expect(pixel(6, 5) == [0, 0, 0, 255])
    }
}
