import ECSCore
import Foundation
import Gameplay
import GameplayECS
import Testing

/// Builds a grid from rows drawn top to bottom: `#` is a wall, `~` costs 5, anything else is floor.
private func grid(_ rows: [String], diagonals: Bool = true) -> GridGraph {
    var grid = GridGraph(width: rows[0].count, height: rows.count, allowsDiagonals: diagonals)
    for (row, line) in rows.enumerated() {
        for (x, character) in line.enumerated() {
            let point = GridPoint(x, rows.count - 1 - row)
            if character == "#" { grid.setWalkable(false, at: point) }
            if character == "~" { grid.setCost(5, at: point) }
        }
    }
    return grid
}

private func cost(of path: [GridPoint], in grid: GridGraph) -> Float {
    zip(path, path.dropFirst()).reduce(0) { total, step in
        total + grid.neighbors(of: step.0).first { $0.to == step.1 }!.cost
    }
}

@Suite struct PathfindingTests {
    @Test func straightLineOnEmptyGrid() throws {
        let g = GridGraph(width: 5, height: 1)
        let path = try #require(g.findPath(from: GridPoint(0, 0), to: GridPoint(4, 0)))
        #expect(path == (0...4).map { GridPoint($0, 0) })
    }

    @Test func goesAroundWalls() throws {
        let g = grid([
            ".....",
            ".###.",
            ".#...",
            ".#.#.",
            "S#..G",
        ], diagonals: false)
        let path = try #require(g.findPath(from: GridPoint(0, 0), to: GridPoint(4, 0)))
        #expect(path.first == GridPoint(0, 0) && path.last == GridPoint(4, 0))
        #expect(path.allSatisfy(g.isWalkable))
        // Up the left side, across the top, down the right: 4 + 4 + 4 steps.
        #expect(path.count == 13)
        // Every step is to an orthogonal neighbor.
        for (a, b) in zip(path, path.dropFirst()) {
            #expect(abs(a.x - b.x) + abs(a.y - b.y) == 1)
        }
    }

    @Test func noPathWhenWalledOff() {
        let g = grid([
            "..#..",
            "..#..",
        ])
        #expect(g.findPath(from: GridPoint(0, 0), to: GridPoint(4, 1)) == nil)
        #expect(g.findPath(from: GridPoint(0, 0), to: GridPoint(0, 0)) == [GridPoint(0, 0)])
    }

    @Test func diagonalsDontCutCorners() throws {
        let g = grid([
            ".#",
            "..",
        ])
        // (0,0) → (1,1) is open diagonally, but (0,1)…(1,0) squeezes past the wall.
        let path = try #require(g.findPath(from: GridPoint(0, 1), to: GridPoint(1, 0)))
        #expect(path.count == 3)
        #expect(g.neighbors(of: GridPoint(0, 0)).contains { $0.to == GridPoint(1, 1) } == false)
    }

    @Test func avoidsExpensiveTerrain() throws {
        let g = grid([
            ".....",
            ".~~~.",
            "S~~~G",
        ], diagonals: false)
        let path = try #require(g.findPath(from: GridPoint(0, 0), to: GridPoint(4, 0)))
        // Walking around the mud (8 steps) beats wading through it (1 + 5·3).
        #expect(cost(of: path, in: g) == 8)
        #expect(!path.contains(GridPoint(2, 0)))
    }

    @Test func aStarMatchesDijkstra() {
        // A* with the grid's estimate and a plain cost map agree on the cheapest cost.
        var rng = SeededGenerator(seed: 11)
        var g = GridGraph(width: 20, height: 20)
        for point in g.points where rng.chance(0.25) { g.setWalkable(false, at: point) }
        let start = GridPoint(0, 0), map = { g.setWalkable(true, at: start); return g.costMap(from: start) }()
        for goal in g.points where g.isWalkable(goal) {
            let path = g.findPath(from: start, to: goal)
            #expect((path != nil) == (map.cost(to: goal) != nil))
            if let path, let expected = map.cost(to: goal) {
                #expect(abs(cost(of: path, in: g) - expected) < 0.001)
            }
        }
    }

    @Test func costMapStepsTowardNearestSource() throws {
        let g = GridGraph(width: 7, height: 1)
        let map = g.costMap(from: [GridPoint(0, 0), GridPoint(6, 0)])
        #expect(map.cost(to: GridPoint(3, 0)) == 3)
        #expect(map.nextStep(from: GridPoint(5, 0)) == GridPoint(6, 0))
        #expect(map.nextStep(from: GridPoint(1, 0)) == GridPoint(0, 0))
        #expect(map.nextStep(from: GridPoint(0, 0)) == nil)
        #expect(map.path(to: GridPoint(4, 0)) == [GridPoint(6, 0), GridPoint(5, 0), GridPoint(4, 0)])
    }

