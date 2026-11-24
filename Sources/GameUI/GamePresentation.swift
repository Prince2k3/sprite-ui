import MetalKit
import Observation
import SwiftUI
import Synchronization

/// Completed GPU pixels from one game host, shared with read-only displays.
/// A nil viewport ID selects the full composite; an ID selects an existing pane.
/// This object never owns a world, advances simulation, or creates a camera.
@MainActor @Observable
public final class GamePresentationSource {
    public let viewportID: String?
    public private(set) var isAvailable = false
    public private(set) var pixelSize: CGSize = .zero
    public private(set) var frameNumber: UInt64 = 0

    /// Successful publications in the current publisher claim, independent of frame-number gaps.
    @ObservationIgnored private(set) var publishedFrameCount: UInt64 = 0

    /// The producer's render plan must reserve this many BGRA8 frame buffers.
    static let texturePoolCapacity = 3

    @ObservationIgnored private var owner: UUID?
    @ObservationIgnored private var publicationValidator: (@MainActor () -> Bool)?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var configuration: Configuration?
    @ObservationIgnored private var slots = (0..<GamePresentationSource.texturePoolCapacity).map { _ in GamePresentationSlot() }
    @ObservationIgnored private var published: GamePresentationSlot?
    @ObservationIgnored private var nextSequence: UInt64 = 0
    @ObservationIgnored private var publishedSequence: UInt64 = 0
    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]

    private struct Configuration: Equatable {
        let device: ObjectIdentifier
        let width: Int
        let height: Int
    }

    public init(viewportID: String? = nil) { self.viewportID = viewportID }

    /// Idempotent for the current publisher; another publisher cannot take over.
    @discardableResult
    func attach(owner: UUID) -> Bool {
        guard self.owner == nil || self.owner == owner else { return false }
        if self.owner == nil { publishedFrameCount = 0 }
        self.owner = owner
        return true
    }

    func detach(owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        publicationValidator = nil
        publishedFrameCount = 0
        configuration = nil
        invalidate()
    }

    /// Installs a claim-scoped completion-time check; absent validation permits publication.
    func setPublicationValidator(owner: UUID, _ validator: @escaping @MainActor () -> Bool) {
        guard self.owner == owner else { return }
        publicationValidator = validator
    }

    /// Retains publisher ownership while retiring pending publications and idle allocations.
    func suspend(owner: UUID) {
        guard self.owner == owner else { return }
        configuration = nil
        invalidate()
    }

    /// Allocation is lazy, but the planner reserves the complete three-slot pool.
    static func reservationBytes(width: Int, height: Int) -> Int? {
        guard width > 0, height > 0 else { return nil }
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4 * texturePoolCapacity)
        return pixelOverflow || byteOverflow ? nil : bytes
    }

    /// Returns nil under backpressure. Never steals a published, writing, or read slot.
    func beginFrame(owner: UUID, device: any MTLDevice, width: Int, height: Int) -> GamePresentationWriteLease? {
        guard self.owner == owner, Self.reservationBytes(width: width, height: height) != nil else { return nil }
        let requested = Configuration(device: ObjectIdentifier(device), width: width, height: height)
        let requestedGeneration: UUID
        if configuration != requested {
            configuration = requested
            requestedGeneration = invalidate()
        } else { requestedGeneration = generation }
        // An invalidation observer may synchronously detach or reconfigure us.
        guard self.owner == owner, configuration == requested, generation == requestedGeneration,
              let slot = slots.first(where: { $0 !== published && $0.writeID == nil && $0.readers.isEmpty }) else { return nil }
        if let texture = slot.texture,
           ObjectIdentifier(texture.device) == requested.device,
           texture.width == width, texture.height == height {
            // Reuse only after every consumer GPU command has relinquished it.
        } else {
            slot.texture = nil
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead]
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            texture.label = "SpriteUI presentation frame"
            slot.texture = texture
        }
        guard let texture = slot.texture else { return nil }
        let writeID = UUID()
        slot.writeID = writeID
        nextSequence &+= 1
        return GamePresentationWriteLease(source: self, slot: slot, texture: texture,
            owner: owner, generation: generation, writeID: writeID, sequence: nextSequence)
    }

    func acquireFrame() -> GamePresentationReadLease? {
        guard isAvailable, let slot = published, let texture = slot.texture else { return nil }
        return GamePresentationReadLease(source: self, slot: slot, texture: texture)
    }

    /// Native views subscribe directly, without reading observable frame state in body.
    func observeFrames(_ callback: @escaping @MainActor () -> Void) -> UUID {
        let token = UUID()
        observers[token] = callback
        return token
    }

    func removeFrameObserver(_ token: UUID) { observers.removeValue(forKey: token) }

    fileprivate func releaseRead(slot: GamePresentationSlot, readerID: UUID) {
        slot.readers.remove(readerID)
        discardRetiredTexture(in: slot)
    }

    fileprivate func cancelWrite(slot: GamePresentationSlot, writeID: UUID) {
        guard slot.writeID == writeID else { return }
        slot.writeID = nil
        discardRetiredTexture(in: slot)
    }

    fileprivate func finishWrite(slot: GamePresentationSlot, writeID: UUID, owner: UUID,
                                 generation: UUID, sequence: UInt64, frameNumber: UInt64, succeeded: Bool) {
        guard slot.writeID == writeID else { return }
        guard succeeded, self.owner == owner, self.generation == generation,
              sequence > publishedSequence else {
            cancelWrite(slot: slot, writeID: writeID)
            return
        }
        let mayPublish = publicationValidator?() ?? true
        // Validation can synchronously suspend, detach, or replace this claim.
        guard slot.writeID == writeID, self.owner == owner, self.generation == generation,
              sequence > publishedSequence else {
            cancelWrite(slot: slot, writeID: writeID)
            return
        }
        guard mayPublish else {
            cancelWrite(slot: slot, writeID: writeID)
            suspend(owner: owner)
            return
        }
        slot.writeID = nil
        guard let texture = slot.texture else {
            discardRetiredTexture(in: slot)
            return
        }
        let previous = published
        published = slot
        publishedSequence = sequence
        pixelSize = CGSize(width: texture.width, height: texture.height)
        self.frameNumber = frameNumber
        publishedFrameCount &+= 1
        isAvailable = true
        if let previous { discardRetiredTexture(in: previous) }
        notify()
    }

    @discardableResult
    private func invalidate() -> UUID {
        generation = UUID()
        let invalidatedGeneration = generation
        nextSequence = 0
        publishedSequence = 0
        published = nil
        isAvailable = false
        pixelSize = .zero
        frameNumber = 0
        for slot in slots { discardRetiredTexture(in: slot) }
        notify()
        return invalidatedGeneration
    }

    private func discardRetiredTexture(in slot: GamePresentationSlot) {
        guard slot !== published, slot.writeID == nil, slot.readers.isEmpty else { return }
        guard let configuration, let texture = slot.texture,
              ObjectIdentifier(texture.device) == configuration.device,
              texture.width == configuration.width, texture.height == configuration.height else {
            slot.texture = nil
            return
        }
    }

    private func notify() {
        // Snapshot tokens so an observer can remove itself during delivery.
        for token in Array(observers.keys) { observers[token]?() }
    }
}

