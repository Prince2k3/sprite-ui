import Foundation

/// Steering behaviors.
///
/// Each function returns the force that moves an agent toward what it wants. Forces
/// add, so weight and sum several, then pass the total to
/// ``Agent2D/apply(_:deltaTime:)``, which caps it at the agent's `maxForce`.
public enum AgentGoal {
    // MARK: Targets

    /// Head straight for `target` at full speed.
    public static func seek(_ agent: Agent2D, toward target: SIMD2<Float>) -> SIMD2<Float> {
        steer(agent, toward: resized(target - agent.position, to: agent.maxSpeed))
    }

    /// Run directly away from `threat` while it's within `panicDistance`.
    public static func flee(
        _ agent: Agent2D,
        from threat: SIMD2<Float>,
        panicDistance: Float = .infinity
    ) -> SIMD2<Float> {
        let away = agent.position - threat
        guard dot(away, away) <= panicDistance * panicDistance else { return .zero }
        // Standing on the threat: any direction will do, so keep going or pick +x.
        let direction = away == .zero ? (agent.heading ?? [1, 0]) : away
        return steer(agent, toward: resized(direction, to: agent.maxSpeed))
    }

    /// Head for `target`, slowing down inside `slowingRadius` to stop on it.
    ///
    /// ``Agent2D/brakingDistance`` is a good `slowingRadius`.
    public static func arrive(
        _ agent: Agent2D,
        at target: SIMD2<Float>,
        slowingRadius: Float
    ) -> SIMD2<Float> {
        let offset = target - agent.position
        let distance = magnitude(offset)
        guard distance > 0.01 else { return steer(agent, toward: .zero) }
        let speed = slowingRadius > 0 ? agent.maxSpeed * min(distance / slowingRadius, 1) : agent.maxSpeed
        return steer(agent, toward: offset * (speed / distance))
    }

    /// Speed up or slow down to `speed` without turning.
    /// An agent standing still sets off along +x.
    public static func reachSpeed(_ agent: Agent2D, _ speed: Float) -> SIMD2<Float> {
        let target = max(0, min(speed, agent.maxSpeed))
        return steer(agent, toward: (agent.heading ?? [1, 0]) * target)
    }

    /// Head for where a moving target is going to be.
    public static func pursue(
        _ agent: Agent2D,
        target position: SIMD2<Float>,
        moving velocity: SIMD2<Float>
    ) -> SIMD2<Float> {
        seek(agent, toward: position + velocity * leadTime(agent, position, velocity))
    }

    /// Run from where a moving threat is going to be.
    public static func evade(
        _ agent: Agent2D,
        threat position: SIMD2<Float>,
        moving velocity: SIMD2<Float>,
        panicDistance: Float = .infinity
    ) -> SIMD2<Float> {
        let gap = agent.position - position
        guard dot(gap, gap) <= panicDistance * panicDistance else { return .zero }
        return flee(agent, from: position + velocity * leadTime(agent, position, velocity))
    }

    /// Roughly how long until the agent could reach a moving point.
    private static func leadTime(_ agent: Agent2D, _ position: SIMD2<Float>, _ velocity: SIMD2<Float>) -> Float {
        let closingSpeed = agent.maxSpeed + magnitude(velocity)
        return closingSpeed > 0 ? magnitude(position - agent.position) / closingSpeed : 0
    }

    /// The force that changes the agent's velocity to `desired`. Scaled so a full
    /// reversal at top speed uses twice `maxForce`, which makes the agent respond in
    /// about `maxSpeed / maxForce` seconds whatever units it moves in.
    public static func steer(_ agent: Agent2D, toward desired: SIMD2<Float>) -> SIMD2<Float> {
        guard agent.maxSpeed > 0 else { return .zero }
        return (desired - agent.velocity) * (agent.maxForce * agent.mass / agent.maxSpeed)
    }

    // MARK: Groups

