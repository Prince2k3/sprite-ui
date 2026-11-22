/// The walkable floor of a level covered in triangles, for finding paths
/// through open areas, in place of `GKMeshGraph`.
///
/// The floor is ``bounds`` minus every obstacle, with both padded by
/// ``bufferRadius``, the radius of the units that walk it. Gaps narrower than
/// twice that are closed. Paths run through the triangles and are pulled tight,
/// so they hug corners just as ``ObstacleGraph`` paths do, but the search only
/// visits the triangles between start and goal rather than every corner pair.
///
/// ```swift
/// var mesh = NavigationMesh(bounds: room, obstacles: walls, bufferRadius: 12)
/// let route = mesh.findPath(from: unit, to: tap)   // [unit, corner, …, tap]
///
/// mesh.obstacles.append(crate)                      // the mesh rebuilds
/// ```
///
/// As a ``Graph`` its nodes are indices into ``triangles``, joined where two
/// triangles share an edge.
public struct NavigationMesh: Graph, Sendable {
    public typealias Node = Int

    /// One triangle of floor, corners counter-clockwise.
    public struct Triangle: Hashable, Sendable {
        public var a: SIMD2<Float>
        public var b: SIMD2<Float>
        public var c: SIMD2<Float>

        public init(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) {
            self.a = a
            self.b = b
            self.c = c
        }

        public var centroid: SIMD2<Float> { (a + b + c) / 3 }
        public var area: Float { cross(b - a, c - a) / 2 }

        /// Whether `point` is inside or on the edge.
        public func contains(_ point: SIMD2<Float>) -> Bool {
            for (u, v) in [(a, b), (b, c), (c, a)] {
                let edge = v - u
                if cross(edge, point - u) < -PolygonObstacle.tolerance * max(magnitude(edge), 1) { return false }
            }
            return true
        }
    }

    /// The area paths stay inside, before padding.
    public var bounds: BoundingBox {
        didSet { rebuild() }
    }

    /// The obstacles to go around, as given.
    public var obstacles: [PolygonObstacle] {
        didSet { rebuild() }
    }

    /// How far paths keep from every obstacle and from the edge of ``bounds``.
    public var bufferRadius: Float {
        didSet { rebuild() }
    }

    /// The obstacles grown by ``bufferRadius``.
    public private(set) var paddedObstacles: [PolygonObstacle] = []

    /// The walkable floor, in a fixed order. Triangles never overlap and never
    /// cross a padded obstacle.
    public private(set) var triangles: [Triangle] = []

    /// Edges shared by two triangles, which paths cross.
    private var portals: [Portal] = []
    /// The portals around each triangle.
    private var trianglePortals: [[Int]] = []

    public init(bounds: BoundingBox, obstacles: [PolygonObstacle] = [], bufferRadius: Float = 0) {
        self.bounds = bounds
        self.obstacles = obstacles
        self.bufferRadius = max(0, bufferRadius)
        rebuild()
    }

    /// The total area units can stand on.
    public var walkableArea: Float { triangles.reduce(0) { $0 + $1.area } }

    /// Every triangle edge once, for drawing the mesh.
    public var edges: [(SIMD2<Float>, SIMD2<Float>)] {
        var seen: Set<[Float]> = []
        var result: [(SIMD2<Float>, SIMD2<Float>)] = []
        for triangle in triangles {
            for (u, v) in [(triangle.a, triangle.b), (triangle.b, triangle.c), (triangle.c, triangle.a)] {
                let key = u.x < v.x || (u.x == v.x && u.y < v.y) ? [u.x, u.y, v.x, v.y] : [v.x, v.y, u.x, u.y]
                if seen.insert(key).inserted { result.append((u, v)) }
            }
        }
        return result
    }

    /// The index of the triangle `point` is in, or `nil` if it's off the floor.
    public func triangle(containing point: SIMD2<Float>) -> Int? {
        triangles.indices.first { triangles[$0].contains(point) }
    }

    /// Whether `point` is somewhere a unit can stand.
    public func isWalkable(_ point: SIMD2<Float>) -> Bool {
        triangle(containing: point) != nil
    }

