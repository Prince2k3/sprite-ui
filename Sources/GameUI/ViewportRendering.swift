@_spi(Backend) import SpriteBackend
import MetalKit
import SpriteKit
import QuartzCore
import Synchronization

/// One SpriteKit update, followed by independent offscreen camera draws. Keeping
/// each pane in its own target also contains SpriteKit background/filter passes.
/// Internal so GPU tests exercise the exact encoder used by the native host.
@MainActor
final class ViewportFrameRenderer {
    enum Failure: Error {
        case unavailableCommandQueue, unavailableCommandBuffer, unavailableTexture
        case unavailableEncoder, unavailableShader
        case incompletePaneRender
        case resourceBudgetExceeded
    }

    let scene: SpriteRenderer
    let device: any MTLDevice
    let commandQueue: any MTLCommandQueue
    private let spriteKit: SKRenderer
    private let compositor: any MTLRenderPipelineState
    private var textures: [String: any MTLTexture] = [:]
    private struct Pane {
        let id: String
        let texture: any MTLTexture
        let x: Int, y: Int, width: Int, height: Int
    }
    private struct CompletedFrame {
        let panes: [Pane]
        let width: Int, height: Int
        let background: MTLClearColor
        let commandBuffer: any MTLCommandBuffer
    }
    private var completedFrame: CompletedFrame?
    private var isEncodingFrame = false
    private var isAdvancingScene = false
    var hasCaptureFrame: Bool { completedFrame != nil && !isEncodingFrame && !isAdvancingScene }
    private var lastDisplayTime: TimeInterval?
    private var nativeTime: TimeInterval = 1
    private var hasNativeUpdate = false
    private var suspendPhysicsOnNextUpdate = false
    private(set) var frameNumber: UInt64 = 0
    private(set) var droppedPresentationFrames: UInt64 = 0
    private(set) var lastPlan: GameRenderPlan?

