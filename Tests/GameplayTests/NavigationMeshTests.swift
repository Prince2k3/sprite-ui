import ECSCore
import Foundation
@testable import Gameplay
import GameplayECS
import Testing

private func box(_ minX: Float, _ minY: Float, _ maxX: Float, _ maxY: Float) -> PolygonObstacle {
    PolygonObstacle(BoundingBox(min: [minX, minY], max: [maxX, maxY]))
}

private func length(_ path: [SIMD2<Float>]) -> Float {
    zip(path, path.dropFirst()).reduce(0) { $0 + magnitude($1.1 - $1.0) }
}

/// No point along `path` is inside a padded obstacle or outside the floor.
private func staysOnFloor(_ path: [SIMD2<Float>], _ mesh: NavigationMesh) -> Bool {
    let floor = BoundingBox(min: mesh.bounds.min + mesh.bufferRadius - 0.01, max: mesh.bounds.max - mesh.bufferRadius + 0.01)
    for (a, b) in zip(path, path.dropFirst()) {
        for step in 0...200 {
            let point = a + (b - a) * (Float(step) / 200)
            guard floor.contains(point) else { return false }
            if mesh.paddedObstacles.contains(where: { $0.signedDistance(to: point) < -0.01 }) { return false }
        }
    }
    return true
}

/// A room like the Obstacles demo's: walls, a concave L, two pillars with a narrow gap.
private let room: [PolygonObstacle] = [
    box(-174, 0, -40, 10),
    box(40, -10, 174, 0),
    PolygonObstacle(points: [[-100, -80], [-20, -80], [-20, -60], [-80, -60], [-80, 0], [-100, 0]]),
    box(-174, -200, -110, -170),
    box(-78, -200, -10, -170),          // 32 wide gap to its left
    PolygonObstacle(center: [80, 100], size: [54, 54], rotation: .pi / 5),
]
private let roomBounds = BoundingBox(min: [-174, -250], max: [174, 250])

@Suite struct NavigationMeshTests {
    @Test func emptyRoomIsTheWholeFloor() {
        let mesh = NavigationMesh(bounds: BoundingBox(min: [0, 0], max: [100, 50]))
        #expect(abs(mesh.walkableArea - 5000) < 0.01)
        #expect(mesh.findPath(from: [10, 10], to: [90, 40]) == [[10, 10], [90, 40]])
    }

    @Test func trianglesCoverExactlyTheWalkableArea() {
        for radius: Float in [0, 5, 12] {
            let mesh = NavigationMesh(bounds: roomBounds, obstacles: room, bufferRadius: radius)
            // Grid samples away from any edge agree with the floor's definition.
            for x in stride(from: Float(-173.3), through: 173, by: 7.1) {
                for y in stride(from: Float(-249.1), through: 249, by: 6.7) {
                    let point = SIMD2(x, y)
                    let floor = BoundingBox(min: roomBounds.min + radius, max: roomBounds.max - radius)
                    let distances = mesh.paddedObstacles.map { $0.signedDistance(to: point) }
                    let edge = min(distances.map(abs).min() ?? .infinity,
                                   abs(point.x - floor.min.x), abs(point.x - floor.max.x),
                                   abs(point.y - floor.min.y), abs(point.y - floor.max.y))
                    guard edge > 0.05 else { continue }
                    let expected = floor.contains(point) && distances.allSatisfy { $0 > 0 }
                    #expect(mesh.isWalkable(point) == expected, "radius \(radius) at \(point)")
                }
            }
            // No overlaps: the triangles add up to no more than the floor.
            let floorArea = (roomBounds.size.x - 2 * radius) * (roomBounds.size.y - 2 * radius)
            #expect(mesh.walkableArea <= floorArea + 0.1)
            #expect(mesh.triangles.allSatisfy { $0.area > 0 })
        }
    }

    @Test func areaMatchesForSeparateObstacles() {
        let obstacles = [box(20, 20, 40, 60), PolygonObstacle(center: [120, 50], size: [30, 30], rotation: 0.4)]
        let mesh = NavigationMesh(bounds: BoundingBox(min: [0, 0], max: [200, 100]), obstacles: obstacles, bufferRadius: 4)
        let expected = 192 * 92 - mesh.paddedObstacles.reduce(0) { $0 + $1.area }
        #expect(abs(mesh.walkableArea - expected) < 0.5)
    }

    @Test func pathsStayOffPaddedWalls() {
        let mesh = NavigationMesh(bounds: roomBounds, obstacles: room, bufferRadius: 8)
        var generator = SeededGenerator(seed: 7)
        var found = 0
        for _ in 0..<150 {
            let start = SIMD2(Float.random(in: -165...165, using: &generator), Float.random(in: -240...240, using: &generator))
            let goal = SIMD2(Float.random(in: -165...165, using: &generator), Float.random(in: -240...240, using: &generator))
            guard mesh.isWalkable(start), let path = mesh.findPath(from: start, to: goal) else { continue }
            found += 1
            #expect(path.first == start && path.last == goal)
            #expect(staysOnFloor(path, mesh), "\(start) → \(goal): \(path)")
        }
        #expect(found > 80)
    }