    public func neighbors(of node: Int) -> [GraphEdge<Int>] {
        guard trianglePortals.indices.contains(node) else { return [] }
        return trianglePortals[node].map { index in
            let portal = portals[index]
            let other = portal.left == node ? portal.right : portal.left
            return GraphEdge(to: other, cost: magnitude(triangles[other].centroid - triangles[node].centroid))
        }
    }

    public func estimatedCost(from node: Int, to goal: Int) -> Float {
        magnitude(triangles[goal].centroid - triangles[node].centroid)
    }

    /// The shortest path between two points, both included, or `nil` if `goal`
    /// is off the floor or can't be reached.
    ///
    /// A `start` off the floor, such as a unit pushed into the padding, first
    /// steps to the nearest point on it.
    public func findPath(from start: SIMD2<Float>, to goal: SIMD2<Float>) -> [SIMD2<Float>]? {
        guard let goalTriangle = triangle(containing: goal) else { return nil }
        if start == goal { return [start] }
        var origin = start
        var path: [SIMD2<Float>] = []
        var startTriangle = triangle(containing: start)
        if startTriangle == nil {
            guard let nearest = nearestPoint(to: start) else { return nil }
            path.append(start)
            origin = nearest.0
            startTriangle = nearest.1
        }
        guard let startTriangle else { return nil }

        if startTriangle == goalTriangle {
            path += [origin, goal]
        } else {
            let search = PortalSearch(mesh: self, start: origin, goal: goal, startTriangle: startTriangle, goalTriangle: goalTriangle)
            guard let route = search.findPath(from: PortalSearch.start, to: PortalSearch.goal) else { return nil }
            path += pullTight(from: origin, to: goal, crossing: Array(route.dropFirst().dropLast()), startTriangle: startTriangle)
        }
        // Drop repeats, such as a trapped start that was already on the floor's edge.
        return path.reduce(into: []) { result, point in
            if result.last.map({ distanceSquared($0, point) > 1e-8 }) ?? true { result.append(point) }
        }
    }

    // MARK: Path search

    /// An edge shared by two triangles. `left` sees it counter-clockwise as `a` to `b`.
    private struct Portal: Sendable {
        var a: SIMD2<Float>
        var b: SIMD2<Float>
        var left: Int
        var right: Int
        var midpoint: SIMD2<Float> { (a + b) / 2 }
    }

    /// Searches from portal midpoint to portal midpoint, which picks better
    /// corridors than going centroid to centroid through long thin triangles.
    private struct PortalSearch: Graph {
        static let start = -1
        static let goal = -2
        let mesh: NavigationMesh
        let start: SIMD2<Float>
        let goal: SIMD2<Float>
        let startTriangle: Int
        let goalTriangle: Int

        func position(_ node: Int) -> SIMD2<Float> {
            switch node {
            case Self.start: start
            case Self.goal: goal
            default: mesh.portals[node].midpoint
            }
        }

        func neighbors(of node: Int) -> [GraphEdge<Int>] {
            if node == Self.goal { return [] }
            let here = position(node)
            let sides = node == Self.start ? [startTriangle] : [mesh.portals[node].left, mesh.portals[node].right]
            var edges: [GraphEdge<Int>] = []
            for triangle in sides {
                if triangle == goalTriangle { edges.append(GraphEdge(to: Self.goal, cost: magnitude(goal - here))) }
                for next in mesh.trianglePortals[triangle] where next != node {
                    edges.append(GraphEdge(to: next, cost: magnitude(mesh.portals[next].midpoint - here)))
                }
            }
            return edges
        }

        func estimatedCost(from node: Int, to target: Int) -> Float {
            magnitude(position(target) - position(node))
        }
    }

