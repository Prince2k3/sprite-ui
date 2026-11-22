import ECSCore
import Foundation
import Gameplay
import GameplayECS
import Testing

private func randomPoints(_ count: Int, seed: UInt64, in box: BoundingBox) -> [SIMD2<Float>] {
    var rng = SeededGenerator(seed: seed)
    return (0..<count).map { _ in
        SIMD2(Float.random(in: box.min.x..<box.max.x, using: &rng),
              Float.random(in: box.min.y..<box.max.y, using: &rng))
    }
}

private func lengthSquared(_ v: SIMD2<Float>) -> Float { (v * v).sum() }

@Suite struct BoundingBoxTests {
    @Test func basics() {
        let box = BoundingBox(center: [0, 0], size: [10, 4])
        #expect(box.min == [-5, -2] && box.max == [5, 2])
        #expect(box.contains([5, 2]))
        #expect(!box.contains([5.1, 0]))
        #expect(box.intersects(BoundingBox(min: [4, 1], max: [8, 8])))
        #expect(!box.intersects(BoundingBox(min: [6, 0], max: [8, 1])))
        #expect(box.intersects(circleAt: [7, 0], radius: 2))
        #expect(!box.intersects(circleAt: [8, 0], radius: 2))
        #expect(box.distanceSquared(to: [8, 6]) == 9 + 16)
        #expect(box.distanceSquared(to: [1, 1]) == 0)
        let quarters = box.quadrants
        #expect(quarters[0] == BoundingBox(min: [-5, -2], max: [0, 0]))
        #expect(quarters[3] == BoundingBox(min: [0, 0], max: [5, 2]))
    }
}

