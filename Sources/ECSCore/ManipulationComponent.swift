import Foundation

/// Opts a pickable entity into GameView's direct manipulation. Add an
/// ``InputTargetComponent`` as well. Configuration is copied and saved by value;
/// active gesture captures are runtime state and are never cloned or restored.
public struct ManipulationComponent: Component, Hashable, Codable, Sendable {
    /// Transform channels a gesture may change.
    public struct Operations: OptionSet, Hashable, Codable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let translation = Self(rawValue: 1 << 0)
        public static let rotation = Self(rawValue: 1 << 1)
        public static let scale = Self(rawValue: 1 << 2)
        public static let all: Self = [.translation, .rotation, .scale]
    }
    /// Parent-local axes on which translation is allowed.
    public struct TranslationAxes: OptionSet, Hashable, Codable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let x = Self(rawValue: 1 << 0)
        public static let y = Self(rawValue: 1 << 1)
        public static let all: Self = [.x, .y]
    }
    /// Inclusive limits for the entity origin in its parent's coordinates.
    public struct Bounds: Hashable, Codable, Sendable {
        public var min: SIMD2<Float>
        public var max: SIMD2<Float>
        public init(min: SIMD2<Float>, max: SIMD2<Float>) { self.min = min; self.max = max }
        public init(center: SIMD2<Float>, size: SIMD2<Float>) {
            min = center - size / 2; max = center + size / 2
        }
    }
    /// Velocity to use after releasing a temporarily suspended dynamic body.
    public enum PhysicsRelease: String, Hashable, Codable, Sendable {
        case stop
        case restoreVelocity
    }

    public var isEnabled: Bool
    public var operations: Operations
    public var translationAxes: TranslationAxes
    public var translationBounds: Bounds?
    /// Positive grid steps per axis, measured from the parent origin; nil disables snapping.
    public var translationSnap: SIMD2<Float>?
    /// A positive angular grid step in radians, measured from zero.
    public var rotationSnap: Float?
    /// Allowed absolute local scale magnitudes. Uniform gestures preserve aspect ratio.
    public var scaleRange: ClosedRange<Float>
    public var physicsRelease: PhysicsRelease

    public init(isEnabled: Bool = true, operations: Operations = .all, translationAxes: TranslationAxes = .all,
                translationBounds: Bounds? = nil, translationSnap: SIMD2<Float>? = nil,
                rotationSnap: Float? = nil, scaleRange: ClosedRange<Float> = 0.25...4,
                physicsRelease: PhysicsRelease = .stop) {
        self.isEnabled = isEnabled; self.operations = operations; self.translationAxes = translationAxes
        self.translationBounds = translationBounds; self.translationSnap = translationSnap
        self.rotationSnap = rotationSnap; self.scaleRange = scaleRange; self.physicsRelease = physicsRelease
    }

    /// Applies parent-local locks, snapping and bounds to a proposed pose. Returns
    /// nil for nonfinite values, invalid configuration, or an impossible scale range.
    /// Locked and unselected channels retain their initial values; z order is unchanged.
    public func constrained(_ proposed: Transform, relativeTo initial: Transform, operations requested: Operations = .all) -> Transform? {
        func finite(_ v: SIMD2<Float>) -> Bool { v.x.isFinite && v.y.isFinite }
        guard isEnabled, scaleRange.lowerBound.isFinite, scaleRange.upperBound.isFinite,
              scaleRange.lowerBound > 0, scaleRange.lowerBound <= scaleRange.upperBound,
              finite(initial.translation), finite(initial.scale), initial.rotation.isFinite, initial.zPosition.isFinite,
              finite(proposed.translation), finite(proposed.scale), proposed.rotation.isFinite, proposed.zPosition.isFinite,
              translationBounds.map({ finite($0.min) && finite($0.max) && $0.min.x <= $0.max.x && $0.min.y <= $0.max.y }) ?? true,
              translationSnap.map({ finite($0) && $0.x > 0 && $0.y > 0 }) ?? true,
              rotationSnap.map({ $0.isFinite && $0 > 0 }) ?? true else { return nil }
        let allowed = operations.intersection(requested)
        var result = initial
        if allowed.contains(.translation) {
            for axis in 0..<2 where translationAxes.contains(axis == 0 ? .x : .y) {
                var value = proposed.translation[axis]
                if let snap = translationSnap { value = (value / snap[axis]).rounded() * snap[axis] }
                if let bounds = translationBounds { value = Swift.min(Swift.max(value, bounds.min[axis]), bounds.max[axis]) }
                result.translation[axis] = value
            }
        }
        if allowed.contains(.rotation) {
            result.rotation = rotationSnap.map { (proposed.rotation / $0).rounded() * $0 } ?? proposed.rotation
        }
        if allowed.contains(.scale) {
            guard initial.scale.x != 0, initial.scale.y != 0 else { return nil }
            let x = proposed.scale.x / initial.scale.x, y = proposed.scale.y / initial.scale.y
            guard x.isFinite, y.isFinite, x > 0, y > 0, abs(x - y) <= 1e-4 * Swift.max(x, y) else { return nil }
            let lower = Swift.max(scaleRange.lowerBound / abs(initial.scale.x), scaleRange.lowerBound / abs(initial.scale.y))
            let upper = Swift.min(scaleRange.upperBound / abs(initial.scale.x), scaleRange.upperBound / abs(initial.scale.y))
            guard lower <= upper else { return nil }
            result.scale = initial.scale * Swift.min(Swift.max(x, lower), upper)
        }
        guard finite(result.translation), finite(result.scale), result.rotation.isFinite else { return nil }
        return result
    }
}

/// Lifecycle events emitted from the manipulated entity after its pose is committed.
public enum ManipulationEvents {
    public enum CancellationReason: String, Codable, Sendable {
        case inputCancelled, entityUnavailable, configurationChanged, hierarchyChanged, transformChanged, physicsChanged
    }
    public struct Began: Event {
        public let entity: Entity
        public let initialTransform: Transform
        public let transform: Transform
        public init(entity: Entity, initialTransform: Transform, transform: Transform) {
            self.entity = entity; self.initialTransform = initialTransform; self.transform = transform
        }
    }
    public struct Changed: Event {
        public let entity: Entity
        public let initialTransform: Transform
        public let transform: Transform
        public init(entity: Entity, initialTransform: Transform, transform: Transform) {
            self.entity = entity; self.initialTransform = initialTransform; self.transform = transform
        }
    }
    public struct Ended: Event {
        public let entity: Entity
        public let initialTransform: Transform
        public let transform: Transform
        public init(entity: Entity, initialTransform: Transform, transform: Transform) {
            self.entity = entity; self.initialTransform = initialTransform; self.transform = transform
        }
    }
    public struct Cancelled: Event {
        public let entity: Entity
        public let initialTransform: Transform
        public let transform: Transform
        public let reason: CancellationReason
        public init(entity: Entity, initialTransform: Transform, transform: Transform, reason: CancellationReason) {
            self.entity = entity; self.initialTransform = initialTransform; self.transform = transform; self.reason = reason
        }
    }
}
