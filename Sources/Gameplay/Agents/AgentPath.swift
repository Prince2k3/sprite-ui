/// A line of points for agents to follow.
///
/// Measure along it with ``distance(closestTo:)`` and ``point(atDistance:)``, or
/// hand it to ``AgentGoal/follow(_:path:lookAhead:)``.
public struct AgentPath: Hashable, Sendable {
    public let points: [SIMD2<Float>]
    /// How far from the line an agent may drift.
    public let radius: Float
    /// Whether the last point joins back to the first.
    public let isClosed: Bool
    /// Distance along the path at the start of each segment, plus the total at the end.
    private let marks: [Float]

    public init(points: [SIMD2<Float>], radius: Float = 10, isClosed: Bool = false) {
        precondition(!points.isEmpty, "A path needs at least one point.")
        self.points = points
        self.radius = radius
        self.isClosed = isClosed && points.count > 2
        var marks: [Float] = [0]
        let segmentCount = self.isClosed ? points.count : points.count - 1
        for i in 0..<segmentCount {
            let a = points[i], b = points[(i + 1) % points.count]
            marks.append(marks[i] + magnitude(b - a))
        }
        self.marks = marks
    }

    /// The path's total length, including the closing segment if closed.
    public var length: Float { marks[marks.count - 1] }

    private var segmentCount: Int { marks.count - 1 }

    /// How far along the path its nearest point to `point` is.
    public func distance(closestTo point: SIMD2<Float>) -> Float {
        guard segmentCount > 0 else { return 0 }
        var best = Float.infinity
        var bestDistance: Float = 0
        for i in 0..<segmentCount {
            let a = points[i], b = points[(i + 1) % points.count]
            let edge = b - a
            let edgeLengthSquared = dot(edge, edge)
            let t = edgeLengthSquared > 0 ? min(max(dot(point - a, edge) / edgeLengthSquared, 0), 1) : 0
            let gap = point - (a + edge * t)
            let gapSquared = dot(gap, gap)
            if gapSquared < best {
                best = gapSquared
                bestDistance = marks[i] + t * (marks[i + 1] - marks[i])
            }
        }
        return bestDistance
    }

    /// The point `distance` along the path. Closed paths wrap around; open ones
    /// stop at their ends.
    public func point(atDistance distance: Float) -> SIMD2<Float> {
        guard segmentCount > 0, length > 0 else { return points[0] }
        var d = distance
        if isClosed {
            d = d.truncatingRemainder(dividingBy: length)
            if d < 0 { d += length }
        } else {
            d = min(max(d, 0), length)
        }
        // Binary search for the segment holding d.
        var low = 0, high = segmentCount - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if marks[mid] <= d { low = mid } else { high = mid - 1 }
        }
        let a = points[low], b = points[(low + 1) % points.count]
        let span = marks[low + 1] - marks[low]
        return span > 0 ? a + (b - a) * ((d - marks[low]) / span) : a
    }
}

extension AgentPath: Codable {
    private enum CodingKeys: String, CodingKey { case points, radius, isClosed }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let points = try container.decode([SIMD2<Float>].self, forKey: .points)
        guard !points.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .points, in: container, debugDescription: "A path needs at least one point.")
        }
        self.init(
            points: points,
            radius: try container.decode(Float.self, forKey: .radius),
            isClosed: try container.decode(Bool.self, forKey: .isClosed)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(points, forKey: .points)
        try container.encode(radius, forKey: .radius)
        try container.encode(isClosed, forKey: .isClosed)
    }
}
