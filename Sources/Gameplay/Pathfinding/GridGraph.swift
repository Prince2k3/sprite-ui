/// A cell in a ``GridGraph``. `(0, 0)` is the bottom-left cell, with +y up like the scene.
public struct GridPoint: Hashable, Codable, Sendable, CustomStringConvertible {
    public var x: Int
    public var y: Int

    public init(_ x: Int, _ y: Int) {
        self.x = x
        self.y = y
    }

    public init(x: Int, y: Int) {
        self.init(x, y)
    }

    public var description: String { "(\(x), \(y))" }

    public static func + (lhs: GridPoint, rhs: GridPoint) -> GridPoint {
        GridPoint(lhs.x + rhs.x, lhs.y + rhs.y)
    }
}

/// A grid of walkable and blocked cells.
///
/// It's a plain value: no node objects to create, connect or remove.
///
/// ```swift
/// var grid = GridGraph(width: 10, height: 8)
/// grid.setWalkable(false, at: GridPoint(4, 3))
/// let path = grid.findPath(from: GridPoint(0, 0), to: GridPoint(9, 7))
/// let corners = grid.smoothed(path ?? [])
/// ```
///
/// Diagonal steps cost √2 and never cut past a blocked cell's corner.
public struct GridGraph: Graph, Hashable, Codable, Sendable {
    public let width: Int
    public let height: Int
    /// Whether paths may step diagonally.
    public var allowsDiagonals: Bool

    private var blocked: [Bool]
    private var costs: [Float]

    /// A grid where every cell is walkable and costs 1 to enter.
    public init(width: Int, height: Int, allowsDiagonals: Bool = true) {
        precondition(width > 0 && height > 0, "A grid needs at least one cell.")
        self.width = width
        self.height = height
        self.allowsDiagonals = allowsDiagonals
        blocked = Array(repeating: false, count: width * height)
        costs = Array(repeating: 1, count: width * height)
    }

    /// Whether `point` is inside the grid.
    public func contains(_ point: GridPoint) -> Bool {
        point.x >= 0 && point.y >= 0 && point.x < width && point.y < height
    }

    /// Whether `point` is inside the grid and not blocked.
    public func isWalkable(_ point: GridPoint) -> Bool {
        contains(point) && !blocked[index(point)]
    }

    public mutating func setWalkable(_ walkable: Bool, at point: GridPoint) {
        precondition(contains(point), "\(point) is outside the \(width)×\(height) grid.")
        blocked[index(point)] = !walkable
    }

    /// What it costs to step onto `point`, such as 3 for mud. At least 1.
    public func cost(at point: GridPoint) -> Float {
        costs[index(point)]
    }

    /// Sets what it costs to step onto `point`. Costs are at least 1, so the
    /// distance estimate A* uses stays accurate.
    public mutating func setCost(_ cost: Float, at point: GridPoint) {
        precondition(cost >= 1, "Cell costs start at 1.")
        costs[index(point)] = cost
    }

    /// Every cell, row by row from the bottom.
    public var points: [GridPoint] {
        (0..<height).flatMap { y in (0..<width).map { x in GridPoint(x, y) } }
    }

    private func index(_ point: GridPoint) -> Int { point.y * width + point.x }

    // MARK: Graph

    private static let straight = [GridPoint(1, 0), GridPoint(0, 1), GridPoint(-1, 0), GridPoint(0, -1)]
    private static let diagonal = [GridPoint(1, 1), GridPoint(-1, 1), GridPoint(-1, -1), GridPoint(1, -1)]

    public func neighbors(of point: GridPoint) -> [GraphEdge<GridPoint>] {
        var edges: [GraphEdge<GridPoint>] = []
        for step in Self.straight {
            let next = point + step
            if isWalkable(next) { edges.append(GraphEdge(to: next, cost: cost(at: next))) }
        }
        guard allowsDiagonals else { return edges }
        for step in Self.diagonal {
            let next = point + step
            // Both cells beside the diagonal must be open, so paths don't clip corners.
            if isWalkable(next),
               isWalkable(GridPoint(point.x + step.x, point.y)),
               isWalkable(GridPoint(point.x, point.y + step.y)) {
                edges.append(GraphEdge(to: next, cost: cost(at: next) * Float(2).squareRoot()))
            }
        }
        return edges
    }

