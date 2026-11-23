@_spi(Backend) import ECSCore
@_spi(Backend) import SpriteBackend
import Metal
import SpriteKit
import SwiftUI

/// The coordinator holds this bridge weakly; the stable host owns its lifetime.
@MainActor
final class GameLevelPresentation: LevelPresentation {
    private weak var host: GameHost?
    private let inputOwner = UUID()
    private weak var suppressedInput: InputController?
    private weak var suppressedHub: PlayerInputHub?
    private var synchronizingInput = false
    private var needsInputSynchronization = false
    private var capturing = false
    private(set) var blocksInput = false

    init(host: GameHost) { self.host = host }

    isolated deinit {
        suppressedInput?.setInputSuppressed(false, owner: inputOwner)
        suppressedHub?.setInputSuppressed(false, owner: inputOwner)
    }

    var isLevelPresentationAvailable: Bool {
        !capturing && host?.nativeView?.isLevelPresentationAvailable == true
    }

    func captureLevelPresentation() throws -> SpriteImage {
        guard isLevelPresentationAvailable, let view = host?.nativeView else {
            throw LevelLoadingError.presentationUnavailable
        }
        capturing = true
        defer { capturing = false }
        do { return try view.captureLevelPresentation() }
        catch { throw LevelLoadingError.presentationUnavailable }
    }

    func levelInputDidChange(blocked: Bool) {
        // A coordinator may finish cancellation after its view disappeared.
        let blocked = blocked && host?.isPresentationActive == true
        let changed = blocksInput != blocked
        blocksInput = blocked
        host?.attachmentStore.levelInputBlocked = blocked
        synchronizeInputSuppression()
        if changed && blocked { host?.cancelInputs() }
        host?.nativeInputSession?.refresh()
    }

    /// Also called when gameInput changes its binding during a transition.
    /// Publish lease ownership before cancellation callbacks can reenter binding.
    func synchronizeInputSuppression() {
        needsInputSynchronization = true
        guard !synchronizingInput else { return }
        synchronizingInput = true
        defer { synchronizingInput = false }
        while needsInputSynchronization {
            needsInputSynchronization = false
            let nextInput = blocksInput ? (host?.actionInput ?? host?.nativeInputSession?.router.input) : nil
            let nextHub = blocksInput ? host?.nativeInputSession?.router.hub : nil
            let oldInput = suppressedInput, oldHub = suppressedHub
            suppressedInput = nextInput; suppressedHub = nextHub
            if oldInput !== nextInput {
                nextInput?.setInputSuppressed(true, owner: inputOwner)
                oldInput?.setInputSuppressed(false, owner: inputOwner)
            }
            if oldHub !== nextHub {
                nextHub?.setInputSuppressed(true, owner: inputOwner)
                oldHub?.setInputSuppressed(false, owner: inputOwner)
            }
        }
    }
}

/// Shared readback for the cached compositor and legacy render-only path.
@MainActor
enum LevelPresentationPixels {
    static func makeTexture(device: any MTLDevice, width: Int, height: Int) throws -> any MTLTexture {
        guard width > 0, height > 0 else { throw LevelLoadingError.presentationUnavailable }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw LevelLoadingError.presentationUnavailable }
        return texture
    }

    static func image(from texture: any MTLTexture) -> SpriteImage {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return image(bgra: bytes, width: texture.width, height: texture.height)
    }

    /// Metal texture rows already start at the top. SpriteImage uses straight
    /// RGBA, whereas SpriteKit/compositor targets contain premultiplied BGRA.
    static func image(bgra bytes: [UInt8], width: Int, height: Int) -> SpriteImage {
        var rgba = bytes
        for index in stride(from: 0, to: rgba.count, by: 4) {
            let alpha = Int(bytes[index + 3])
            for channel in 0..<3 {
                let value = Int(bytes[index + 2 - channel])
                rgba[index + channel] = alpha == 0 ? 0 : UInt8(min(255, (value * 255 + alpha / 2) / alpha))
            }
        }
        return SpriteImage(width: width, height: height, pixels: rgba)
    }

    static func captureLegacy(scene: SpriteRenderer, logicalSize: CGSize, scale: CGFloat) throws -> SpriteImage {
        guard !scene.isUpdatingPresentation,
              logicalSize.width.isFinite, logicalSize.height.isFinite, scale.isFinite,
              logicalSize.width > 0, logicalSize.height > 0, scale > 0,
              let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let command = queue.makeCommandBuffer() else { throw LevelLoadingError.presentationUnavailable }
        let width = Int((logicalSize.width * scale).rounded())
        let height = Int((logicalSize.height * scale).rounded())
        let texture = try makeTexture(device: device, width: width, height: height)
        let renderer = SKRenderer(device: device)
        renderer.scene = scene
        renderer.ignoresSiblingOrder = true
        defer { renderer.scene = nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        // SpriteKit's offscreen renderer does not reliably draw an empty
        // scene's background. Match the live driver's premultiplied clear so
        // gaps and translucent surfaces retain their color and alpha.
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
#if os(macOS)
        scene.backgroundColor.usingColorSpace(.deviceRGB)?.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
#else
        scene.backgroundColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
#endif
        pass.colorAttachments[0].clearColor = MTLClearColorMake(
            Double(red * alpha), Double(green * alpha), Double(blue * alpha), Double(alpha))
        // A fresh renderer draws the already presented scene. Never update,
        // flush ECS writes, change cameras, or warm this renderer with a frame.
        renderer.render(withViewport: CGRect(x: 0, y: 0, width: width, height: height),
                        commandBuffer: command, renderPassDescriptor: pass)
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw LevelLoadingError.presentationUnavailable }
        return image(from: texture)
    }

    static func cgImage(_ image: SpriteImage) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(image.pixels) as CFData) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8,
                       bitsPerPixel: 32, bytesPerRow: image.width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: image.smoothsScaling,
                       intent: .defaultIntent)
    }
}

/// Drawn after attachments so both fade styles cover the entire game surface.
struct LevelPresentationOverlay: View {
    let levels: LevelCoordinator
    @State private var outgoing: CGImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let outgoing, levels.outgoingImage != nil {
                    Image(decorative: outgoing, scale: 1, orientation: .up)
                        .resizable()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .opacity(levels.overlayOpacity)
                } else {
                    Color.black.opacity(levels.overlayOpacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .onChange(of: levels.outgoingImage, initial: true) { _, image in
            outgoing = image.flatMap(LevelPresentationPixels.cgImage)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
