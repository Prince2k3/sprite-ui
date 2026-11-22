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

/// Every leg of `path` keeps at least `radius` (minus a hair) from every obstacle.
private func keepsClear(_ path: [SIMD2<Float>], of obstacles: [PolygonObstacle], by radius: Float) -> Bool {
    for (a, b) in zip(path, path.dropFirst()) {
        for step in 0...100 {
            let point = a + (b - a) * (Float(step) / 100)
            if obstacles.contains(where: { $0.distance(to: point) < radius - 0.05 }) { return false }
        }
    }
    return true
}

@Suite struct PolygonObstacleTests {
    @Test func storesCornersCounterClockwise() {
        let clockwise = PolygonObstacle(points: [[0, 0], [0, 10], [10, 10], [10, 0]])
        #expect(clockwise.area == 100)
        #expect(clockwise.points.indices.allSatisfy(clockwise.isConvex(at:)))
    }

    @Test func dropsRepeatedCorners() {
        let polygon = PolygonObstacle(points: [[0, 0], [0, 0], [10, 0], [10, 10], [0, 10], [0, 0]])
        #expect(polygon.points.count == 4)
    }

    @Test func edgesAreOutside() {
        let square = box(0, 0, 10, 10)
        #expect(square.contains([5, 5]))
        #expect(!square.contains([10, 5]), "on the edge")
        #expect(!square.contains([0, 0]), "on a corner")
        #expect(!square.contains([11, 5]))
    }

    @Test func handlesConcaveShapes() {
        // An L: the notch at the top right is outside.
        let l = PolygonObstacle(points: [[0, 0], [20, 0], [20, 10], [10, 10], [10, 20], [0, 20]])
        #expect(l.contains([5, 15]))
        #expect(l.contains([15, 5]))
        #expect(!l.contains([15, 15]))
        #expect(!l.isConvex(at: 3), "the inside corner")
        #expect(l.area == 300)
    }

    @Test func measuresDistance() {
        let square = box(0, 0, 10, 10)
        #expect(square.distance(to: [13, 5]) == 3)
        #expect(square.distance(to: [13, 14]) == 5)
        #expect(square.distance(to: [5, 5]) == 0)
        #expect(square.signedDistance(to: [5, 8]) == -2)
        #expect(square.closestPoint(to: [5, 30]) == [5, 10])
    }

    @Test func inflatesSquareCornersByTheMiter() {
        let grown = box(0, 0, 10, 10).inflated(by: 2)
        #expect(grown.boundingBox == BoundingBox(min: [-2, -2], max: [12, 12]))
        #expect(grown.points.count == 4)
    }

    @Test func inflatedSharpCornersCoverTheCircleWithoutASpike() {
        let spike = PolygonObstacle(points: [[0, 0], [100, 5], [0, 10]])
        let radius: Float = 4
        let grown = spike.inflated(by: radius)
        #expect(grown.points.count > 3, "the sharp tip is cut off")
        #expect(grown.boundingBox.max.x < 100 + radius * 1.5)
        // Every point just under `radius` from the original is inside the padding.
        for angle in stride(from: Float(0), to: 2 * .pi, by: 0.1) {
            let point = SIMD2<Float>(100, 5) + SIMD2(cos(angle), sin(angle)) * (radius - 0.01)
            #expect(grown.contains(point) || spike.contains(point))
        }
    }

    @Test func inflatingAConcaveShapeKeepsTheNotch() {
        let l = PolygonObstacle(points: [[0, 0], [20, 0], [20, 10], [10, 10], [10, 20], [0, 20]])
        let grown = l.inflated(by: 1)
        #expect(grown.contains([10.5, 10.5]))
        #expect(!grown.contains([11.5, 11.5]), "the inside corner moves out by exactly the radius")
    }

    @Test func segmentsThroughTheInsideIntersect() {
        let square = box(0, 0, 10, 10)
        #expect(square.intersects(segmentFrom: [-5, 5], to: [15, 5]))
        #expect(!square.intersects(segmentFrom: [-5, 10], to: [15, 10]), "sliding along an edge")
        #expect(!square.intersects(segmentFrom: [-5, -5], to: [0, 0]), "touching a corner")
        #expect(square.intersects(segmentFrom: [0, 0], to: [10, 10]), "corner to corner through the middle")
        #expect(square.intersects(segmentFrom: [2, 2], to: [3, 3]), "entirely inside")
        #expect(!square.intersects(segmentFrom: [0, 0], to: [10, 0]), "an edge itself")
    }
}