    /// Octile distance with diagonals, Manhattan without.
    public func estimatedCost(from point: GridPoint, to goal: GridPoint) -> Float {
        let dx = Float(abs(goal.x - point.x)), dy = Float(abs(goal.y - point.y))
        guard allowsDiagonals else { return dx + dy }
        return max(dx, dy) + (Float(2).squareRoot() - 1) * min(dx, dy)
    }

    // MARK: Smoothing

    /// Whether a straight line between the centers of `a` and `b` crosses only
    /// walkable cells. A line through a corner needs both cells beside it open.
    public func hasLineOfSight(from a: GridPoint, to b: GridPoint) -> Bool {
        guard isWalkable(a), isWalkable(b) else { return false }
        let nx = abs(b.x - a.x), ny = abs(b.y - a.y)
        let sx = b.x > a.x ? 1 : -1, sy = b.y > a.y ? 1 : -1
        var x = a.x, y = a.y
        var ix = 0, iy = 0
        while ix < nx || iy < ny {
            // Which cell edge the line crosses next, compared without division.
            let decision = (1 + 2 * ix) * ny - (1 + 2 * iy) * nx
            if decision == 0 {
                guard isWalkable(GridPoint(x + sx, y)), isWalkable(GridPoint(x, y + sy)) else { return false }
                x += sx; y += sy; ix += 1; iy += 1
            } else if decision < 0 {
                x += sx; ix += 1
            } else {
                y += sy; iy += 1
            }
            if !isWalkable(GridPoint(x, y)) { return false }
        }
        return true
    }

    /// `path` with every cell dropped that a straight line can skip, leaving just
    /// the corners. Cell costs are ignored: only walls are avoided.
    public func smoothed(_ path: [GridPoint]) -> [GridPoint] {
        guard path.count > 2 else { return path }
        var result = [path[0]]
        var anchor = path[0]
        for i in 2..<path.count where !hasLineOfSight(from: anchor, to: path[i]) {
            anchor = path[i - 1]
            result.append(anchor)
        }
        result.append(path[path.count - 1])
        return result
    }
}

/// Places a grid in the scene: where each cell's center is.
///
/// ```swift
/// let space = GridSpace(cellSize: 40, centering: grid)
/// enemy.follow(space.positions(along: path), speed: 120)
/// ```
public struct GridSpace: Hashable, Codable, Sendable {
    /// The width and height of one cell, in points.
    public var cellSize: Float
    /// The scene position of the center of cell `(0, 0)`.
    public var origin: SIMD2<Float>

    public init(cellSize: Float, origin: SIMD2<Float> = .zero) {
        self.cellSize = cellSize
        self.origin = origin
    }

    /// A space that puts the middle of `grid` at the scene's origin.
    public init(cellSize: Float, centering grid: GridGraph) {
        let size = SIMD2(Float(grid.width - 1), Float(grid.height - 1)) * cellSize
        self.init(cellSize: cellSize, origin: -size / 2)
    }

    /// The scene position of the center of `point`.
    public func position(of point: GridPoint) -> SIMD2<Float> {
        origin + SIMD2(Float(point.x), Float(point.y)) * cellSize
    }

    /// The cell containing a scene position. It may be outside the grid.
    public func point(at position: SIMD2<Float>) -> GridPoint {
        let cell = ((position - origin) / cellSize).rounded(.toNearestOrAwayFromZero)
        return GridPoint(Int(cell.x), Int(cell.y))
    }

    /// The scene positions of each cell in `path`.
    public func positions(along path: [GridPoint]) -> [SIMD2<Float>] {
        path.map(position(of:))
    }
}
