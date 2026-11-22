import ECSCore
import SwiftUI

/// Draws an image or a solid color rectangle at the entity's transform.
public struct SpriteComponent: Component, Equatable {
    /// Name of an image in the asset catalog. With no `imageName` or `image`, draws a
    /// solid `color` rectangle.
    public var imageName: String?
    /// Pixels made in code, such as a colored ``NoiseMap``. Wins over `imageName`.
    public var image: SpriteImage?
    /// Fill color, or the tint color when an image is set.
    public var color: Color
    /// How much `color` tints the image, from 0 (none) to 1 (full).
    public var colorBlendFactor: Float
    /// Size in points. `nil` uses the image's own size.
    public var size: SIMD2<Float>?
    /// The point in the sprite placed at the entity's position. (0.5, 0.5) is the center.
    public var anchorPoint: SIMD2<Float>
    public var opacity: Float

    public init(
        imageName: String,
        size: SIMD2<Float>? = nil,
        tint: Color = .white,
        tintAmount: Float = 0,
        anchorPoint: SIMD2<Float> = [0.5, 0.5],
        opacity: Float = 1
    ) {
        self.imageName = imageName
        self.image = nil
        self.color = tint
        self.colorBlendFactor = tintAmount
        self.size = size
        self.anchorPoint = anchorPoint
        self.opacity = opacity
    }

    public init(
        image: SpriteImage,
        size: SIMD2<Float>? = nil,
        tint: Color = .white,
        tintAmount: Float = 0,
        anchorPoint: SIMD2<Float> = [0.5, 0.5],
        opacity: Float = 1
    ) {
        self.imageName = nil
        self.image = image
        self.color = tint
        self.colorBlendFactor = tintAmount
        self.size = size
        self.anchorPoint = anchorPoint
        self.opacity = opacity
    }

    public init(
        color: Color,
        size: SIMD2<Float>,
        anchorPoint: SIMD2<Float> = [0.5, 0.5],
        opacity: Float = 1
    ) {
        self.imageName = nil
        self.image = nil
        self.color = color
        self.colorBlendFactor = 1
        self.size = size
        self.anchorPoint = anchorPoint
        self.opacity = opacity
    }
}

/// An image made in code: 8-bit RGBA pixels, top row first.
public struct SpriteImage: Hashable, Sendable {
    public let width: Int
    public let height: Int
    /// `width * height * 4` bytes of straight (not premultiplied) RGBA.
    public let pixels: [UInt8]
    /// Whether to blend between pixels when scaled up. `false` keeps hard pixel edges.
    public var smoothsScaling: Bool

    public init(width: Int, height: Int, pixels: [UInt8], smoothsScaling: Bool = true) {
        precondition(width > 0 && height > 0 && pixels.count == width * height * 4,
                     "SpriteImage needs width * height * 4 bytes")
        self.width = width
        self.height = height
        self.pixels = pixels
        self.smoothsScaling = smoothsScaling
    }
}