@MainActor
fileprivate final class GamePresentationSlot {
    var texture: (any MTLTexture)?
    var writeID: UUID?
    var readers: Set<UUID> = []
}

/// Producer ownership ends only after its command buffer has finished on the GPU.
@MainActor
final class GamePresentationWriteLease {
    let texture: any MTLTexture
    private weak var source: GamePresentationSource?
    private let slot: GamePresentationSlot
    private let owner: UUID
    private let generation: UUID
    private let writeID: UUID
    private let sequence: UInt64
    private var submitted = false
    private(set) var isFinished = false

    fileprivate init(source: GamePresentationSource, slot: GamePresentationSlot, texture: any MTLTexture,
                     owner: UUID, generation: UUID, writeID: UUID, sequence: UInt64) {
        self.source = source
        self.slot = slot
        self.texture = texture
        self.owner = owner
        self.generation = generation
        self.writeID = writeID
        self.sequence = sequence
    }

    /// Call after encoding and BEFORE commit. This method never commits or waits.
    func complete(commandBuffer: any MTLCommandBuffer, frameNumber: UInt64) {
        guard !submitted, !isFinished else { return }
        guard ObjectIdentifier(commandBuffer.device) == ObjectIdentifier(texture.device),
              commandBuffer.status == .notEnqueued || commandBuffer.status == .enqueued else {
            cancel()
            return
        }
        submitted = true
        commandBuffer.addCompletedHandler { [self] completed in
            let succeeded = completed.status == .completed
            Task { @MainActor [self] in
                source?.finishWrite(slot: slot, writeID: writeID, owner: owner, generation: generation,
                    sequence: sequence, frameNumber: frameNumber, succeeded: succeeded)
                isFinished = true
            }
        }
    }

