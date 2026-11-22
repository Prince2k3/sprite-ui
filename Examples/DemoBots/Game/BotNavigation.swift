import Foundation
import SpriteUI
import simd

/// A conservative raster of the original level's polygon obstacles. A* and
/// string smoothing come from SpriteUI; the game owns its level-specific cache.
struct BotNavigation {
    var bounds: BoundingBox
    var obstacles: [PolygonObstacle]
    var padded: [PolygonObstacle]
    var grid: GridGraph
    var space: GridSpace

    init(bounds: BoundingBox, obstacles: [PolygonObstacle], radius: Float = 25) {
        self.bounds = bounds
        self.obstacles = obstacles
        padded = obstacles.map { $0.inflated(by: radius) }
        let cell: Float = 32
        grid = GridGraph(width: max(1, Int(ceil(bounds.size.x / cell))), height: max(1, Int(ceil(bounds.size.y / cell))))
        space = GridSpace(cellSize: cell, origin: bounds.min + SIMD2(repeating: cell / 2))
        for point in grid.points {
            let position = space.position(of: point)
            let blocked = !bounds.contains(position) || obstacles.contains {
                $0.boundingBox.intersects(circleAt: position, radius: radius + 16) && $0.signedDistance(to: position) < radius + 16
            }
            grid.setWalkable(!blocked, at: point)
        }
    }

    func isClear(from start: SIMD2<Float>, to end: SIMD2<Float>) -> Bool {
        !padded.contains { $0.intersects(segmentFrom: start, to: end) }
    }

    func nearestCell(to position: SIMD2<Float>) -> GridPoint? {
        let cell = space.point(at: position)
        if grid.isWalkable(cell) { return cell }
        var best: GridPoint?
        var distance = Float.infinity
        for y in (cell.y - 4)...(cell.y + 4) {
            for x in (cell.x - 4)...(cell.x + 4) {
                let p = GridPoint(x, y)
                guard grid.isWalkable(p) else { continue }
                let d = simd_distance_squared(position, space.position(of: p))
                if d < distance && isClear(from: position, to: space.position(of: p)) { best = p; distance = d }
            }
        }
        return best
    }

    func path(from start: SIMD2<Float>, to end: SIMD2<Float>) -> [SIMD2<Float>] {
        if isClear(from: start, to: end) { return [start, end] }
        guard let a = nearestCell(to: start), let b = nearestCell(to: end),
              let cells = grid.findPath(from: a, to: b) else { return [] }
        var route = [start] + space.positions(along: grid.smoothed(cells))
        if let last = route.last, isClear(from: last, to: end) { route.append(end) }
        return route
    }

    /// Sweep in small steps, then slide along walls. Steering remains the source
    /// of motion; this prevents even a fast charge from tunneling through a wall.
    func move(from start: SIMD2<Float>, toward end: SIMD2<Float>, radius: Float = 25) -> SIMD2<Float> {
        let delta = end - start
        let steps = max(1, Int(ceil(simd_length(delta) / 8)))
        var result = start
        for _ in 0..<steps {
            var next = result + delta / Float(steps)
            next = simd_clamp(next, bounds.min + SIMD2(repeating: radius), bounds.max - SIMD2(repeating: radius))
            for _ in 0..<3 {
                for obstacle in obstacles where obstacle.boundingBox.intersects(circleAt: next, radius: radius) {
                    let distance = obstacle.signedDistance(to: next)
                    guard distance < radius else { continue }
                    let edge = obstacle.closestPoint(to: next)
                    var outward = distance < 0 ? edge - next : next - edge
                    if simd_length_squared(outward) < 0.0001 { outward = edge - obstacle.boundingBox.center }
                    if simd_length_squared(outward) > 0 { next = edge + simd_normalize(outward) * (radius + 0.1) }
                }
            }
            result = next
        }
        return result
    }
}
