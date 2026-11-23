import CoreImage
import ECSCore
import Foundation
import SpriteKit
import Synchronization

/// A filter applied to a group's composited image, in array order. Radii use
/// offscreen-image pixels. Filters are visual only: their blurred/glowing edges
/// do not expand collision or hit-test shapes.
public enum PostProcessEffect: Hashable, Codable, Sendable {
    /// Gaussian blur. Radius is clamped to 0...128; nonfinite values use zero.
    case blur(radius: Float)
    /// Glow around bright pixels. Radius is clamped to 0...128, intensity to 0...2.
    case bloom(radius: Float, intensity: Float = 1)
    /// Saturation 0...2, brightness -1...1, contrast 0...4. Nonfinite values use defaults.
    case colorAdjustment(saturation: Float = 1, brightness: Float = 0, contrast: Float = 1)

    private func limited(_ value: Float, _ range: ClosedRange<Float>, fallback: Float = 0) -> Float {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }

    var filter: CIFilter {
        switch self {
        case .blur(let radius):
            CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: limited(radius, 0...128)])!
        case .bloom(let radius, let intensity):
            CIFilter(name: "CIBloom", parameters: [kCIInputRadiusKey: limited(radius, 0...128), kCIInputIntensityKey: limited(intensity, 0...2)])!
        case .colorAdjustment(let saturation, let brightness, let contrast):
            CIFilter(name: "CIColorControls", parameters: [kCIInputSaturationKey: limited(saturation, 0...2, fallback: 1),
                kCIInputBrightnessKey: limited(brightness, -1...1), kCIInputContrastKey: limited(contrast, 0...4, fallback: 1)])!
        }
    }

    var padding: CGFloat {
        switch self {
        case .blur(let radius), .bloom(let radius, _): CGFloat(limited(radius, 0...128)) * 3
        case .colorAdjustment: 0
        }
    }

    init?(filter: CIFilter) {
        func number(_ key: String, fallback: Float) -> Float { (filter.value(forKey: key) as? NSNumber)?.floatValue ?? fallback }
        switch filter.name {
        case "CIGaussianBlur": self = .blur(radius: number(kCIInputRadiusKey, fallback: 10))
        case "CIBloom": self = .bloom(radius: number(kCIInputRadiusKey, fallback: 10), intensity: number(kCIInputIntensityKey, fallback: 1))
        case "CIColorControls": self = .colorAdjustment(saturation: number(kCIInputSaturationKey, fallback: 1),
            brightness: number(kCIInputBrightnessKey, fallback: 0), contrast: number(kCIInputContrastKey, fallback: 1))
        default: return nil
        }
    }
}

/// Composites an entity's sprites and descendants as one visual layer. Nested
/// groups filter from the inside out. Child z positions sort within their group;
/// the group's own z position orders the resulting image against its siblings.
///
/// Transforms, physics and hit shapes remain in their original coordinate spaces.
/// Keep cameras outside filtered gameplay groups. SwiftUI overlays and attachments
/// are hosted separately and stay sharp. Attachments inherit ancestor opacity and
/// visibility, but not filters or blend modes. Keep a group's lights and lit sprites
/// together inside the same compositing boundary.
///
/// No framebuffer caching is used, so animated content and edited filters stay live.
/// Opacity/blending are applied to the flattened image. A disabled component bypasses
/// all group settings; entity activation still controls simulation and input.
///
/// ```swift
/// let scenery = Entity(components: RenderGroupComponent(effects: [.bloom(radius: 12)]))
/// scenery.addChild(portal)
/// scenery.components[RenderGroupComponent.self]?.effects = [.blur(radius: 8), .colorAdjustment(saturation: 0.4)]
/// ```
public struct RenderGroupComponent: Component, Hashable, Codable, Sendable {
    public var effects: [PostProcessEffect]
    /// Opacity of the composited image, clamped to 0...1. Animates with withAnimation.
    /// Nonfinite values render as zero. Does not disable hit testing or physics.
    public var opacity: Float
    public var blendMode: SpriteBlendMode
    public var isEnabled: Bool