    /// Only for abandoned, unsubmitted encoding. Submitted GPU work cannot be cancelled here.
    func cancel() {
        guard !submitted, !isFinished else { return }
        isFinished = true
        source?.cancelWrite(slot: slot, writeID: writeID)
    }

    deinit {
        let source = self.source, slot = self.slot, writeID = self.writeID
        Task { @MainActor in source?.cancelWrite(slot: slot, writeID: writeID) }
    }
}

/// Keep alive until the consumer command buffer completes; release on the main actor.
@MainActor
final class GamePresentationReadLease {
    let texture: any MTLTexture
    var width: Int { texture.width }
    var height: Int { texture.height }
    private weak var source: GamePresentationSource?
    private let slot: GamePresentationSlot
    private let readerID = UUID()

    fileprivate init(source: GamePresentationSource, slot: GamePresentationSlot, texture: any MTLTexture) {
        self.source = source
        self.slot = slot
        self.texture = texture
        slot.readers.insert(readerID)
    }

    func release() {
        if let source { source.releaseRead(slot: slot, readerID: readerID) }
        else { _ = slot.readers.remove(readerID) }
    }

    deinit {
        let source = self.source, slot = self.slot, readerID = self.readerID
        Task { @MainActor in
            if let source { source.releaseRead(slot: slot, readerID: readerID) }
            else { _ = slot.readers.remove(readerID) }
        }
    }
}

/// A passive, aspect-fit GPU display. It has no input or simulation clock.
@MainActor
public struct GamePresentationView: View {
    private let source: GamePresentationSource

    public init(source: GamePresentationSource) { self.source = source }