@Suite struct ObstacleGraphTests {
    @Test func walksStraightWhenNothingIsInTheWay() {
        let graph = ObstacleGraph(obstacles: [box(0, 0, 10, 10)], bufferRadius: 1)
        #expect(graph.findPath(from: [-20, -20], to: [-20, 40]) == [[-20, -20], [-20, 40]])
    }

    @Test func goesAroundTheNearCorner() {
        // A wall from x 0…100 at y 40…60; the gap to its left is shorter.
        let wall = box(0, 40, 100, 60)
        let graph = ObstacleGraph(obstacles: [wall], bufferRadius: 5)
        let path = try! #require(graph.findPath(from: [20, 0], to: [20, 100]))
        #expect(path.count == 4)
        #expect(path[1] == [-5, 35] && path[2] == [-5, 65])
        #expect(keepsClear(path, of: [wall], by: 5))
        #expect(abs(length(path) - (magnitude([25, 35]) + 30 + magnitude([25, 35]))) < 0.01)
    }

    @Test func takesTheShortestOfSeveralRoutes() {
        let obstacles = [box(-50, -10, -5, 10), box(5, -10, 30, 10), box(-10, 30, 10, 50)]
        let graph = ObstacleGraph(obstacles: obstacles, bufferRadius: 2)
        let path = try! #require(graph.findPath(from: [0, -40], to: [0, 80]))
        #expect(keepsClear(path, of: obstacles, by: 2))
        // Through the 10-wide slot between the first two, then round the third.
        #expect(path.contains([3, 12]) || path.contains([-3, 12]))
        #expect(length(path) < 130)
    }

    @Test func pathsNeverCrossPaddedObstacles() {
        var rng = SeededGenerator(seed: 3)
        var obstacles: [PolygonObstacle] = []
        for _ in 0..<8 {
            let center = SIMD2(Float.random(in: -200...200, using: &rng), Float.random(in: -200...200, using: &rng))
            obstacles.append(PolygonObstacle(center: center, size: [Float.random(in: 20...80, using: &rng), 20],
                                             rotation: Float.random(in: 0...3, using: &rng)))
        }
        let graph = ObstacleGraph(obstacles: obstacles, bufferRadius: 6)
        var found = 0
        for _ in 0..<30 {
            let a = SIMD2(Float.random(in: -260...260, using: &rng), Float.random(in: -260...260, using: &rng))
            let b = SIMD2(Float.random(in: -260...260, using: &rng), Float.random(in: -260...260, using: &rng))
            guard graph.isWalkable(a), graph.isWalkable(b) else { continue }
            guard let path = graph.findPath(from: a, to: b) else { continue }
            found += 1
            #expect(path.first == a && path.last == b)
            #expect(keepsClear(path, of: obstacles, by: 6))
        }
        #expect(found > 15)
    }

    @Test func aGapNarrowerThanTheUnitIsClosed() {
        // Two walls with a 10-wide gap between x = -5 and 5, and a long way round.
        let left = box(-200, 0, -5, 20), right = box(5, 0, 200, 20)
        let narrow = ObstacleGraph(obstacles: [left, right], bufferRadius: 6)
        let thin = ObstacleGraph(obstacles: [left, right], bufferRadius: 4)

        let squeezed = try! #require(thin.findPath(from: [0, -30], to: [0, 50]))
        #expect(squeezed.count == 2, "a radius-4 unit fits straight through")

        let around = try! #require(narrow.findPath(from: [0, -30], to: [0, 50]))
        #expect(around.count > 2)
        #expect(around.contains { abs($0.x) > 200 }, "a radius-6 unit has to go around the end")
        #expect(keepsClear(around, of: [left, right], by: 6))
    }