    /// The "simple stupid funnel": the tightest line through the portals.
    private func pullTight(
        from start: SIMD2<Float>,
        to goal: SIMD2<Float>,
        crossing route: [Int],
        startTriangle: Int
    ) -> [SIMD2<Float>] {
        // Each portal as (left, right) seen walking through it.
        var gates: [(SIMD2<Float>, SIMD2<Float>)] = [(start, start)]
        var current = startTriangle
        for (step, index) in route.enumerated() {
            let portal = portals[index]
            if step > 0 {
                // Whichever triangle this portal shares with the last one.
                let previous = portals[route[step - 1]]
                current = [portal.left, portal.right].first { $0 == previous.left || $0 == previous.right } ?? current
            }
            // Leaving a counter-clockwise triangle across a to b, b is on the left.
            gates.append(portal.left == current ? (portal.b, portal.a) : (portal.a, portal.b))
            current = portal.left == current ? portal.right : portal.left
        }
        gates.append((goal, goal))

        var path = [start]
        var apex = start, left = start, right = start
        var apexIndex = 0, leftIndex = 0, rightIndex = 0
        var i = 1
        while i < gates.count {
            let (newLeft, newRight) = gates[i]

            // Narrow the right side.
            if cross(right - apex, newRight - apex) >= 0 {
                if apex == right || cross(left - apex, newRight - apex) < 0 {
                    right = newRight
                    rightIndex = i
                } else {
                    // The right side crossed the left: turn at the left corner.
                    path.append(left)
                    apex = left
                    apexIndex = leftIndex
                    right = apex
                    rightIndex = apexIndex
                    i = apexIndex + 1
                    continue
                }
            }

            // Narrow the left side.
            if cross(left - apex, newLeft - apex) <= 0 {
                if apex == left || cross(right - apex, newLeft - apex) > 0 {
                    left = newLeft
                    leftIndex = i
                } else {
                    path.append(right)
                    apex = right
                    apexIndex = rightIndex
                    left = apex
                    leftIndex = apexIndex
                    i = apexIndex + 1
                    continue
                }
            }
            i += 1
        }
        if path.last != goal { path.append(goal) }
        return path
    }

    /// The point on the floor nearest to `point`, and its triangle.
    private func nearestPoint(to point: SIMD2<Float>) -> (SIMD2<Float>, Int)? {
        var best: (SIMD2<Float>, Int)?
        var bestDistance = Float.infinity
        for (index, triangle) in triangles.enumerated() {
            for (u, v) in [(triangle.a, triangle.b), (triangle.b, triangle.c), (triangle.c, triangle.a)] {
                let candidate = PolygonObstacle.closestPoint(to: point, onSegment: u, v)
                let d = distanceSquared(candidate, point)
                if d < bestDistance {
                    bestDistance = d
                    best = (candidate, index)
                }
            }
        }
        return best
    }

    // MARK: Building

