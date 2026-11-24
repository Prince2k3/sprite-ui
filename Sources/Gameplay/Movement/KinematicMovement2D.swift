import Foundation

/// Invalid shared movement rules, untrusted direction, or nonfinite/out-of-bounds state.
public enum KinematicMovementError: Error, Equatable, Sendable { case invalidRules, invalidInput, invalidState, invalidDuration }

/// Inert root-local kinematic state; it contains no renderer or native physics state.
public struct KinematicState2D: Codable, Hashable, Sendable {
    /// The canonical center position in shared game units.
    public var position: SIMD2<Float>
    /// Actual velocity after boundary clamping.
    public var velocity: SIMD2<Float>
    /// Creates a state that must be validated against the shared movement rules.
    public init(position: SIMD2<Float> = .zero, velocity: SIMD2<Float> = .zero) { self.position = position; self.velocity = velocity }
}

/// A pure fixed-step movement rule shared by prediction and authoritative simulation.
/// This first adapter supports rectangular center bounds, not native SpriteKit contacts or world rollback.
public struct KinematicMovement2D: Codable, Hashable, Sendable {
    /// Maximum speed in game units per second, validated in 0...10,000.
    public let maximumSpeed: Float
    /// Optional finite rectangular limits on the actor center.
    public let bounds: BoundingBox?
    /// Creates inert rules. Validate decoded or externally supplied rules before use.
    public init(maximumSpeed: Float = 120, bounds: BoundingBox? = nil) { self.maximumSpeed = maximumSpeed; self.bounds = bounds }
    /// Validates finite, bounded rules.
    public func validate() throws {
        guard maximumSpeed.isFinite, (0...10_000).contains(maximumSpeed) else { throw KinematicMovementError.invalidRules }
        if let bounds {
            guard finite(bounds.min), finite(bounds.max), bounds.min.x <= bounds.max.x, bounds.min.y <= bounds.max.y else { throw KinematicMovementError.invalidRules }
        }
    }
    /// Rejects nonfinite input or vectors whose magnitude exceeds one.
    public func validate(direction: SIMD2<Float>) throws {
        guard finite(direction), direction.x * direction.x + direction.y * direction.y <= 1.000_01 else { throw KinematicMovementError.invalidInput }
    }
    /// Validates a full state before prediction, reconciliation, or a host correction.
    public func validate(state: KinematicState2D) throws {
        try validate()
        guard finite(state.position), finite(state.velocity), abs(state.position.x) <= 1_000_000, abs(state.position.y) <= 1_000_000,
              state.velocity.x * state.velocity.x + state.velocity.y * state.velocity.y <= maximumSpeed * maximumSpeed + 0.1,
              bounds?.contains(state.position) ?? true else { throw KinematicMovementError.invalidState }
    }
    /// Advances exactly one supplied fixed step; diagonals cannot exceed maximumSpeed.
    public func step(_ state: KinematicState2D, direction: SIMD2<Float>, deltaTime: TimeInterval) throws -> KinematicState2D {
        try validate(state: state); try validate(direction: direction)
        guard deltaTime.isFinite, deltaTime > 0, deltaTime <= 0.1 else { throw KinematicMovementError.invalidDuration }
        let dt = Float(deltaTime)
        let lengthSquared = direction.x * direction.x + direction.y * direction.y
        let desired = direction * (lengthSquared > 1 ? maximumSpeed / sqrt(lengthSquared) : maximumSpeed)
        var next = state.position + desired * dt
        if let bounds { next = SIMD2(max(bounds.min.x, min(bounds.max.x, next.x)), max(bounds.min.y, min(bounds.max.y, next.y))) }
        var velocity = (next - state.position) / dt
        let speedSquared = velocity.x * velocity.x + velocity.y * velocity.y
        if speedSquared > maximumSpeed * maximumSpeed { velocity *= maximumSpeed / sqrt(speedSquared) }
        let result = KinematicState2D(position: next, velocity: velocity)
        try validate(state: result); return result
    }
    private func finite(_ value: SIMD2<Float>) -> Bool { value.x.isFinite && value.y.isFinite }
}
