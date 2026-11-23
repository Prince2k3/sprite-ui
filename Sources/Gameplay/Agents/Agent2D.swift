/// Something that moves by steering, in place of `GKAgent2D`.
///
/// Goal functions such as ``AgentGoal/seek(_:toward:)`` return a force; add up
/// the ones you want, weighted, and pass the total to ``apply(_:deltaTime:)``:
///
/// ```swift
/// var agent = Agent2D(position: .zero, maxSpeed: 120, maxForce: 300)
/// let force = AgentGoal.seek(agent, toward: goal) + 2 * AgentGoal.avoid(agent, obstacles: rocks)
/// agent.apply(force, deltaTime: 1 / 60)
/// ```
public struct Agent2D: Hashable, Codable, Sendable {
    public var position: SIMD2<Float>
    public var velocity: SIMD2<Float>
    /// Points per second the agent never goes faster than.
    public var maxSpeed: Float
    /// The largest force applied in one step. Lower values turn and stop more slowly.
    public var maxForce: Float
    /// Heavier agents respond to the same force more slowly.
    public var mass: Float
    /// How much room the agent takes up, used to keep clear of obstacles.
    public var radius: Float

    public init(
        position: SIMD2<Float> = .zero,
        velocity: SIMD2<Float> = .zero,
        maxSpeed: Float,
        maxForce: Float,
        mass: Float = 1,
        radius: Float = 0
    ) {
        self.position = position
        self.velocity = velocity
        self.maxSpeed = maxSpeed
        self.maxForce = maxForce
        self.mass = mass
        self.radius = radius
    }

    public var speed: Float { magnitude(velocity) }

    /// The direction of travel, or `nil` when standing still.
    public var heading: SIMD2<Float>? {
        let speed = speed
        return speed > 1e-4 ? velocity / speed : nil
    }

    /// How far the agent travels from full speed before it can stop.
    public var brakingDistance: Float {
        let deceleration = maxForce / mass
        return deceleration > 0 ? maxSpeed * maxSpeed / (2 * deceleration) : .infinity
    }

    /// Where the agent will be after `seconds` at its current velocity.
    public func predictedPosition(after seconds: Float) -> SIMD2<Float> {
        position + velocity * seconds
    }

    /// Moves the agent one step under `force`, capped at ``maxForce`` and ``maxSpeed``.
    public mutating func apply(_ force: SIMD2<Float>, deltaTime: Float) {
        guard deltaTime > 0, mass > 0 else { return }
        let acceleration = clampedLength(force, max: maxForce) / mass
        velocity = clampedLength(velocity + acceleration * deltaTime, max: maxSpeed)
        position += velocity * deltaTime
    }
}

/// A round thing for agents to steer around, in place of `GKCircleObstacle`.
public struct CircleObstacle: Hashable, Codable, Sendable {
    public var center: SIMD2<Float>
    public var radius: Float

    public init(center: SIMD2<Float>, radius: Float) {
        self.center = center
        self.radius = radius
    }
}

// MARK: Vector helpers

@inline(__always)
func dot(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { (a * b).sum() }

@inline(__always)
func magnitude(_ v: SIMD2<Float>) -> Float { dot(v, v).squareRoot() }

/// `v` scaled to `length`, or zero when `v` is zero.
@inline(__always)
func resized(_ v: SIMD2<Float>, to length: Float) -> SIMD2<Float> {
    let current = magnitude(v)
    return current > 0 ? v * (length / current) : .zero
}

/// `v` shortened to `max` if it's longer.
@inline(__always)
func clampedLength(_ v: SIMD2<Float>, max: Float) -> SIMD2<Float> {
    let current = magnitude(v)
    return current > max && current > 0 ? v * (max / current) : v
}