    @Test func pathsAreAboutAsShortAsTheObstacleGraph() {
        let radius: Float = 8
        let mesh = NavigationMesh(bounds: roomBounds, obstacles: room, bufferRadius: radius)
        // The room's outer edge as walls, so the graph has the same floor.
        let outer = [box(-300, 250, 300, 300), box(-300, -300, 300, -250), box(-300, -300, -174, 300), box(174, -300, 300, 300)]
        let graph = ObstacleGraph(obstacles: room + outer, bufferRadius: radius)
        var generator = SeededGenerator(seed: 11)
        var compared = 0
        for _ in 0..<150 {
            let start = SIMD2(Float.random(in: -165...165, using: &generator), Float.random(in: -240...240, using: &generator))
            let goal = SIMD2(Float.random(in: -165...165, using: &generator), Float.random(in: -240...240, using: &generator))
            guard mesh.isWalkable(start), mesh.isWalkable(goal),
                  let meshPath = mesh.findPath(from: start, to: goal),
                  let graphPath = graph.findPath(from: start, to: goal) else { continue }
            compared += 1
            let ratio = length(meshPath) / max(length(graphPath), 1e-3)
            #expect(ratio < 1.2 && ratio > 0.99, "\(start) → \(goal): \(length(meshPath)) vs \(length(graphPath))")
        }
        #expect(compared > 80)
    }

    @Test func narrowGapClosesForWideUnits() {
        let pillars = [box(-100, -20, -16, 20), box(16, -20, 100, 20)]   // 32 wide gap
        let bounds = BoundingBox(min: [-100, -100], max: [100, 100])
        let thin = NavigationMesh(bounds: bounds, obstacles: pillars, bufferRadius: 10)
        let wide = NavigationMesh(bounds: bounds, obstacles: pillars, bufferRadius: 17)
        #expect(thin.findPath(from: [0, -60], to: [0, 60])?.count == 2)
        #expect(wide.findPath(from: [0, -60], to: [0, 60]) == nil)
        #expect(!wide.isWalkable([0, 0]))
    }

    @Test func goalOffTheFloorHasNoPath() {
        let mesh = NavigationMesh(bounds: roomBounds, obstacles: room, bufferRadius: 8)
        #expect(mesh.findPath(from: [100, 200], to: [-90, -40]) == nil)   // inside the L
        #expect(mesh.findPath(from: [100, 200], to: [170, 0]) == nil)     // in the edge padding
    }

    @Test func trappedStartStepsOntoTheFloor() {
        let mesh = NavigationMesh(bounds: BoundingBox(min: [0, 0], max: [100, 100]), obstacles: [box(40, 40, 60, 60)], bufferRadius: 10)
        let path = try! #require(mesh.findPath(from: [50, 33], to: [50, 10]))
        #expect(path.first == [50, 33])
        #expect(abs(path[1].y - 30) < 0.01)
        #expect(path.last == [50, 10])
    }

    @Test func goesAroundAWall() {
        let mesh = NavigationMesh(bounds: BoundingBox(min: [0, 0], max: [100, 100]), obstacles: [box(20, 45, 100, 55)], bufferRadius: 5)
        let path = try! #require(mesh.findPath(from: [80, 20], to: [80, 80]))
        // Around the wall's left end, padded to x = 15.
        #expect(path.count == 4)
        #expect(abs(path[1].x - 15) < 0.01 && abs(path[2].x - 15) < 0.01)
        #expect(staysOnFloor(path, mesh))
    }

    @Test func graphJoinsNeighboringTriangles() {
        let mesh = NavigationMesh(bounds: roomBounds, obstacles: room, bufferRadius: 8)
        for node in mesh.triangles.indices {
            for edge in mesh.neighbors(of: node) {
                #expect(mesh.neighbors(of: edge.to).contains { $0.to == node })
            }
        }
        let from = try! #require(mesh.triangle(containing: [100, 200]))
        let to = try! #require(mesh.triangle(containing: [-150, -230]))
        let corridor = try! #require(mesh.findPath(from: from, to: to))
        #expect(corridor.first == from && corridor.last == to)
    }

    @Test func rebuildsWhenObstaclesChange() {
        var mesh = NavigationMesh(bounds: BoundingBox(min: [0, 0], max: [100, 100]), bufferRadius: 5)
        #expect(mesh.findPath(from: [50, 10], to: [50, 90])?.count == 2)
        mesh.obstacles = [box(0, 45, 100, 55)]
        #expect(mesh.findPath(from: [50, 10], to: [50, 90]) == nil)
        mesh.obstacles = [box(20, 45, 100, 55)]
        #expect(mesh.findPath(from: [50, 10], to: [50, 90])?.count == 4)
        mesh.bufferRadius = 11
        #expect(mesh.findPath(from: [50, 10], to: [50, 90]) == nil)
    }
}

@MainActor @Suite(.serialized) struct NavigationMeshWorldTests {
    @Test func worldMeshFollowsObstacleEntities() {
        let world = World()
        let wall = Entity()
        wall.position = [60, 50]
        wall.components.set(PolygonObstacleComponent(rectangle: [80, 10]))
        world.addEntity(wall)

        let bounds = BoundingBox(min: [0, 0], max: [100, 100])
        let before = world.navigationMesh(bounds: bounds, bufferRadius: 4)
        #expect(before.findPath(from: [80, 20], to: [80, 80])?.count == 4)

        wall.position = [50, 50]
        wall.components[PolygonObstacleComponent.self] = PolygonObstacleComponent(rectangle: [100, 10])
        let after = world.navigationMesh(bounds: bounds, bufferRadius: 4)
        #expect(after.findPath(from: [80, 20], to: [80, 80]) == nil)
    }
}
