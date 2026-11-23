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
    }

    let scene: SpriteRenderer
    let device: any MTLDevice
    let commandQueue: any MTLCommandQueue
    private let spriteKit: SKRenderer
    private let compositor: any MTLRenderPipelineState
    private var textures: [String: any MTLTexture] = [:]
    private var lastDisplayTime: TimeInterval?
    private var nativeTime: TimeInterval = 1
    private var hasNativeUpdate = false
    private var suspendPhysicsOnNextUpdate = false

    init(scene: SpriteRenderer, device: any MTLDevice) throws {
        self.scene = scene
        self.device = device
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
                     into output: any MTLTexture, commandBuffer: any MTLCommandBuffer) throws {
        guard logicalSize.width.isFinite, logicalSize.height.isFinite,
              logicalSize.width > 0, logicalSize.height > 0 else { return }
        precondition(output.pixelFormat == .bgra8Unorm && output.sampleCount == 1)
        // resizeFill asks SpriteKit to obtain dimensions from its presenting
        // SKView. There is deliberately no presenting SKView in this path, so
        // update would otherwise replace the logical canvas with CGSize.zero.
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
            // SpriteKit can perform a minimum physics step at an unchanged
            // timestamp. Resume still delivers its zero-delta ECS/action frame,
            // while the backend holds bodies and contacts for this update only.
            scene.withViewportPhysicsSuspended { spriteKit.update(atTime: nativeTime) }
        } else {
            spriteKit.update(atTime: nativeTime)
        }

        struct Pane {
            let texture: any MTLTexture
            let x: Int, y: Int, width: Int, height: Int
        }
        var panes: [Pane] = []
        var retainedTextures: [String: any MTLTexture] = [:]
        let scaleX = CGFloat(output.width) / logicalSize.width
        let scaleY = CGFloat(output.height) / logicalSize.height
        for viewport in scene.resolvedViewports {
            guard let rect = scene.viewportRect(id: viewport.id) else { continue }
            // Round shared edges identically, including at fractional display scales.
            let left = max(0, min(output.width, Int((rect.minX * scaleX).rounded())))
            let top = max(0, min(output.height, Int((rect.minY * scaleY).rounded())))
            let right = max(left, min(output.width, Int((rect.maxX * scaleX).rounded())))
            let bottom = max(top, min(output.height, Int((rect.maxY * scaleY).rounded())))
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
            if rendered != nil { panes.append(Pane(texture: texture, x: left, y: top, width: width, height: height)) }
        }
        textures = retainedTextures

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = backgroundColor
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
        metalView.autoResizeDrawable = true
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
        frames.resetClock()
        metalView.isPaused = !active
    }

    func setShowsStatistics(_ enabled: Bool) { frames.setShowsStatistics(enabled) }

    func synchronizeGeometry() {
        guard let container else { return }
        metalView.frame = container.bounds
        let size = container.bounds.size
        guard size != lastBoundsSize else { return }
        lastBoundsSize = size
        host?.cancelInputs()
        frames.scene.size = size
    }

    func stop() {
        setActive(false)
        metalView.delegate = nil
        metalView.removeFromSuperview()
    }

    private func drawFrame() {
        guard isRunning else { return }
        synchronizeGeometry()
        guard let container, container.window != nil,
              container.bounds.width > 0, container.bounds.height > 0,
              let drawable = metalView.currentDrawable else { return }
        guard let commandBuffer = frames.commandQueue.makeCommandBuffer() else {
            preconditionFailure("Could not create viewport command buffer.")
        }
        do {
            try frames.encodeFrame(atTime: CACurrentMediaTime(), logicalSize: container.bounds.size,
                                   into: drawable.texture, commandBuffer: commandBuffer)
        } catch { preconditionFailure("Could not render viewports: \(error)") }
        commandBuffer.present(drawable)
        commandBuffer.commit()
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