    /// Move away from neighbors, pushing harder the closer they are.
    public static func separate(_ agent: Agent2D, from neighbors: some Sequence<SIMD2<Float>>) -> SIMD2<Float> {
        var push = SIMD2<Float>.zero
        for neighbor in neighbors {
            let away = agent.position - neighbor
            let distanceSquared = dot(away, away)
            if distanceSquared > 0 { push += away / distanceSquared }
        }
        return push == .zero ? .zero : steer(agent, toward: resized(push, to: agent.maxSpeed))
    }

    /// Match the neighbors' average direction.
    public static func align(_ agent: Agent2D, with velocities: some Sequence<SIMD2<Float>>) -> SIMD2<Float> {
        var total = SIMD2<Float>.zero
        for velocity in velocities { total += resized(velocity, to: 1) }
        return total == .zero ? .zero : steer(agent, toward: resized(total, to: agent.maxSpeed))
    }

    /// Move toward the neighbors' center.
    public static func cohere(_ agent: Agent2D, with neighbors: some Sequence<SIMD2<Float>>) -> SIMD2<Float> {
        var total = SIMD2<Float>.zero
        var count: Float = 0
        for neighbor in neighbors {
            total += neighbor
            count += 1
        }
        return count > 0 ? seek(agent, toward: total / count) : .zero
    }

    // MARK: Surroundings

    /// Swerve around obstacles in the agent's way, looking `lookAhead` seconds ahead.
    /// An agent already overlapping an obstacle is pushed straight out.
    public static func avoid(
        _ agent: Agent2D,
        obstacles: some Sequence<CircleObstacle>,
        lookAhead: Float = 1
    ) -> SIMD2<Float> {
        var escape = SIMD2<Float>.zero
        var threat: (along: Float, lateral: Float)?
        let heading = agent.heading
        let reach = max(agent.speed * lookAhead, agent.radius)
        let side = heading.map { SIMD2(-$0.y, $0.x) } ?? .zero

        for obstacle in obstacles {
            let offset = obstacle.center - agent.position
            let clearance = obstacle.radius + agent.radius
            let distanceSquared = dot(offset, offset)
            if distanceSquared < clearance * clearance {
                escape += distanceSquared > 0 ? -offset / distanceSquared.squareRoot() : -(heading ?? [1, 0])
                continue
            }
            guard let heading else { continue }
            let along = dot(offset, heading)
            let lateral = dot(offset, side)
            guard along > 0, along - clearance < reach, abs(lateral) < clearance else { continue }
            if threat == nil || along < threat!.along { threat = (along, lateral) }
        }

        if escape != .zero { return resized(escape, to: agent.maxForce) }
        guard let threat, let heading else { return .zero }
        // Closer obstacles call for a harder swerve and some braking.
        let urgency = max(0, min(1, 1 - threat.along / max(reach, 1e-3)))
        let away: Float = threat.lateral >= 0 ? -1 : 1
        return side * (away * agent.maxForce * (1 + urgency)) - heading * (agent.maxForce * urgency * 0.5)
    }

    /// Steer clear of polygon walls, looking `lookAhead` seconds ahead.
    ///
    /// When where the agent is headed comes within its radius of a polygon, it
    /// turns away from the nearest point on the wall, harder the deeper it would
    /// go. An agent already overlapping a wall is pushed straight out.
    public static func avoid(
        _ agent: Agent2D,
        polygons: some Sequence<PolygonObstacle>,
        lookAhead: Float = 0.5
    ) -> SIMD2<Float> {
        var push = SIMD2<Float>.zero
        let probe = agent.predictedPosition(after: lookAhead)
        let reach = max(agent.radius, 1)
        for polygon in polygons {
            // Skip polygons nowhere near the agent or where it's going.
            let range = agent.radius + agent.speed * lookAhead + reach
            guard polygon.boundingBox.distanceSquared(to: agent.position) < range * range else { continue }

            for point in [agent.position, probe] {
                let wall = polygon.closestPoint(to: point)
                let inside = polygon.contains(point)
                let gap = magnitude(point - wall) * (inside ? -1 : 1)
                guard gap < agent.radius else { continue }
                var away = inside ? wall - point : point - wall
                if away == .zero { away = -(agent.heading ?? [1, 0]) }
                // 0 just touching, 1 at the wall, more past it.
                let depth = (agent.radius - gap) / reach
                push += normalized(away) * agent.maxForce * min(depth, 2)
            }
        }
        return clampedLength(push, max: agent.maxForce * 2)
    }