    private mutating func rebuild() {
        paddedObstacles = obstacles.map { $0.inflated(by: bufferRadius) }
        let floor = BoundingBox(min: bounds.min + bufferRadius, max: bounds.max - bufferRadius)
        triangles = []
        portals = []
        trianglePortals = []
        guard floor.size.x > 0, floor.size.y > 0 else { return }

        let padded = paddedObstacles.map { $0.points.map { SIMD2<Double>($0) } }
        let box = (min: SIMD2<Double>(floor.min), max: SIMD2<Double>(floor.max))
        func isWalkable(_ p: SIMD2<Double>) -> Bool {
            let eps = 1e-4
            guard p.x >= box.min.x - eps, p.x <= box.max.x + eps, p.y >= box.min.y - eps, p.y <= box.max.y + eps else { return false }
            return !padded.contains { polygonContains($0, p) }
        }

        // Every wall of the floor, split where walls cross, keeping only pieces
        // that border somewhere walkable.
        let corners: [SIMD2<Double>] = [box.min, [box.max.x, box.min.y], box.max, [box.min.x, box.max.y]]
        var walls: [(SIMD2<Double>, SIMD2<Double>)] = zip(corners, corners.dropFirst() + [corners[0]]).map { ($0, $1) }
        for outline in padded {
            walls += zip(outline, outline.dropFirst() + [outline[0]]).map { ($0, $1) }
        }
        var pieces: [(SIMD2<Double>, SIMD2<Double>)] = []
        for (i, (a, b)) in walls.enumerated() {
            var stops: [Double] = [0, 1]
            for (j, (c, d)) in walls.enumerated() where j != i {
                if let t = crossing(a, b, c, d) { stops.append(t) }
            }
            stops.sort()
            for (t0, t1) in zip(stops, stops.dropFirst()) where t1 - t0 > 1e-9 {
                let p = a + (b - a) * t0, q = a + (b - a) * t1
                let middle = (p + q) / 2
                let inBox = middle.x >= box.min.x - 1e-4 && middle.x <= box.max.x + 1e-4
                    && middle.y >= box.min.y - 1e-4 && middle.y <= box.max.y + 1e-4
                if inBox, !padded.contains(where: { polygonContains($0, middle) }), distanceSquared(p, q) > 1e-8 {
                    pieces.append((p, q))
                }
            }
        }
        guard !pieces.isEmpty else { return }

        // Triangulate, splitting walls until every piece is a triangle edge.
        var mesh = Delaunay(around: box)
        var constraints: [(Int, Int)] = pieces.map { (mesh.insert($0.0), mesh.insert($0.1)) }
        var budget = 4000
        while budget > 0 {
            let present = mesh.edgeSet()
            var next: [(Int, Int)] = []
            var changed = false
            for (u, v) in constraints {
                if u == v || present.contains(EdgeKey(u, v)) {
                    next.append((u, v))
                    continue
                }
                let p = mesh.points[u], q = mesh.points[v]
                guard distanceSquared(p, q) > 1e-6, budget > 0 else {
                    next.append((u, v))
                    continue
                }
                // A vertex already on the wall splits it; otherwise add its midpoint.
                let split = mesh.points.indices.first { k in
                    k >= 3 && k != u && k != v && onSegment(mesh.points[k], p, q)
                } ?? mesh.insert((p + q) / 2)
                budget -= 1
                changed = true
                next += [(u, split), (split, v)]
            }
            constraints = next
            if !changed { break }
        }

        // Every wall is now an edge, so each triangle is entirely on or off the floor.
        var kept: [(Int, Int, Int)] = []
        for (a, b, c) in mesh.triangles where a >= 3 && b >= 3 && c >= 3 {
            let pa = mesh.points[a], pb = mesh.points[b], pc = mesh.points[c]
            guard cross(pb - pa, pc - pa) > 1e-9, isWalkable((pa + pb + pc) / 3) else { continue }
            kept.append((a, b, c))
        }
        triangles = kept.map { Triangle(SIMD2<Float>(mesh.points[$0.0]), SIMD2<Float>(mesh.points[$0.1]), SIMD2<Float>(mesh.points[$0.2])) }

        var owner: [EdgeKey: (triangle: Int, from: Int)] = [:]
        trianglePortals = Array(repeating: [], count: kept.count)
        for (index, (a, b, c)) in kept.enumerated() {
            for (u, v) in [(a, b), (b, c), (c, a)] {
                let key = EdgeKey(u, v)
                if let other = owner[key] {
                    trianglePortals[index].append(portals.count)
                    trianglePortals[other.triangle].append(portals.count)
                    portals.append(Portal(
                        a: SIMD2<Float>(mesh.points[other.from]),
                        b: SIMD2<Float>(mesh.points[other.from == u ? v : u]),
                        left: other.triangle,
                        right: index
                    ))
                } else {
                    owner[key] = (index, u)
                }
            }
        }
    }
}

// MARK: - Triangulation

/// An undirected edge between two vertex indices.
private struct EdgeKey: Hashable {
    let low: Int
    let high: Int
    init(_ a: Int, _ b: Int) {
        low = min(a, b)
        high = max(a, b)
    }
}

/// Bowyer–Watson Delaunay triangulation in doubles. The first three points are
/// a huge triangle around everything, dropped at the end.
private struct Delaunay {
    var points: [SIMD2<Double>]
    var triangles: [(Int, Int, Int)]
    private var circles: [(center: SIMD2<Double>, radiusSquared: Double)]

    init(around box: (min: SIMD2<Double>, max: SIMD2<Double>)) {
        let center = (box.min + box.max) / 2
        let extent = max(box.max.x - box.min.x, box.max.y - box.min.y, 1) * 100
        points = [center + [-extent, -extent], center + [extent, -extent], center + [0, extent]]
        triangles = [(0, 1, 2)]
        circles = []
        circles = [circle(0, 1, 2)]
    }