    @Test func sealedRoomsAreUnreachable() {
        // Four walls with no door.
        let walls = [box(-50, -50, 50, -40), box(-50, 40, 50, 50), box(-50, -40, -40, 40), box(40, -40, 50, 40)]
        let graph = ObstacleGraph(obstacles: walls, bufferRadius: 3)
        #expect(graph.findPath(from: [0, 0], to: [100, 0]) == nil)
        #expect(graph.findPath(from: [0, 0], to: [20, 20])?.count == 2)
    }

    @Test func goalsInsideObstaclesAreRefused() {
        let graph = ObstacleGraph(obstacles: [box(0, 0, 10, 10)], bufferRadius: 3)
        #expect(graph.findPath(from: [-20, 5], to: [5, 5]) == nil)
        #expect(graph.findPath(from: [-20, 5], to: [11, 5]) == nil, "inside the padding")
    }

    @Test func aUnitInsideThePaddingCanLeave() {
        let wall = box(0, 0, 100, 10)
        let graph = ObstacleGraph(obstacles: [wall], bufferRadius: 5)
        let path = try! #require(graph.findPath(from: [50, 12], to: [50, 40]))
        #expect(path == [[50, 12], [50, 40]])
        let around = try! #require(graph.findPath(from: [50, 12], to: [50, -40]))
        #expect(around.count > 2)
    }

    @Test func movingAnObstacleUpdatesTheGraph() {
        var graph = ObstacleGraph(obstacles: [box(-10, 20, 10, 40)], bufferRadius: 2)
        let blocked = try! #require(graph.findPath(from: [0, 0], to: [0, 60]))
        #expect(blocked.count > 2)

        graph.obstacles[0] = box(90, 20, 110, 40)
        #expect(graph.findPath(from: [0, 0], to: [0, 60])?.count == 2)
        #expect(graph.nodes.allSatisfy { $0.x > 80 })
    }

    @Test func addingAndRemovingObstaclesUpdatesTheGraph() {
        var graph = ObstacleGraph(bufferRadius: 2)
        #expect(graph.nodes.isEmpty)
        #expect(graph.findPath(from: [0, 0], to: [0, 60])?.count == 2)

        graph.obstacles.append(box(-10, 20, 10, 40))
        #expect(graph.nodes.count == 4)
        #expect((graph.findPath(from: [0, 0], to: [0, 60])?.count ?? 0) > 2)

        graph.obstacles.removeAll()
        #expect(graph.nodes.isEmpty)
        #expect(graph.findPath(from: [0, 0], to: [0, 60])?.count == 2)
    }

    @Test func changingTheRadiusRebuilds() {
        var graph = ObstacleGraph(obstacles: [box(0, 0, 10, 10)], bufferRadius: 1)
        #expect(graph.nodes.contains([-1, -1]))
        graph.bufferRadius = 3
        #expect(graph.nodes.contains([-3, -3]))
        #expect(!graph.nodes.contains([-1, -1]))
    }

    @Test func cornersBuriedInOtherPaddingAreDropped() {
        // A taller box 2 to the right swallows the first box's right-hand padded corners.
        let graph = ObstacleGraph(obstacles: [box(0, 0, 10, 10), box(12, -5, 22, 15)], bufferRadius: 3)
        #expect(graph.nodes.count == 6)
        #expect(!graph.nodes.contains([13, -3]))
        #expect(!graph.nodes.contains([13, 13]))
    }

    @Test func connectionsAreMutual() {
        let graph = ObstacleGraph(obstacles: [box(0, 0, 10, 10), box(30, 0, 40, 10)], bufferRadius: 2)
        for (a, b) in graph.connections {
            #expect(graph.neighbors(of: a).contains { $0.to == b })
            #expect(graph.neighbors(of: b).contains { $0.to == a })
            #expect(graph.isClear(from: a, to: b))
        }
        #expect(!graph.connections.isEmpty)
    }

    @Test func sameObstaclesSamePath() {
        let obstacles = [box(-30, 10, 30, 20), box(-10, 40, 50, 50)]
        let a = ObstacleGraph(obstacles: obstacles, bufferRadius: 4)
        let b = ObstacleGraph(obstacles: obstacles, bufferRadius: 4)
        #expect(a.findPath(from: [0, 0], to: [0, 80]) == b.findPath(from: [0, 0], to: [0, 80]))
    }
}

