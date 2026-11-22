/// A graph for finding paths around polygon obstacles, in place of `GKObstacleGraph`.
///
/// Every obstacle is padded by ``bufferRadius``, the radius of the units that
/// will walk the paths. The nodes are the outward corners of the padded
/// obstacles, joined wherever one can see another. A unit following a path
/// therefore keeps at least `bufferRadius` from every obstacle, and gaps
/// narrower than twice that are closed.
///
/// ```swift
/// var graph = ObstacleGraph(obstacles: walls, bufferRadius: 12)
/// let route = graph.findPath(from: unit, to: tap)   // [unit, corner, …, tap]
///
/// graph.obstacles.append(crate)                      // the graph updates
/// ```
///
/// Changing ``obstacles`` or ``bufferRadius`` rebuilds the graph, which takes
/// time proportional to the corner count squared times the edge count, so batch
/// changes rather than making many small ones every frame.
public struct ObstacleGraph: Graph, Sendable {
    public typealias Node = SIMD2<Float>

    /// The obstacles to go around, as given.
    public var obstacles: [PolygonObstacle] {
        didSet { rebuild() }
    }

    /// How far paths keep from every obstacle; the radius of the units that use it.
    public var bufferRadius: Float {
        didSet { rebuild() }
    }

    /// The obstacles grown by ``bufferRadius``, which paths may touch but not enter.
    public private(set) var paddedObstacles: [PolygonObstacle] = []

    /// The corners paths can turn at, in a fixed order.
    public private(set) var nodes: [SIMD2<Float>] = []

    private var links: [SIMD2<Float>: [GraphEdge<SIMD2<Float>>]] = [:]

    public init(obstacles: [PolygonObstacle] = [], bufferRadius: Float = 0) {
        self.obstacles = obstacles
        self.bufferRadius = max(0, bufferRadius)
        rebuild()
    }

    /// Pairs of nodes that can see each other, each pair once.
    public var connections: [(SIMD2<Float>, SIMD2<Float>)] {
        nodes.enumerated().flatMap { index, node in
            neighbors(of: node).compactMap { edge in
                nodes.firstIndex(of: edge.to).flatMap { $0 > index ? (node, edge.to) : nil }
            }
        }
    }

    public func neighbors(of node: SIMD2<Float>) -> [GraphEdge<SIMD2<Float>>] {
        links[node] ?? []
    }

    public func estimatedCost(from node: SIMD2<Float>, to goal: SIMD2<Float>) -> Float {
        magnitude(goal - node)
    }

    /// Whether a unit can walk straight from `a` to `b` without entering any
    /// padded obstacle.
    public func isClear(from a: SIMD2<Float>, to b: SIMD2<Float>) -> Bool {
        isClear(from: a, to: b, ignoring: [])
    }

    /// Whether `point` is somewhere a unit can stand: outside every padded obstacle.
    public func isWalkable(_ point: SIMD2<Float>) -> Bool {
        !paddedObstacles.contains { $0.contains(point) }
    }

    /// The shortest path between any two points, both included, or `nil` if
    /// `goal` is inside a padded obstacle or can't be reached.
    ///
    /// The points don't need to be nodes; they're joined to every corner they
    /// can see for this search only, like `GKObstacleGraph.connectUsingObstacles(node:)`
    /// without having to remove them afterwards. A `start` inside a padded
    /// obstacle may walk straight out of it, so a unit pushed into the padding
    /// can still find its way, though never through the obstacle itself.
    public func findPath(from start: SIMD2<Float>, to goal: SIMD2<Float>) -> [SIMD2<Float>]? {
        guard isWalkable(goal) else { return nil }
        if start == goal { return [start] }
        // Padding the start is caught in only blocks its first step where the
        // obstacle itself does.
        let trapping = Set(paddedObstacles.indices.filter { paddedObstacles[$0].contains(start) })
        if isClear(from: start, to: goal, ignoring: trapping) { return [start, goal] }

        var extended = Extended(base: self, start: start, goal: goal)
        for node in nodes where node != start {
            if isClear(from: start, to: node, ignoring: trapping) {
                extended.startEdges.append(GraphEdge(to: node, cost: magnitude(node - start)))
            }
            if isClear(from: node, to: goal) {
                extended.goalCosts[node] = magnitude(goal - node)
            }
        }
        return extended.findPath(from: start, to: goal)
    }

    /// The obstacle graph plus a start and goal joined to the corners they can see.
    private struct Extended: Graph {
        let base: ObstacleGraph
        let start: SIMD2<Float>
        let goal: SIMD2<Float>
        var startEdges: [GraphEdge<SIMD2<Float>>] = []
        var goalCosts: [SIMD2<Float>: Float] = [:]

        func neighbors(of node: SIMD2<Float>) -> [GraphEdge<SIMD2<Float>>] {
            if node == start { return startEdges }
            var edges = base.neighbors(of: node)
            if let cost = goalCosts[node] { edges.append(GraphEdge(to: goal, cost: cost)) }
            return edges
        }

        func estimatedCost(from node: SIMD2<Float>, to goal: SIMD2<Float>) -> Float {
            magnitude(goal - node)
        }
    }

    /// Checks `trapped` obstacles' own outlines instead of their padding.
    private func isClear(from a: SIMD2<Float>, to b: SIMD2<Float>, ignoring trapped: Set<Int>) -> Bool {
        for index in paddedObstacles.indices {
            let outline = trapped.contains(index) ? obstacles[index] : paddedObstacles[index]
            if outline.intersects(segmentFrom: a, to: b) { return false }
        }
        return true
    }

    private mutating func rebuild() {
        paddedObstacles = obstacles.map { $0.inflated(by: bufferRadius) }

        // Outward corners that aren't swallowed by another obstacle's padding.
        var corners: [SIMD2<Float>] = []
        var seen: Set<SIMD2<Float>> = []
        for (index, padded) in paddedObstacles.enumerated() {
            for (i, corner) in padded.points.enumerated() where padded.isConvex(at: i) {
                let buried = paddedObstacles.indices.contains { $0 != index && paddedObstacles[$0].contains(corner) }
                if !buried, seen.insert(corner).inserted { corners.append(corner) }
            }
        }
        nodes = corners

        var links: [SIMD2<Float>: [GraphEdge<SIMD2<Float>>]] = [:]
        for i in corners.indices {
            for j in corners.indices where j > i && isClear(from: corners[i], to: corners[j], ignoring: []) {
                let cost = magnitude(corners[j] - corners[i])
                links[corners[i], default: []].append(GraphEdge(to: corners[j], cost: cost))
                links[corners[j], default: []].append(GraphEdge(to: corners[i], cost: cost))
            }
        }
        self.links = links
    }
}