    init(scene: SpriteRenderer, device: any MTLDevice) throws {
        self.scene = scene
        self.device = device
        if let time = scene.presentationClockTime, time.isFinite {
            nativeTime = time
            hasNativeUpdate = true
        }
        guard let queue = device.makeCommandQueue() else { throw Failure.unavailableCommandQueue }
        commandQueue = queue
        spriteKit = SKRenderer(device: device)
        spriteKit.scene = scene
        spriteKit.ignoresSiblingOrder = true

        let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        struct PaneVertex { float4 position [[position]]; float2 uv; };
        vertex PaneVertex viewportVertex(uint id [[vertex_id]]) {
            float2 corner = float2((id << 1) & 2, id & 2);
            PaneVertex result;
            result.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
            result.uv = float2(corner.x, 1.0 - corner.y);
            return result;
        }
        fragment float4 viewportFragment(PaneVertex in [[stage_in]],
                                          texture2d<float> image [[texture(0)]]) {
            constexpr sampler sample(coord::normalized, address::clamp_to_edge, filter::nearest);
            return image.sample(sample, in.uv);
        }
        """, options: nil)
        guard let vertex = library.makeFunction(name: "viewportVertex"),
              let fragment = library.makeFunction(name: "viewportFragment") else { throw Failure.unavailableShader }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "SpriteUI viewport compositor"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        compositor = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    func setShowsStatistics(_ enabled: Bool) {
        spriteKit.showsNodeCount = enabled
        spriteKit.showsDrawCount = enabled
    }

    /// Pause the display clock without resetting SpriteKit's action/physics
    /// timeline. The first resumed update uses the last native timestamp.
    func resetClock() {
        lastDisplayTime = nil
        if hasNativeUpdate { suspendPhysicsOnNextUpdate = true }
        scene.resetFrameClock()
    }

    /// Updates once and finishes the independent pane draws, then encodes their
    /// composition into the supplied buffer. The caller presents once.
    func encodeFrame(atTime time: TimeInterval, logicalSize: CGSize,
                     into output: any MTLTexture, commandBuffer: any MTLCommandBuffer,
                     plan suppliedPlan: GameRenderPlan? = nil, updatesScene: Bool = true,
                     presentation: GamePresentationSource? = nil, presentationOwner: UUID? = nil) throws {
        guard !isEncodingFrame, !isAdvancingScene else { throw LevelLoadingError.presentationUnavailable }
        isEncodingFrame = true
        // A partial draw may overwrite textures belonging to the previous frame.
        completedFrame = nil
        defer { isEncodingFrame = false }
        guard logicalSize.width.isFinite, logicalSize.height.isFinite,
              logicalSize.width > 0, logicalSize.height > 0 else { return }
        precondition(output.pixelFormat == .bgra8Unorm && output.sampleCount == 1)
        if updatesScene { advanceScene(atTime: time, logicalSize: logicalSize) }

        let viewports = scene.resolvedViewports
        let rects = viewports.map { scene.viewportRect(id: $0.id) ?? .zero }
        let plan = suppliedPlan ?? GameRenderPlan(logicalSize: logicalSize,
            existingDrawableSize: CGSize(width: output.width, height: output.height), viewportRects: rects)
        guard plan.isValid, plan.drawableSize == CGSize(width: output.width, height: output.height),
              plan.panePixelRects.count == viewports.count else { throw Failure.resourceBudgetExceeded }
        lastPlan = plan

        var panes: [Pane] = []
        var retainedTextures: [String: any MTLTexture] = [:]
        for (index, viewport) in viewports.enumerated() {
            let pixels = plan.panePixelRects[index]
            let left = Int(pixels.minX), top = Int(pixels.minY)
            let right = Int(pixels.maxX), bottom = Int(pixels.maxY)
            let width = right - left, height = bottom - top
            guard width > 0, height > 0 else { continue }
            let texture: any MTLTexture
            if let existing = textures[viewport.id], existing.width == width, existing.height == height {
                texture = existing
            } else {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
                descriptor.storageMode = .private
                descriptor.usage = [.renderTarget, .shaderRead]
                guard let created = device.makeTexture(descriptor: descriptor) else { throw Failure.unavailableTexture }
                created.label = "SpriteUI viewport \(viewport.id)"
                texture = created
            }
            retainedTextures[viewport.id] = texture
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = backgroundColor
            guard let paneCommand = commandQueue.makeCommandBuffer() else { throw Failure.unavailableCommandBuffer }
            let rendered: Void? = scene.renderViewport(viewport.id) {
                spriteKit.render(withViewport: CGRect(x: 0, y: 0, width: width, height: height),
                                 commandBuffer: paneCommand, renderPassDescriptor: pass)
                paneCommand.commit()
                // SpriteKit reuses camera-dependent GPU storage between renders.
                // Encoding all cameras before execution made every target show
                // the last camera. Finish this draw before restoring the scope.
                paneCommand.waitUntilCompleted()
            }
            guard paneCommand.status == .completed else { throw Failure.incompletePaneRender }
            if rendered != nil { panes.append(Pane(id: viewport.id, texture: texture, x: left, y: top, width: width, height: height)) }
        }
        textures = retainedTextures

        let background = backgroundColor
        try composite(panes, background: background, into: output, commandBuffer: commandBuffer)
        completedFrame = CompletedFrame(panes: panes, width: output.width, height: output.height,
                                        background: background, commandBuffer: commandBuffer)
        frameNumber &+= 1
        if let presentation, let presentationOwner {
            try exportPresentation(presentation, owner: presentationOwner, panes: panes,
                                   width: output.width, height: output.height, background: background,
                                   commandBuffer: commandBuffer)
        }
    }

    /// The primary host alone calls this once, before acquiring a drawable sized
    /// for the updated scene. Exporting and consuming frames never calls it.
    func advanceScene(atTime time: TimeInterval, logicalSize: CGSize) {
        guard !isAdvancingScene else { return }
        isAdvancingScene = true
        defer { isAdvancingScene = false }
        guard logicalSize.width.isFinite, logicalSize.height.isFinite,
              logicalSize.width > 0, logicalSize.height > 0 else { return }
        let oldScaleMode = scene.scaleMode
        scene.scaleMode = .fill
        defer { scene.scaleMode = oldScaleMode; scene.size = logicalSize }
        scene.size = logicalSize
        if time.isFinite {
            if let previous = lastDisplayTime {
                let interval = time - previous
                if interval.isFinite { nativeTime += min(max(interval, 0), 1.0 / 15.0) }
            }
            lastDisplayTime = time
        }
        let suspendPhysics = suspendPhysicsOnNextUpdate
        suspendPhysicsOnNextUpdate = false
        hasNativeUpdate = true
        if suspendPhysics {
            scene.withViewportPhysicsSuspended { spriteKit.update(atTime: nativeTime) }
        } else { spriteKit.update(atTime: nativeTime) }
    }

    private func exportPresentation(_ source: GamePresentationSource, owner: UUID, panes: [Pane],
                                    width: Int, height: Int, background: MTLClearColor,
                                    commandBuffer: any MTLCommandBuffer) throws {
        let imagePanes: [Pane], imageWidth: Int, imageHeight: Int
        if let id = source.viewportID {
            guard let pane = panes.first(where: { $0.id == id }) else {
                source.suspend(owner: owner)
                return
            }
            imageWidth = pane.width; imageHeight = pane.height
            imagePanes = [Pane(id: pane.id, texture: pane.texture, x: 0, y: 0,
                               width: pane.width, height: pane.height)]
        } else { imagePanes = panes; imageWidth = width; imageHeight = height }
        guard let lease = source.beginFrame(owner: owner, device: device, width: imageWidth, height: imageHeight) else {
            droppedPresentationFrames &+= 1
            return
        }
        do {
            try composite(imagePanes, background: background, into: lease.texture, commandBuffer: commandBuffer)
            lease.complete(commandBuffer: commandBuffer, frameNumber: frameNumber)
        } catch { lease.cancel(); throw error }
    }

    /// Recompose exactly the last frame's pixels, geometry and ordering. This
    /// deliberately never reads the current cameras or invokes SpriteKit.
    func capturePresentation() throws -> SpriteImage {
        guard !isEncodingFrame, !isAdvancingScene, let frame = completedFrame,
              frame.commandBuffer.status == .committed || frame.commandBuffer.status == .scheduled ||
                frame.commandBuffer.status == .completed else { throw LevelLoadingError.presentationUnavailable }
        frame.commandBuffer.waitUntilCompleted()
        guard frame.commandBuffer.status == .completed else { throw LevelLoadingError.presentationUnavailable }
        let output = try LevelPresentationPixels.makeTexture(device: device, width: frame.width, height: frame.height)
        guard let command = commandQueue.makeCommandBuffer() else { throw Failure.unavailableCommandBuffer }
        try composite(frame.panes, background: frame.background, into: output, commandBuffer: command)
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw Failure.incompletePaneRender }
        return LevelPresentationPixels.image(from: output)
    }

    private func composite(_ panes: [Pane], background: MTLClearColor,
                           into output: any MTLTexture, commandBuffer: any MTLCommandBuffer) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = background
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.unavailableEncoder }
        encoder.label = "SpriteUI composite viewports"
        encoder.setRenderPipelineState(compositor)
        for pane in panes {
            encoder.setViewport(MTLViewport(originX: Double(pane.x), originY: Double(pane.y),
                                            width: Double(pane.width), height: Double(pane.height), znear: 0, zfar: 1))
            encoder.setScissorRect(MTLScissorRect(x: pane.x, y: pane.y, width: pane.width, height: pane.height))
            encoder.setFragmentTexture(pane.texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
    }

    private var backgroundColor: MTLClearColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
#if os(macOS)
        scene.backgroundColor.usingColorSpace(.deviceRGB)?.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
#else
        scene.backgroundColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
#endif
        return MTLClearColorMake(Double(red * alpha), Double(green * alpha), Double(blue * alpha), Double(alpha))
    }
}

/// Owns only native presentation. The input wrapper never presents a scene in
/// this mode, and SpriteRenderer remains the world's sole backend observer.
@MainActor
final class ViewportRendering: NSObject {
    private weak var host: GameHost?
    private weak var container: SKView?
    private let metalView: MTKView
    private let frames: ViewportFrameRenderer
    private var isRunning = false
    private var isSurfaceVisible = true
    private var activityGeneration: UInt64 = 0
    private var lastBoundsSize: CGSize = .zero
    private nonisolated let drawPending = Mutex(false)

    init?(host: GameHost, container: SKView) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.host = host
        self.container = container
        do { frames = try ViewportFrameRenderer(scene: host.renderer, device: device) }
        catch { preconditionFailure("Could not create viewport renderer: \(error)") }
        metalView = MTKView(frame: container.bounds, device: device)
        super.init()
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.depthStencilPixelFormat = .invalid
        metalView.sampleCount = 1
        metalView.framebufferOnly = true
        metalView.autoResizeDrawable = false
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
#if os(macOS)
        metalView.autoresizingMask = [.width, .height]
#else
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        metalView.isUserInteractionEnabled = false
#endif
        container.addSubview(metalView)
        metalView.delegate = self
        synchronizeGeometry()
    }

    func setActive(_ active: Bool) {
        guard active != isRunning else { return }
        isRunning = active
        activityGeneration &+= 1
        frames.resetClock()
        metalView.isPaused = !active
    }

    var hasCaptureFrame: Bool { isRunning && frames.hasCaptureFrame }

    func capturePresentation() throws -> SpriteImage {
        guard isRunning else { throw LevelLoadingError.presentationUnavailable }
        return try frames.capturePresentation()
    }

    func setShowsStatistics(_ enabled: Bool) { frames.setShowsStatistics(enabled) }

    /// Keep the native callback alive while an attached ancestor is hidden so
    /// showing it again can resume without requiring a SwiftUI remount.
    func synchronizeVisibility() {
        let visible = (container as? GameSKView)?.isNativeSurfaceVisible == true
        guard visible != isSurfaceVisible else { return }
        isSurfaceVisible = visible
        activityGeneration &+= 1
        frames.resetClock()
        if !visible { host?.suspendPresentationSource() }
    }

    func synchronizeGeometry() {
        guard let container else { return }
        metalView.frame = container.bounds
        metalView.preferredFramesPerSecond = resolvedConfiguration.preferredFramesPerSecond
        let size = container.bounds.size
        guard size != lastBoundsSize else { return }
        lastBoundsSize = size
        host?.cancelInputs(preservingHinge: true)
        frames.scene.size = size
    }

    func stop() {
        setActive(false)
        metalView.delegate = nil
        metalView.removeFromSuperview()
    }

    private func drawFrame() {
        guard isRunning, let host else { return }
        synchronizeVisibility()
        guard isSurfaceVisible else { return }
        (container as? GameSKView)?.synchronizeSurfaceGeometry()
        synchronizeGeometry()
        guard let container, container.window != nil,
              container.bounds.width > 0, container.bounds.height > 0 else { return }
        let logicalSize = container.bounds.size
        // A world update may change cameras or pane layout. Plan the targets only
        // after that single update, without asking a mirror to update the scene.
        frames.advanceScene(atTime: CACurrentMediaTime(), logicalSize: logicalSize)
        synchronizeVisibility()
        guard isRunning, isSurfaceVisible, host.isPresentationActive, container.window != nil,
              container.bounds.size == logicalSize else { return }
        let configuration = resolvedConfiguration
        metalView.preferredFramesPerSecond = configuration.preferredFramesPerSecond
        let viewports = frames.scene.resolvedViewports
        let rects = viewports.map { frames.scene.viewportRect(id: $0.id) ?? .zero }
        var source = host.activePresentationSource
        let selection = source?.viewportID.flatMap { id in viewports.firstIndex { $0.id == id } }
        if source?.viewportID != nil && selection == nil {
            source?.suspend(owner: host.presentationOwner)
            source = nil
        }
        let plan = GameRenderPlan(logicalSize: logicalSize,
            displayScale: host.surfaceState.geometry.displayScale, viewportRects: rects,
            configuration: configuration, presentationViewportIndex: selection,
            presentationCopies: source == nil ? 0 : GamePresentationSource.texturePoolCapacity)
        guard plan.isValid else {
            source?.suspend(owner: host.presentationOwner)
            return
        }
        if metalView.drawableSize != plan.drawableSize { metalView.drawableSize = plan.drawableSize }
        guard let drawable = metalView.currentDrawable,
              let commandBuffer = frames.commandQueue.makeCommandBuffer() else { return }
        let revision = host.renderingRevision
        let activity = activityGeneration
        do {
            try frames.encodeFrame(atTime: CACurrentMediaTime(), logicalSize: logicalSize,
                into: drawable.texture, commandBuffer: commandBuffer, plan: plan, updatesScene: false,
                presentation: source, presentationOwner: host.presentationOwner)
        } catch {
            // A failed target allocation must not retry the simulation or crash
            // the game. Retire pending exports and leave a cleared primary frame.
            source?.suspend(owner: host.presentationOwner)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }
        let frameNumber = frames.frameNumber
        let drops = frames.droppedPresentationFrames
        let paneCount = plan.panePixelRects.filter { !$0.isEmpty }.count
        if let monitor = host.renderMonitor, monitor.isEnabled {
            commandBuffer.addCompletedHandler { [weak self, weak monitor, weak source] completed in
                guard completed.status == .completed else { return }
                Task { @MainActor [weak self, weak monitor, weak source] in
                    guard let self, self.isRunning, let host = self.host,
                          self.activityGeneration == activity,
                          (self.container as? GameSKView)?.isNativeSurfaceVisible == true,
                          host.renderingRevision == revision, host.renderMonitor === monitor,
                          let monitor else { return }
                    monitor.record(GameRenderStatistics(logicalSize: logicalSize, drawableSize: plan.drawableSize,
                        renderedViewportCount: paneCount, renderPixels: plan.totalRenderPixels,
                        effectiveResolutionScale: plan.effectiveResolutionScale,
                        preferredFramesPerSecond: configuration.preferredFramesPerSecond,
                        frameNumber: frameNumber, presentationFrameCount: source?.publishedFrameCount ?? 0,
                        droppedPresentationFrames: drops))
                }
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private var resolvedConfiguration: GameRenderConfiguration {
        (host?.renderConfiguration ?? .init()).resolved(in: .current)
    }
}

extension ViewportRendering: MTKViewDelegate {
    // MTKView can request drawing off the main actor. Acquire its drawable and
    // touch the shared scene only after hopping to the main actor. Pending draws
    // become no-ops after suspension/teardown.
    nonisolated func draw(in view: MTKView) {
        let requested = drawPending.withLock { pending in
            guard !pending else { return false }
            pending = true
            return true
        }
        guard requested else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.drawPending.withLock { $0 = false } }
            self.drawFrame()
        }
    }
    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        Task { @MainActor [weak self] in self?.synchronizeGeometry() }
    }
}
