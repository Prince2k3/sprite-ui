import Foundation
import Gameplay
import Testing

@Suite struct CharacterPenetrationTests {
    @Test func circleDepthAndNormalMatchAnalyticOverlap() throws {
        let a = CollisionGeometry.Shape(.circle(radius: 3), position: [3, 0])
        let b = CollisionGeometry.Shape(.circle(radius: 2))
        let hit = try #require(CollisionGeometry.penetration(a, against: b))
        #expect(abs(hit.depth - 2) < 0.002 && hit.normal.x > 0.999)
        var moved = a; moved.position += hit.normal * (hit.depth + 0.01)
        #expect(CollisionGeometry.overlap(moved, b) == nil)
    }
    @Test func coincidentCentersRecoverDeterministically() throws {
        let a = CollisionGeometry.Shape(.circle(radius: 3)), b = CollisionGeometry.Shape(.circle(radius: 2))
        let hit = try #require(CollisionGeometry.penetration(a, against: b))
        #expect(abs(hit.depth - 5) < 0.002)
        var moved = a; moved.position += hit.normal * (hit.depth + 0.01)
        #expect(CollisionGeometry.overlap(moved, b) == nil)
    }
    @Test func affineShapesAndEdgesRecoverWithoutUsingBoundingBoxes() throws {
        let b = CollisionGeometry.Shape(.edgeChain([[-20, 0], [20, 0]]))
        var a = CollisionGeometry.Shape(.circle(radius: 2), position: [0, 1], xAxis: [3, 0], yAxis: [1, 2])
        let hit = try #require(CollisionGeometry.penetration(a, against: b))
        #expect(abs(hit.depth - 3) < 0.002 && hit.normal.y > 0.999)
        a.position += hit.normal * (hit.depth + 0.01)
        #expect(CollisionGeometry.overlap(a, b) == nil)
        #expect(CollisionGeometry.penetration(a, against: b) == nil)
    }
    @Test func seededOverlappingCirclesRecoverWithAnalyticDepth() throws {
        var rng = SeededGenerator(seed: 912)
        for _ in 0..<100 {
            let radius = Float.random(in: 0.1...20, using: &rng), other = Float.random(in: 0.1...20, using: &rng)
            let angle = Float.random(in: 0...(2 * .pi), using: &rng)
            let distance = Float.random(in: 0...(radius + other - 0.01), using: &rng)
            var a = CollisionGeometry.Shape(.circle(radius: radius), position: [cos(angle), sin(angle)] * distance)
            let b = CollisionGeometry.Shape(.circle(radius: other))
            let hit = try #require(CollisionGeometry.penetration(a, against: b))
            #expect(abs(hit.depth - (radius + other - distance)) < 0.01)
            a.position += hit.normal * (hit.depth + 0.01)
            #expect(CollisionGeometry.overlap(a, b) == nil)
        }
    }
}