@Suite struct PolygonAvoidanceTests {
    @Test func turnsAwayFromAWallAhead() {
        let wall = box(-50, 30, 50, 40)
        let agent = SteeringAgent(position: [0, 0], velocity: [0, 60], maxSpeed: 60, maxForce: 100, radius: 10)
        let force = Steering.avoid(agent, polygons: [wall], lookAhead: 0.5)
        #expect(force.y < 0, "pushes back from the wall")
    }

    @Test func ignoresWallsItIsNotHeadingFor() {
        let wall = box(-50, 30, 50, 40)
        let agent = SteeringAgent(position: [0, 0], velocity: [0, -60], maxSpeed: 60, maxForce: 100, radius: 10)
        #expect(Steering.avoid(agent, polygons: [wall], lookAhead: 0.5) == .zero)
    }

    @Test func pushesAnOverlappingAgentOut() {
        let wall = box(-50, 0, 50, 10)
        let agent = SteeringAgent(position: [0, 14], velocity: .zero, maxSpeed: 60, maxForce: 100, radius: 10)
        let force = Steering.avoid(agent, polygons: [wall])
        #expect(force.y > 0 && abs(force.x) < 1e-3)
    }

    @Test func neverDrivesIntoAWall() {
        // Head straight at a wall with avoidance only; the agent must stop short of it.
        let wall = box(-100, 50, 100, 60)
        var agent = SteeringAgent(position: [0, 0], velocity: [0, 80], maxSpeed: 80, maxForce: 200, radius: 8)
        for _ in 0..<240 {
            agent.apply(Steering.avoid(agent, polygons: [wall]), deltaTime: 1 / 60)
            #expect(wall.distance(to: agent.position) > 0)
        }
    }
}

@MainActor @Suite(.serialized) struct PolygonObstacleComponentTests {
    @Test func outlineFollowsTheEntityAndItsParents() {
        let world = World()
        let room = Entity()
        room.position = [100, 0]
        room.transform.rotation = .pi / 2
        let crate = Entity()
        crate.position = [10, 0]
        crate.transform.scale = [2, 2]
        crate.components.set(PolygonObstacleComponent(rectangle: [10, 4]))
        room.addChild(crate)
        world.addEntity(room)

        let outline = try! #require(crate.sceneObstacle)
        // 20 × 8 after scaling, turned a quarter so it's 8 wide and 20 tall, at (100, 10).
        let bounds = outline.boundingBox
        #expect(abs(bounds.min.x - 96) < 1e-3 && abs(bounds.max.x - 104) < 1e-3)
        #expect(abs(bounds.min.y - 0) < 1e-3 && abs(bounds.max.y - 20) < 1e-3)
        #expect(world.polygonObstacles.count == 1)
    }

    @Test func worldGraphRoutesAroundObstacleEntities() {
        let world = World()
        let wall = Entity()
        wall.position = [0, 50]
        wall.components.set(PolygonObstacleComponent(rectangle: [100, 10]))
        world.addEntity(wall)

        let graph = world.obstacleGraph(bufferRadius: 5)
        let path = try! #require(graph.findPath(from: [0, 0], to: [0, 100]))
        #expect(path.count == 4)

        wall.position = [500, 50]
        #expect(world.obstacleGraph(bufferRadius: 5).findPath(from: [0, 0], to: [0, 100])?.count == 2)
    }

    @Test func steeringAvoidsPolygonEntities() {
        let world = World()
        world.addSystem(SteeringSystem.self)
        let wall = Entity()
        wall.position = [100, 0]
        wall.components.set(PolygonObstacleComponent(rectangle: [10, 200]))
        world.addEntity(wall)
        let mover = Entity()
        mover.components.set(SteeringComponent(maxSpeed: 100, maxForce: 400, radius: 8, goals: [
            SteeringGoal(.seek(.point([300, 0]))),
            SteeringGoal(.avoidObstacles(), weight: 3),
        ]))
        world.addEntity(mover)
        let outline = try! #require(wall.sceneObstacle)
        for _ in 0..<300 {
            world.update(deltaTime: 1 / 60)
            #expect(outline.distance(to: mover.position) > 0)
        }
    }
}