    public var body: some View {
        GamePresentationNativeView(source: source)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Pixel-space bounds, shared by the native renderer and geometry tests.
func gamePresentationAspectFit(image: CGSize, canvas: CGSize) -> CGRect {
    guard image.width.isFinite, image.height.isFinite, canvas.width.isFinite, canvas.height.isFinite,
          image.width > 0, image.height > 0, canvas.width > 0, canvas.height > 0 else { return .zero }
    let scale = min(canvas.width / image.width, canvas.height / image.height)
    let width = image.width * scale, height = image.height * scale
    guard width.isFinite, height.isFinite, width > 0, height > 0 else { return .zero }
    return CGRect(x: (canvas.width - width) / 2, y: (canvas.height - height) / 2, width: width, height: height)
}

/// Shares the exact mirror sampling path with offscreen pixel tests.
@MainActor
final class GamePresentationBlitter {
    private let pipeline: any MTLRenderPipelineState

    init(device: any MTLDevice) throws {
        let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        struct PresentationVertex { float4 position [[position]]; float2 uv; };
        vertex PresentationVertex presentationVertex(uint id [[vertex_id]]) {
            float2 p = float2((id << 1) & 2, id & 2);
            return { float4(p * 2.0 - 1.0, 0.0, 1.0), float2(p.x, 1.0 - p.y) };
        }
        fragment float4 presentationFragment(PresentationVertex in [[stage_in]],
                                             texture2d<float> image [[texture(0)]]) {
            constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);
            return image.sample(s, in.uv);
        }
        """, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "SpriteUI read-only presentation"
        descriptor.vertexFunction = library.makeFunction(name: "presentationVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "presentationFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// The caller owns the read lease until command completion, including errors.
    @discardableResult
    func encode(frame: GamePresentationReadLease?, into output: any MTLTexture,
                commandBuffer: any MTLCommandBuffer) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        if let frame {
            let rect = gamePresentationAspectFit(image: CGSize(width: frame.width, height: frame.height),
                canvas: CGSize(width: output.width, height: output.height))
            if !rect.isEmpty {
                encoder.setRenderPipelineState(pipeline)
                encoder.setViewport(MTLViewport(originX: Double(rect.minX), originY: Double(rect.minY),
                    width: Double(rect.width), height: Double(rect.height), znear: 0, zfar: 1))
                encoder.setFragmentTexture(frame.texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        }
        encoder.endEncoding()
        return true
    }
}

@MainActor
private final class GamePresentationCoordinator: NSObject, MTKViewDelegate {
    private weak var view: MTKView?
    private var source: GamePresentationSource?
    private var observer: UUID?
    private var blitter: GamePresentationBlitter?
    private var queue: (any MTLCommandQueue)?
    private nonisolated let drawPending = Mutex(false)

    func connect(source: GamePresentationSource, view: MTKView) {
        self.view = view
        guard self.source !== source else { return }
        disconnect()
        self.source = source
        observer = source.observeFrames { [weak self] in self?.invalidate() }
        invalidate()
    }

    func disconnect() {
        if let observer { source?.removeFrameObserver(observer) }
        observer = nil
        source = nil
    }

    private func invalidate() {
        guard let view else { return }
#if os(macOS)
        view.needsDisplay = true
#else
        view.setNeedsDisplay()
#endif
    }

    private func drawFrame() {
        guard let view, let source else { return }
        let frame = source.acquireFrame()
        guard let device = frame?.texture.device ?? view.device ?? MTLCreateSystemDefaultDevice() else { return }
        if view.device.map({ ObjectIdentifier($0) }) != ObjectIdentifier(device) || blitter == nil {
            view.device = device
            queue = device.makeCommandQueue()
            blitter = try? GamePresentationBlitter(device: device)
        }
        guard let blitter, let command = queue?.makeCommandBuffer(), let drawable = view.currentDrawable,
              blitter.encode(frame: frame, into: drawable.texture, commandBuffer: command) else {
            frame?.release()
            return
        }
        if let frame {
            command.addCompletedHandler { [frame] _ in
                Task { @MainActor in frame.release() }
            }
        }
        command.present(drawable)
        command.commit()
    }

    nonisolated func draw(in view: MTKView) {
        let shouldDraw = drawPending.withLock { pending in
            guard !pending else { return false }
            pending = true
            return true
        }
        guard shouldDraw else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.drawPending.withLock { $0 = false } }
            self.drawFrame()
        }
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        Task { @MainActor [weak self] in self?.invalidate() }
    }

    deinit {
        let source = self.source, observer = self.observer
        Task { @MainActor in if let observer { source?.removeFrameObserver(observer) } }
    }
}

@MainActor
private func makeGamePresentationView(coordinator: GamePresentationCoordinator, source: GamePresentationSource) -> MTKView {
    let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
    view.colorPixelFormat = .bgra8Unorm
    view.depthStencilPixelFormat = .invalid
    view.clearColor = MTLClearColorMake(0, 0, 0, 1)
    view.sampleCount = 1
    view.framebufferOnly = true
    view.autoResizeDrawable = true
    view.isPaused = true
    view.enableSetNeedsDisplay = true
#if !os(macOS)
    view.isUserInteractionEnabled = false
#endif
    view.delegate = coordinator
    coordinator.connect(source: source, view: view)
    return view
}

#if os(macOS)
private struct GamePresentationNativeView: NSViewRepresentable {
    let source: GamePresentationSource
    func makeCoordinator() -> GamePresentationCoordinator { GamePresentationCoordinator() }
    func makeNSView(context: Context) -> MTKView { makeGamePresentationView(coordinator: context.coordinator, source: source) }
    func updateNSView(_ view: MTKView, context: Context) { context.coordinator.connect(source: source, view: view) }
    static func dismantleNSView(_ view: MTKView, coordinator: GamePresentationCoordinator) {
        coordinator.disconnect()
        view.delegate = nil
    }
}
#else
private struct GamePresentationNativeView: UIViewRepresentable {
    let source: GamePresentationSource
    func makeCoordinator() -> GamePresentationCoordinator { GamePresentationCoordinator() }
    func makeUIView(context: Context) -> MTKView { makeGamePresentationView(coordinator: context.coordinator, source: source) }
    func updateUIView(_ view: MTKView, context: Context) { context.coordinator.connect(source: source, view: view) }
    static func dismantleUIView(_ view: MTKView, coordinator: GamePresentationCoordinator) {
        coordinator.disconnect()
        view.delegate = nil
    }
}
#endif