    public init(effects: [PostProcessEffect] = [], opacity: Float = 1,
                blendMode: SpriteBlendMode = .alpha, isEnabled: Bool = true) {
        self.effects = effects; self.opacity = opacity; self.blendMode = blendMode; self.isEnabled = isEnabled
    }
}

/// A single-input filter chain. Configuration is immutable after attachment.
/// Input is supplied by SpriteKit; each evaluation owns its temporary filters.
final class RenderGroupFilter: CIFilter, @unchecked Sendable {
    let effects: [PostProcessEffect]
    private let input = Mutex<CIImage?>(nil)
    @objc dynamic var inputImage: CIImage? {
        get { input.withLock { $0 } }
        set { input.withLock { $0 = newValue } }
    }
    init(effects: [PostProcessEffect]) { self.effects = effects; super.init() }
    required init?(coder: NSCoder) {
        guard let data = coder.decodeObject(of: NSData.self, forKey: "effects") as Data?,
              let effects = try? JSONDecoder().decode([PostProcessEffect].self, from: data) else { return nil }
        self.effects = effects; super.init()
    }
    override func encode(with coder: NSCoder) { coder.encode(try? JSONEncoder().encode(effects), forKey: "effects") }
    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = RenderGroupFilter(effects: effects); copy.inputImage = inputImage; return copy
    }
    override var inputKeys: [String] { [kCIInputImageKey] }
    override var attributes: [String: Any] {
        [kCIAttributeFilterDisplayName: "SpriteUI post-processing", kCIInputImageKey: [kCIAttributeClass: "CIImage"]]
    }
    override func setDefaults() { inputImage = nil }
    override var outputImage: CIImage? {
        guard var image = inputImage, !image.extent.isInfinite, !image.extent.isNull else { return nil }
        var bounds = image.extent
        for effect in effects {
            let filter = effect.filter
            filter.setValue(image, forKey: kCIInputImageKey)
            guard let output = filter.outputImage else { return nil }
            bounds = bounds.insetBy(dx: -effect.padding, dy: -effect.padding)
            image = output.cropped(to: bounds)
        }
        return image
    }
}

extension SpriteRenderer {
    static let groupOpacityKey = "renderGroup.opacity"
    static let renderGroupBinding = Binding<RenderGroupComponent>(
        apply: { new, old, node, animator in
            guard let node = node as? SKEffectNode else { return }
            guard let value = new else {
                animator.cancel(groupOpacityKey, on: node)
                node.shouldEnableEffects = false; node.filter = nil; node.alpha = 1; node.blendMode = .alpha
                animator.renderer.needsLightingRefresh = true
                return
            }
            if old?.isEnabled != value.isEnabled { animator.renderer.needsLightingRefresh = true }
            node.shouldEnableEffects = value.isEnabled
            node.shouldRasterize = false; node.shouldCenterFilter = false
            node.blendMode = value.isEnabled ? value.blendMode.native : .alpha
            if old?.effects != value.effects || old?.isEnabled != value.isEnabled {
                node.filter = value.isEnabled && !value.effects.isEmpty ? RenderGroupFilter(effects: value.effects) : nil
            }
            let opacity = value.isEnabled ? (value.opacity.isFinite ? min(max(value.opacity, 0), 1) : 0) : 1
            if old?.opacity != value.opacity || old?.isEnabled != value.isEnabled {
                let start = node.alpha
                let animator = old == nil || !value.isEnabled
                    ? Animator(renderer: animator.renderer, entityID: animator.entityID, transaction: nil) : animator
                animator.update(groupOpacityKey, on: node,
                    to: { .fadeAlpha(to: CGFloat(opacity), duration: $0) },
                    from: { .fadeAlpha(to: start, duration: $0) }, set: { node.alpha = CGFloat(opacity) })
            }
        },
        present: { node, model in
            var value = model
            if value.isEnabled { value.opacity = Float(node.alpha) }
            return value
        })
}
