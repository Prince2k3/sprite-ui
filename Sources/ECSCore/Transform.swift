import Foundation

/// Position, rotation and scale of an entity relative to its parent.
///
/// Every entity has a `Transform`. The world origin is the center of the view,
/// +x is right and +y is up.
public struct Transform: Component, Equatable, Sendable, Codable {
    public var translation: SIMD2<Float>
    /// Counter-clockwise rotation in radians.
    public var rotation: Float
    public var scale: SIMD2<Float>
    /// Draw order. Higher values draw on top of lower ones.
    public var zPosition: Float

    public init(
        translation: SIMD2<Float> = .zero,
        rotation: Float = 0,
        scale: SIMD2<Float> = .one,
        zPosition: Float = 0
    ) {
        self.translation = translation
        self.rotation = rotation
        self.scale = scale
        self.zPosition = zPosition
    }

    public static let identity = Transform()
}

extension Transform {
    /// Maps a point from this transform's child space into its parent's space.
    public func apply(to point: SIMD2<Float>) -> SIMD2<Float> {
        let scaled = point * scale
        let c = cos(rotation), s = sin(rotation)
        return translation + SIMD2(c * scaled.x - s * scaled.y, s * scaled.x + c * scaled.y)
    }
}

extension Entity {
    /// The entity's position in scene space: the same space as top-level entities'
    /// positions, after every ancestor's translation, rotation and scale.
    public var scenePosition: SIMD2<Float> {
        sceneTransformMatrix.apply(to: .zero)
    }
}
