import Foundation

/// An exact 2D affine matrix, including shear produced by nested rotations and
/// nonuniform scales. Points map to `(a*x + c*y + tx, b*x + d*y + ty)`.
public struct AffineTransform2D: Hashable, Sendable, Codable {
    public var a: Float
    public var b: Float
    public var c: Float
    public var d: Float
    public var tx: Float
    public var ty: Float

    public init(a: Float = 1, b: Float = 0, c: Float = 0, d: Float = 1, tx: Float = 0, ty: Float = 0) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }

    public static let identity = Self()

    /// Maps a position, including translation.
    public func apply(to point: SIMD2<Float>) -> SIMD2<Float> {
        apply(toDirection: point) + SIMD2(tx, ty)
    }

    /// Maps a direction, without translation. Its length may change with scale.
    public func apply(toDirection direction: SIMD2<Float>) -> SIMD2<Float> {
        [a * direction.x + c * direction.y, b * direction.x + d * direction.y]
    }

    /// The inverse, or `nil` for singular or nonfinite matrices.
    public func inverted() -> Self? {
        let determinant = a * d - b * c
        guard [a, b, c, d, tx, ty, determinant].allSatisfy(\.isFinite), abs(determinant) > Float.leastNormalMagnitude else { return nil }
        let result = Self(a: d / determinant, b: -b / determinant, c: -c / determinant, d: a / determinant,
                          tx: (c * ty - d * tx) / determinant, ty: (b * tx - a * ty) / determinant)
        return [result.a, result.b, result.c, result.d, result.tx, result.ty].allSatisfy(\.isFinite) ? result : nil
    }

    /// Composition: applies `rhs` first, followed by `lhs`.
    public static func * (lhs: Self, rhs: Self) -> Self {
        Self(a: lhs.a * rhs.a + lhs.c * rhs.b, b: lhs.b * rhs.a + lhs.d * rhs.b,
             c: lhs.a * rhs.c + lhs.c * rhs.d, d: lhs.b * rhs.c + lhs.d * rhs.d,
             tx: lhs.a * rhs.tx + lhs.c * rhs.ty + lhs.tx, ty: lhs.b * rhs.tx + lhs.d * rhs.ty + lhs.ty)
    }
}

/// A rejected coordinate conversion or hierarchy change. Mutating operations
/// validate first, so errors leave the entity and its hierarchy unchanged.
public enum EntityTransformError: Error, Equatable, Sendable {
    case hierarchyCycle
    case worldRootCannotBeReparented
    case differentWorlds
    case noninvertibleTransform
    case nonfiniteTransform
    /// A single SpriteKit node cannot represent shear. Use a wrapper hierarchy
    /// or reparent without preserving the world transform instead.
    case requiresShear
}

extension Transform {
    /// The affine matrix of this local transform.
    public var matrix: AffineTransform2D {
        let cosine = cos(rotation), sine = sin(rotation)
        return AffineTransform2D(a: cosine * scale.x, b: sine * scale.x,
                                 c: -sine * scale.y, d: cosine * scale.y,
                                 tx: translation.x, ty: translation.y)
    }

    /// Creates a local transform from a matrix. Throws when a single rotation
    /// and scale cannot represent it accurately (shear), or values are nonfinite.
    public init(matrix: AffineTransform2D, zPosition: Float = 0) throws {
        let values = [matrix.a, matrix.b, matrix.c, matrix.d, matrix.tx, matrix.ty, zPosition]
        guard values.allSatisfy(\.isFinite) else { throw EntityTransformError.nonfiniteTransform }
        let sx = hypot(matrix.a, matrix.b)
        let secondLength = hypot(matrix.c, matrix.d)
        let angle: Float
        let sy: Float
        if sx > 0 {
            angle = atan2(matrix.b, matrix.a)
            sy = (matrix.a * matrix.d - matrix.b * matrix.c) / sx
            let projection = matrix.a * matrix.c + matrix.b * matrix.d
            guard abs(projection) <= 1e-5 * max(sx * secondLength, Float.leastNormalMagnitude) else {
                throw EntityTransformError.requiresShear
            }
        } else {
            // A collapsed x axis still has a valid TRS representation.
            angle = secondLength > 0 ? atan2(-matrix.c, matrix.d) : 0
            sy = secondLength
        }
        self.init(translation: [matrix.tx, matrix.ty], rotation: angle, scale: [sx, sy], zPosition: zPosition)
    }
}

extension Entity {
    /// The world containing this entity, using the scene vocabulary of GameView.
    public var scene: World? { world }
    /// Rotation in radians, relative to the parent.
    public var rotation: Float { get { transform.rotation } set { transform.rotation = newValue } }
    /// Scale relative to the parent.
    public var scale: SIMD2<Float> { get { transform.scale } set { transform.scale = newValue } }
    /// Draw order relative to the parent.
    public var zPosition: Float { get { transform.zPosition } set { transform.zPosition = newValue } }