    func edgeSet() -> Set<EdgeKey> {
        var set: Set<EdgeKey> = []
        for (a, b, c) in triangles {
            set.insert(EdgeKey(a, b))
            set.insert(EdgeKey(b, c))
            set.insert(EdgeKey(c, a))
        }
        return set
    }

    /// Adds `point`, or returns the vertex already there.
    mutating func insert(_ point: SIMD2<Double>) -> Int {
        if let existing = points.indices.first(where: { distanceSquared(points[$0], point) < 1e-10 }) { return existing }
        let index = points.count
        points.append(point)

        var bad: [Int] = []
        for (t, circle) in circles.enumerated() where distanceSquared(circle.center, point) < circle.radiusSquared * (1 + 1e-12) {
            bad.append(t)
        }
        // The cavity's outline: edges of bad triangles that only one of them has.
        var count: [EdgeKey: Int] = [:]
        var directed: [(Int, Int)] = []
        for t in bad {
            let (a, b, c) = triangles[t]
            for (u, v) in [(a, b), (b, c), (c, a)] {
                count[EdgeKey(u, v), default: 0] += 1
                directed.append((u, v))
            }
        }
        for t in bad.reversed() {
            triangles.swapAt(t, triangles.count - 1)
            circles.swapAt(t, circles.count - 1)
            triangles.removeLast()
            circles.removeLast()
        }
        for (u, v) in directed where count[EdgeKey(u, v)] == 1 {
            triangles.append((u, v, index))
            circles.append(circle(u, v, index))
        }
        return index
    }

    private func circle(_ a: Int, _ b: Int, _ c: Int) -> (center: SIMD2<Double>, radiusSquared: Double) {
        let pa = points[a], pb = points[b], pc = points[c]
        let ab = pb - pa, ac = pc - pa
        let d = 2 * (ab.x * ac.y - ab.y * ac.x)
        guard abs(d) > 1e-18 else { return (pa, .infinity) }
        let abSquared = ab.x * ab.x + ab.y * ab.y
        let acSquared = ac.x * ac.x + ac.y * ac.y
        let offset = SIMD2(ac.y * abSquared - ab.y * acSquared, ab.x * acSquared - ac.x * abSquared) / d
        return (pa + offset, offset.x * offset.x + offset.y * offset.y)
    }
}

// MARK: - Double helpers

private func distanceSquared(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
    let d = a - b
    return d.x * d.x + d.y * d.y
}

private func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.y - a.y * b.x }

/// Where `c`–`d` meets `a`–`b`, as a fraction of the way from `a` to `b`
/// strictly between the ends, or `nil` if they don't meet or are parallel.
private func crossing(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, _ d: SIMD2<Double>) -> Double? {
    let r = b - a, s = d - c
    let denominator = cross(r, s)
    guard abs(denominator) > 1e-12 else { return nil }
    let t = cross(c - a, s) / denominator
    let u = cross(c - a, r) / denominator
    let eps = 1e-9
    guard t > eps, t < 1 - eps, u >= -eps, u <= 1 + eps else { return nil }
    return t
}

/// Whether `p` lies on segment `a`–`b`, strictly between its ends.
private func onSegment(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Bool {
    let ab = b - a
    let lengthSquared = ab.x * ab.x + ab.y * ab.y
    guard lengthSquared > 0 else { return false }
    let t = ((p - a).x * ab.x + (p - a).y * ab.y) / lengthSquared
    guard t > 1e-9, t < 1 - 1e-9 else { return false }
    return distanceSquared(a + ab * t, p) < 1e-8
}

/// Whether `p` is strictly inside the polygon, more than a hair from its outline.
private func polygonContains(_ polygon: [SIMD2<Double>], _ p: SIMD2<Double>) -> Bool {
    var inside = false
    for (a, b) in zip(polygon, polygon.dropFirst() + [polygon[0]]) {
        if onSegment(p, a, b) || distanceSquared(p, a) < 1e-8 { return false }
        if (a.y > p.y) != (b.y > p.y) {
            let x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
            if p.x < x { inside.toggle() }
        }
    }
    return inside
}