/// Runs the same checks against both index types, comparing with brute force.
private func checkAgainstBruteForce<Index: SpatialIndex<Int>>(_ make: () -> Index) {
    let region = BoundingBox(center: .zero, size: [1000, 1000])
    let points = randomPoints(500, seed: 7, in: region)
    var index = make()
    for (i, p) in points.enumerated() { let inserted = index.insert(i, at: p); #expect(inserted) }
    #expect(index.count == points.count)

    var rng = SeededGenerator(seed: 99)
    for _ in 0..<40 {
        let center = SIMD2(Float.random(in: -500..<500, using: &rng), Float.random(in: -500..<500, using: &rng))
        let radius = Float.random(in: 0..<200, using: &rng)

        let expectedRadius = Set(points.indices.filter { lengthSquared(points[$0] - center) <= radius * radius })
        #expect(Set(index.elements(within: radius, of: center)) == expectedRadius)

        let box = BoundingBox(center: center, size: [radius * 2, radius])
        let expectedBox = Set(points.indices.filter { box.contains(points[$0]) })
        #expect(Set(index.elements(in: box)) == expectedBox)

        let k = Int.random(in: 1...12, using: &rng)
        let nearest = index.nearest(to: center, count: k)
        let expectedDistances = points.map { lengthSquared($0 - center) }.sorted().prefix(k)
        #expect(nearest.map { lengthSquared(points[$0] - center) } == Array(expectedDistances))

        let capped = index.nearest(to: center, count: 50, maxDistance: radius)
        #expect(capped.count == min(50, expectedRadius.count))
    }
}

@Suite struct QuadTreeTests {
    let region = BoundingBox(center: .zero, size: [1000, 1000])

    @Test func matchesBruteForce() {
        checkAgainstBruteForce { QuadTree<Int>(bounds: region) }
    }

    @Test func rejectsPointsOutsideBounds() {
        var tree = QuadTree<Int>(bounds: region)
        let inserted = tree.insert(1, at: [600, 0])
        #expect(!inserted)
        #expect(tree.isEmpty)
    }

    @Test func movesAndCollapses() {
        var tree = QuadTree<Int>(bounds: region, nodeCapacity: 4)
        let points = randomPoints(200, seed: 3, in: region)
        for (i, p) in points.enumerated() { tree.insert(i, at: p) }
        #expect(tree.leafBounds.count > 1)

        tree.move(0, to: [499, 499])
        #expect(tree.position(of: 0) == [499, 499])
        #expect(tree.elements(within: 1, of: [499, 499]).contains(0))
        #expect(tree.count == 200)

        for i in 0..<197 { let removed = tree.remove(i); #expect(removed) }
        let removedAgain = tree.remove(0)
        #expect(!removedAgain)
        #expect(tree.count == 3)
        #expect(tree.leafBounds == [region])
        #expect(Set(tree.nearest(to: .zero, count: 10)) == [197, 198, 199])
    }

    @Test func handlesManyElementsAtOneSpot() {
        var tree = QuadTree<Int>(bounds: region, nodeCapacity: 2, maxDepth: 5)
        for i in 0..<100 { tree.insert(i, at: [1, 1]) }
        #expect(tree.elements(within: 0, of: [1, 1]).count == 100)
    }

    @Test func codableRoundTrip() throws {
        var tree = QuadTree<Int>(bounds: region)
        for (i, p) in randomPoints(50, seed: 5, in: region).enumerated() { tree.insert(i, at: p) }
        let decoded = try JSONDecoder().decode(QuadTree<Int>.self, from: JSONEncoder().encode(tree))
        #expect(decoded == tree)
        #expect(decoded.nearest(to: .zero, count: 5) == tree.nearest(to: .zero, count: 5))
    }
}

@Suite struct SpatialHashTests {
    @Test func matchesBruteForce() {
        checkAgainstBruteForce { SpatialHash<Int>(cellSize: 37) }
    }

    @Test func handlesNegativeCoordinates() {
        var hash = SpatialHash<String>(cellSize: 10)
        hash.insert("a", at: [-0.5, -0.5])
        hash.insert("b", at: [0.5, 0.5])
        #expect(hash.cell(containing: [-0.5, -0.5]) == GridPoint(-1, -1))
        #expect(hash.occupiedCells.count == 2)
        #expect(Set(hash.elements(within: 1, of: .zero)) == ["a", "b"])
        let inserted = hash.insert("c", at: [.nan, 0])
        #expect(!inserted)
    }

    @Test func movesBetweenCells() {
        var hash = SpatialHash<Int>(cellSize: 10)
        hash.insert(1, at: [1, 1])
        hash.insert(1, at: [2, 2])
        #expect(hash.occupiedCells.count == 1)
        hash.move(1, to: [55, 55])
        #expect(hash.occupiedCells.count == 1)
        #expect(hash.elements(within: 5, of: [1, 1]).isEmpty)
        #expect(hash.nearest(to: .zero) == 1)
        let removed = hash.remove(1)
        #expect(removed)
        #expect(hash.occupiedCells.isEmpty)
    }

    @Test func nearestFindsFarSparseElements() {
        var hash = SpatialHash<Int>(cellSize: 1)
        hash.insert(1, at: [10_000, -10_000])
        hash.insert(2, at: [-20_000, 5])
        #expect(hash.nearest(to: .zero, count: 2) == [1, 2])
        #expect(hash.nearest(to: .zero, maxDistance: 100) == nil)
    }

    @Test func codableRoundTrip() throws {
        var hash = SpatialHash<Int>(cellSize: 16)
        for (i, p) in randomPoints(50, seed: 8, in: BoundingBox(center: .zero, size: [300, 300])).enumerated() {
            hash.insert(i, at: p)
        }
        let decoded = try JSONDecoder().decode(SpatialHash<Int>.self, from: JSONEncoder().encode(hash))
        #expect(decoded == hash)
    }
}

extension SpatialCategories {
    fileprivate static let enemies = SpatialCategories(rawValue: 1 << 1)
}

@MainActor @Suite(.serialized) struct SpatialIndexSystemTests {
    private func makeEntity(in world: World, at position: SIMD2<Float>, categories: SpatialCategories = .default) -> Entity {
        let entity = Entity()
        entity.transform.translation = position
        entity.components.set(SpatialIndexComponent(categories: categories))
        world.addEntity(entity)
        return entity
    }

    @Test func indexesEntitiesEachUpdate() {
        let world = World()
        world.addSystem(SpatialIndexSystem.self)
        let near = makeEntity(in: world, at: [10, 0])
        let far = makeEntity(in: world, at: [100, 0])
        let unindexed = Entity()
        world.addEntity(unindexed)

        world.update(deltaTime: 0.1)
        #expect(world.spatialIndex.count == 2)
        #expect(world.entities(within: 200, of: .zero).map(\.id) == [near.id, far.id])
        #expect(world.nearestEntity(to: [90, 0]) === far)
        #expect(world.nearestEntity(to: [90, 0], excluding: far) === near)

        far.transform.translation = [5, 0]
        world.update(deltaTime: 0.1)
        #expect(world.nearestEntity(to: .zero) === far)
    }

    @Test func filtersByCategory() {
        let world = World()
        let friend = makeEntity(in: world, at: [1, 0])
        let enemy = makeEntity(in: world, at: [50, 0], categories: .enemies)
        world.updateSpatialIndex()

        #expect(world.nearestEntity(to: .zero, matching: .enemies) === enemy)
        #expect(world.entities(within: 100, of: .zero, matching: .default).map(\.id) == [friend.id])
        #expect(world.entities(in: BoundingBox(center: .zero, radius: 100), matching: .all).count == 2)
        #expect(world.nearestEntities(to: .zero, count: 5, matching: .enemies).count == 1)
    }

    @Test func dropsRemovedEntitiesAndComponents() {
        let world = World()
        let a = makeEntity(in: world, at: [0, 0])
        let b = makeEntity(in: world, at: [1, 0])
        world.updateSpatialIndex()
        #expect(world.spatialIndex.count == 2)

        world.removeEntity(a)
        b.components.remove(SpatialIndexComponent.self)
        world.updateSpatialIndex()
        #expect(world.spatialIndex.isEmpty)
        #expect(world.nearestEntity(to: .zero) == nil)
    }

    @Test func usesScenePositionOfChildren() {
        let world = World()
        let parent = Entity()
        parent.transform = Transform(translation: [100, 0], rotation: .pi / 2, scale: [2, 2])
        world.addEntity(parent)
        let child = Entity()
        child.transform.translation = [10, 0]
        child.components.set(SpatialIndexComponent())
        parent.addChild(child)

        world.updateSpatialIndex()
        let position = try! #require(world.spatialIndex.position(of: child.id))
        #expect(abs(position.x - 100) < 0.001 && abs(position.y - 20) < 0.001)
    }

    @Test func changingCellSizeRebuilds() {
        let world = World()
        _ = makeEntity(in: world, at: [3, 4])
        world.updateSpatialIndex()
        world.spatialCellSize = 8
        #expect(world.spatialCellSize == 8)
        #expect(world.spatialIndex.count == 1)
    }
}
