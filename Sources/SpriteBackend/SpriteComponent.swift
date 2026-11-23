import ECSCore
import SwiftUI

/// Draws an image or a solid color rectangle at the entity's transform.
public struct SpriteComponent: Component, Equatable {
    /// Name of an image in the asset catalog. With no `imageName` or `image`, draws a
    /// solid `color` rectangle.
    public var imageName: String?
    /// A shared resource; takes precedence over image and imageName.
    public var texture: TextureResource? = nil
    /// Pixels made in code, such as a colored ``NoiseMap``. Wins over `imageName`.
    public var image: SpriteImage?
    /// Tint, opacity, blending, and optional custom shading, owned by this sprite.
    public var material: SpriteMaterial = SpriteMaterial()
    /// Fill color, or the tint color when an image is set. Forwards to `material.tint`.
    public var color: Color {
        get { material.tint }
        set { material.tint = newValue }
    }
    /// How much `color` tints the image, from 0 (none) to 1 (full).
    public var colorBlendFactor: Float {
        get { material.tintAmount }
        set { material.tintAmount = newValue }
    }
    /// Size in points. `nil` uses the image's own size.
    public var size: SIMD2<Float>?
    /// The point in the sprite placed at the entity's position. (0.5, 0.5) is the center.
    public var anchorPoint: SIMD2<Float>
    public var opacity: Float {
        get { material.opacity }
        set { material.opacity = newValue }
    }

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
        self.material = SpriteMaterial(tint: tint, tintAmount: tintAmount, opacity: opacity)
        self.size = size
        self.anchorPoint = anchorPoint
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
        self.material = SpriteMaterial(tint: tint, tintAmount: tintAmount, opacity: opacity)
        self.size = size
        self.anchorPoint = anchorPoint
    }

    public init(
        texture: TextureResource,
        size: SIMD2<Float>? = nil,
        tint: Color = .white,
        tintAmount: Float = 0,
        anchorPoint: SIMD2<Float> = [0.5, 0.5],
        opacity: Float = 1
    ) {
        self.init(image: texture.image, size: size, tint: tint, tintAmount: tintAmount, anchorPoint: anchorPoint, opacity: opacity)
        self.image = nil
        self.texture = texture
    }

    public init(
        color: Color,
        size: SIMD2<Float>,
        anchorPoint: SIMD2<Float> = [0.5, 0.5],
        opacity: Float = 1
    ) {
        self.imageName = nil
        self.image = nil
        self.material = SpriteMaterial(tint: color, tintAmount: 1, opacity: opacity)
        self.size = size
        self.anchorPoint = anchorPoint
    }

    public init(texture: TextureResource, material: SpriteMaterial, size: SIMD2<Float>? = nil,
                anchorPoint: SIMD2<Float> = [0.5, 0.5]) {
        self.init(texture: texture, size: size, anchorPoint: anchorPoint)
        self.material = material
    }

    public init(image: SpriteImage, material: SpriteMaterial, size: SIMD2<Float>? = nil,
                anchorPoint: SIMD2<Float> = [0.5, 0.5]) {
        self.init(image: image, size: size, anchorPoint: anchorPoint)
        self.material = material
    }

    public init(imageName: String, material: SpriteMaterial, size: SIMD2<Float>? = nil,
                anchorPoint: SIMD2<Float> = [0.5, 0.5]) {
        self.init(imageName: imageName, size: size, anchorPoint: anchorPoint)
        self.material = material
    }

    /// A solid rectangle; tintAmount is irrelevant when no texture is present.
    public init(material: SpriteMaterial, size: SIMD2<Float>, anchorPoint: SIMD2<Float> = [0.5, 0.5]) {
        self.init(color: material.tint, size: size, anchorPoint: anchorPoint)
        self.material = material
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