    @Test func costMapRespectsMaxCost() {
        let g = GridGraph(width: 10, height: 10, allowsDiagonals: false)
        let map = g.costMap(from: GridPoint(5, 5), maxCost: 2)
        // A diamond of radius 2: 1 + 4 + 8 cells.
        #expect(map.nodes.count == 13)
        #expect(map.cost(to: GridPoint(5, 8)) == nil)
    }

    @Test func smoothingKeepsOnlyCorners() throws {
        let g = grid([
            "......",
            "......",
            "####..",
            "S.....",
        ])
        let start = GridPoint(0, 0), goal = GridPoint(0, 3)
        let path = try #require(g.findPath(from: start, to: goal))
        let smooth = g.smoothed(path)
        #expect(smooth.first == start && smooth.last == goal)
        #expect(smooth.count < path.count)
        for (a, b) in zip(smooth, smooth.dropFirst()) {
            #expect(g.hasLineOfSight(from: a, to: b))
        }
    }

    @Test func lineOfSight() {
        let g = grid([
            "...",
            ".#.",
            "...",
        ])
        #expect(g.hasLineOfSight(from: GridPoint(0, 0), to: GridPoint(2, 0)))
        #expect(!g.hasLineOfSight(from: GridPoint(0, 1), to: GridPoint(2, 1)))
        // Exactly through the wall's corner: blocked.
        #expect(!g.hasLineOfSight(from: GridPoint(0, 0), to: GridPoint(2, 2)))
        #expect(g.hasLineOfSight(from: GridPoint(0, 0), to: GridPoint(2, 0)))
    }

    @Test func adjacencyGraph() {
        var roads = AdjacencyGraph<String>()
        roads.connect("camp", "bridge", cost: 4)
        roads.connect("bridge", "castle", cost: 6)
        roads.connect("camp", "forest", cost: 2)
        roads.connect("forest", "castle", cost: 9)
        #expect(roads.findPath(from: "camp", to: "castle") == ["camp", "bridge", "castle"])
        roads.connect("bridge", "castle", cost: 20)
        #expect(roads.findPath(from: "camp", to: "castle") == ["camp", "forest", "castle"])
        roads.remove("forest")
        #expect(roads.findPath(from: "camp", to: "castle") == ["camp", "bridge", "castle"])
        roads.connect("castle", "keep", bidirectional: false)
        #expect(roads.findPath(from: "keep", to: "castle") == nil)
    }

    @Test func gridSpaceRoundTrips() {
        let g = GridGraph(width: 5, height: 3)
        let space = GridSpace(cellSize: 10, centering: g)
        #expect(space.position(of: GridPoint(2, 1)) == .zero)
        #expect(space.position(of: GridPoint(0, 0)) == [-20, -10])
        #expect(space.point(at: [-16, -6]) == GridPoint(0, 0))
        #expect(space.point(at: [24, 9]) == GridPoint(4, 2))
    }

    @Test func gridIsCodable() throws {
        let g = grid([".#~", "..."])
        let data = try JSONEncoder().encode(g)
        #expect(try JSONDecoder().decode(GridGraph.self, from: data) == g)
    }
}

@MainActor @Suite(.serialized) struct PathFollowTests {
    @Test func movesAtSpeedAndCarriesOverCorners() {
        let world = World()
        world.addSystem(PathFollowSystem.self)
        let entity = Entity()
        world.addEntity(entity)
        entity.follow([[10, 0], [10, 10]], speed: 10)

        world.update(deltaTime: 0.5)
        #expect(entity.position == [5, 0])
        world.update(deltaTime: 1)  // 5 to the corner, 5 more up
        #expect(entity.position == [10, 5])
        #expect(entity.components[PathComponent.self]?.nextIndex == 1)
    }

    @Test func finishesWithEvent() {
        let world = World()
        world.addSystem(PathFollowSystem.self)
        let entity = Entity()
        world.addEntity(entity)
        var finished = 0
        let subscription = world.subscribe(to: PathEvents.DidFinish.self, on: entity) { _ in finished += 1 }
        entity.follow([[3, 4]], speed: 100, orientsToPath: true)

        world.update(deltaTime: 1)
        #expect(entity.position == [3, 4])
        #expect(!entity.isFollowingPath)
        #expect(finished == 1)
        #expect(abs(entity.transform.rotation - atan2(4, 3)) < 0.0001)
        world.update(deltaTime: 1)
        #expect(finished == 1)
        _ = subscription
    }

    @Test func stopLeavesEntityInPlace() {
        let world = World()
        world.addSystem(PathFollowSystem.self)
        let entity = Entity()
        world.addEntity(entity)
        entity.follow([[100, 0]], speed: 10)
        world.update(deltaTime: 1)
        entity.stopFollowingPath()
        world.update(deltaTime: 1)
        #expect(entity.position == [10, 0])
    }
}