    /// Turn back toward the inside when within `margin` of the edge of `bounds`.
    public static func stay(_ agent: Agent2D, within bounds: BoundingBox, margin: Float = 0) -> SIMD2<Float> {
        var desired = agent.velocity
        var turning = false
        for axis in 0..<2 {
            if agent.position[axis] < bounds.min[axis] + margin {
                desired[axis] = agent.maxSpeed
                turning = true
            } else if agent.position[axis] > bounds.max[axis] - margin {
                desired[axis] = -agent.maxSpeed
                turning = true
            }
        }
        return turning ? steer(agent, toward: desired) : .zero
    }

    /// Travel along `path`, aiming just past the point on it nearest to where the
    /// agent will be in `lookAhead` seconds. Longer look-aheads cut corners more. An
    /// open path ends with the agent stopping on its last point.
    public static func follow(_ agent: Agent2D, path: AgentPath, lookAhead: Float = 0.5) -> SIMD2<Float> {
        let along = path.distance(closestTo: agent.predictedPosition(after: lookAhead))
        let ahead = max(path.radius, 1)
        if !path.isClosed, along + ahead >= path.length {
            return arrive(agent, at: path.points[path.points.count - 1], slowingRadius: max(agent.brakingDistance, 1))
        }
        return seek(agent, toward: path.point(atDistance: along + ahead))
    }

    /// Keep within `path`'s radius without moving along it.
    /// Nothing happens while the agent and where it will be in `lookAhead`
    /// seconds are both on the path; otherwise it turns back toward the nearest
    /// point on it. Pair it with goals that move the agent.
    public static func stay(_ agent: Agent2D, on path: AgentPath, lookAhead: Float = 0.5) -> SIMD2<Float> {
        guard !path.points.isEmpty else { return .zero }
        let probe = agent.predictedPosition(after: lookAhead)
        let nearest = path.point(atDistance: path.distance(closestTo: probe))
        let gap = magnitude(probe - nearest)
        guard gap > path.radius else { return .zero }
        // Harder the further out it would stray, up to a full turn at twice the radius.
        let strength = min((gap - path.radius) / max(path.radius, 1), 1)
        return seek(agent, toward: nearest) * strength
    }
}

/// Aimless but smooth wandering. Keeps the random walk's state between steps.
public struct Wander: Hashable, Codable, Sendable {
    /// The size of the circle the target moves around. Bigger means sharper turns.
    public var radius: Float
    /// How far ahead of the agent the circle sits. Bigger means steadier paths.
    public var distance: Float
    /// Roughly how many radians the target drifts in a second.
    public var rate: Float
    /// Where on the circle the target is, relative to the agent's heading.
    public var angle: Float

    public init(radius: Float = 30, distance: Float = 60, rate: Float = 3, angle: Float = 0) {
        self.radius = radius
        self.distance = distance
        self.rate = rate
        self.angle = angle
    }

    /// Nudges the target around the circle and steers toward it.
    public mutating func force(
        for agent: Agent2D,
        deltaTime: Float,
        using generator: inout some RandomNumberGenerator
    ) -> SIMD2<Float> {
        // Scaling by √dt makes the drift per second the same at any frame rate.
        angle += Float.random(in: -1...1, using: &generator) * rate * max(deltaTime, 0).squareRoot()
        angle = angle.truncatingRemainder(dividingBy: 2 * .pi)
        let heading = agent.heading ?? [1, 0]
        let facing = atan2(heading.y, heading.x) + angle
        let target = agent.position + heading * distance + SIMD2(cos(facing), sin(facing)) * radius
        return AgentGoal.seek(agent, toward: target)
    }
}