    /// The exact transform into scene space. Complexity is O(hierarchy depth).
    public var sceneTransformMatrix: AffineTransform2D {
        var result = transform.matrix
        var ancestor = parent
        while let entity = ancestor { result = entity.transform.matrix * result; ancestor = entity.parent }
        return result
    }

    /// This entity's transform into `reference`'s local space; `nil` reference
    /// means scene space. Returns `nil` for a singular reference or different worlds.
    public func transformMatrix(relativeTo reference: Entity?) -> AffineTransform2D? {
        if let reference, let world, let other = reference.world, world !== other { return nil }
        if reference === self { return .identity }
        guard let inverse = (reference?.sceneTransformMatrix ?? .identity).inverted() else { return nil }
        let result = inverse * sceneTransformMatrix
        guard [result.a, result.b, result.c, result.d, result.tx, result.ty].allSatisfy(\.isFinite) else { return nil }
        return result
    }

    /// The entity origin in the reference's space; `nil` reference means scene space.
    public func position(relativeTo reference: Entity?) -> SIMD2<Float>? {
        transformMatrix(relativeTo: reference)?.apply(to: .zero)
    }

    /// Converts a position in this entity's space into the reference's space.
    public func convert(position: SIMD2<Float>, to reference: Entity?) -> SIMD2<Float>? {
        transformMatrix(relativeTo: reference)?.apply(to: position)
    }

    /// Converts a position from the reference's space into this entity's space.
    public func convert(position: SIMD2<Float>, from reference: Entity?) -> SIMD2<Float>? {
        if let reference { return reference.convert(position: position, to: self) }
        return sceneTransformMatrix.inverted()?.apply(to: position)
    }

    /// Converts a direction without applying translation.
    public func convert(direction: SIMD2<Float>, to reference: Entity?) -> SIMD2<Float>? {
        transformMatrix(relativeTo: reference)?.apply(toDirection: direction)
    }

    /// Converts a direction from the reference's space, without translation.
    public func convert(direction: SIMD2<Float>, from reference: Entity?) -> SIMD2<Float>? {
        if let reference { return reference.convert(direction: direction, to: self) }
        return sceneTransformMatrix.inverted()?.apply(toDirection: direction)
    }

    /// Sets the entity origin using the reference's coordinate space. Throws for
    /// nonfinite values, a singular parent, or entities in different worlds.
    public func setPosition(_ position: SIMD2<Float>, relativeTo reference: Entity?) throws {
        guard position.x.isFinite, position.y.isFinite else { throw EntityTransformError.nonfiniteTransform }
        if let reference, let world, let other = reference.world, world !== other { throw EntityTransformError.differentWorlds }
        if reference === parent { self.position = position; return }
        let point = reference?.sceneTransformMatrix.apply(to: position) ?? position
        guard let inverse = (parent?.sceneTransformMatrix ?? .identity).inverted() else { throw EntityTransformError.noninvertibleTransform }
        let local = inverse.apply(to: point)
        guard local.x.isFinite, local.y.isFinite else { throw EntityTransformError.nonfiniteTransform }
        self.position = local
    }

    /// Moves the entity to a new parent, optionally preserving its scene transform
    /// and accumulated draw order. Validates cycles and representability atomically.
    public func setParent(_ newParent: Entity?, preservingWorldTransform: Bool = false) throws {
        guard world?.root !== self else { throw EntityTransformError.worldRootCannotBeReparented }
        guard newParent !== self, newParent?.isDescendant(of: self) != true else { throw EntityTransformError.hierarchyCycle }
        guard parent !== newParent else { return }
        var preserved: Transform?
        if preservingWorldTransform {
            guard let inverse = (newParent?.sceneTransformMatrix ?? .identity).inverted() else { throw EntityTransformError.noninvertibleTransform }
            func sceneZ(_ entity: Entity?) -> Float {
                var z: Float = 0; var current = entity
                while let e = current { z += e.zPosition; current = e.parent }
                return z
            }
            preserved = try Transform(matrix: inverse * sceneTransformMatrix, zPosition: sceneZ(self) - sceneZ(newParent))
        }
        removeFromParent()
        if let preserved { transform = preserved }
        newParent?.adopt(self)
    }

    /// Adds a child, throwing if the requested world-preserving change cannot be
    /// represented. The one-argument `addChild` remains available for simple setup.
    public func addChild(_ child: Entity, preservingWorldTransform: Bool) throws {
        try child.setParent(self, preservingWorldTransform: preservingWorldTransform)
    }
}
