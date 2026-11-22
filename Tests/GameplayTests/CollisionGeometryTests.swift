import Foundation
import Gameplay
import Testing

@Suite struct CollisionGeometryTests {
    typealias Shape = CollisionGeometry.Shape
    func close(_ a: Float, _ b: Float, tolerance: Float = 0.002) -> Bool { abs(a - b) < tolerance }
    @Test func raysHaveAnalyticPositionsNormalsAndOrdering() throws {
        let circle = Shape(.circle(radius: 2), position: [10, 0])
        let hit = try #require(CollisionGeometry.raycast(from: .zero, to: [20, 0], against: circle))
        #expect(close(hit.distance, 8) && hit.position == [8, 0] && hit.normal == [-1, 0])
        #expect(CollisionGeometry.raycast(from: .zero, to: [7, 0], against: circle) == nil)
        let tangent = try #require(CollisionGeometry.raycast(from: [0, 2], to: [20, 2], against: circle))
        #expect(close(tangent.distance, 10) && tangent.normal == [0, 1])
        let inside = try #require(CollisionGeometry.raycast(from: [10, 0], to: [20, 0], against: circle))
        #expect(inside.distance == 0 && inside.normal == .zero)
    }
    @Test func affineEllipsesAndMirroredPolygonsAreExact() throws {
        let ellipse = Shape(.circle(radius: 1), position: [5, 0], xAxis: [2, 0], yAxis: [1, 1])
        let hit = try #require(CollisionGeometry.raycast(from: [-10, 0], to: [10, 0], against: ellipse))
        #expect(close(hit.position.x, 3))
        #expect(close(hit.normal.x, -1 / sqrt(2)) && close(hit.normal.y, 1 / sqrt(2)))
        let clockwise: [SIMD2<Float>] = [[-1, -1], [-1, 1], [1, 1], [1, -1]]
        let polygon = Shape(.polygon(clockwise), position: [5, 0], xAxis: [-2, 0], yAxis: [0, 1])
        let p = try #require(CollisionGeometry.raycast(from: .zero, to: [10, 0], against: polygon))
        #expect(close(p.distance, 3) && p.normal == [-1, 0])
    }
    @Test func overlapsUseShapesRatherThanOnlyBoundingBoxes() {
        let box = Shape(.rectangle(size: [2, 2]))
        #expect(CollisionGeometry.overlap(box, Shape(.circle(radius: 0.2), position: [1.19, 1.19])) == nil)
        #expect(CollisionGeometry.overlap(box, Shape(.circle(radius: 0.3), position: [1.19, 1.19])) != nil)
        #expect(CollisionGeometry.overlap(Shape(.circle(radius: 1)), Shape(.circle(radius: 1), position: [2, 0])) != nil)
        #expect(CollisionGeometry.overlap(Shape(.circle(radius: 1)), Shape(.circle(radius: 1), position: [2.01, 0])) == nil)
    }
    @Test func thinWallsCannotBeSkippedByFastSweeps() throws {
        let wall = Shape(.rectangle(size: [0.1, 100]), position: [100, 0])
        let hit = try #require(CollisionGeometry.sweep(Shape(.circle(radius: 1)), by: [1000, 0], against: wall))
        #expect(close(hit.distance, 98.95) && close(hit.position.x, 99.95))
        #expect(close(hit.normal.x, -1) && abs(hit.normal.y) < 0.002)
        #expect(CollisionGeometry.sweep(Shape(.circle(radius: 1)), by: [-1000, 0], against: wall) == nil)
    }
    @Test func edgeLoopsHaveNoFilledInteriorAndChainsAreOpen() throws {
        let loop = Shape(.edgeLoop(rectangle: [20, 20]))
        #expect(!CollisionGeometry.contains(.zero, in: loop))
        #expect(CollisionGeometry.overlap(Shape(.circle(radius: 1)), loop) == nil)
        let ray = try #require(CollisionGeometry.raycast(from: .zero, to: [100, 0], against: loop))
        #expect(close(ray.distance, 10))
        let sweep = try #require(CollisionGeometry.sweep(Shape(.circle(radius: 1)), by: [100, 0], against: loop))
        #expect(close(sweep.distance, 9))
        let chain = Shape(.edgeChain([[-10, -10], [10, -10], [10, 10]]))
        #expect(CollisionGeometry.raycast(from: .zero, to: [-20, 0], against: chain) == nil)
    }
    @Test func randomizedCircleSweepsMatchExpandedAnalyticRays() throws {
        var rng = SeededGenerator(seed: 107)
        for _ in 0..<120 {
            let radius = Float.random(in: 0.5...8, using: &rng), other = Float.random(in: 1...12, using: &rng)
            let target = SIMD2<Float>(Float.random(in: 30...100, using: &rng), Float.random(in: -10...10, using: &rng))
            let expected = CollisionGeometry.raycast(from: .zero, to: [150, 0], against: Shape(.circle(radius: radius + other), position: target))
            let actual = CollisionGeometry.sweep(Shape(.circle(radius: radius)), by: [150, 0], against: Shape(.circle(radius: other), position: target))
            #expect((expected == nil) == (actual == nil))
            if let expected, let actual { #expect(close(expected.distance, actual.distance, tolerance: 0.006)) }
        }
    }
    @Test func rotatedPolygonSweepsMatchIndependentMinkowskiHullRays() {
        var rng = SeededGenerator(seed: 98)
        func hull(_ source: [SIMD2<Float>]) -> [SIMD2<Float>] {
            let points = source.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
            func half(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
                var result: [SIMD2<Float>] = []
                for point in points {
                    while result.count >= 2 {
                        let a = result[result.count - 1] - result[result.count - 2], b = point - result[result.count - 1]
                        if a.x * b.y - a.y * b.x > 0 { break }
                        result.removeLast()
                    }
                    result.append(point)
                }
                return result
            }
            return Array(half(points).dropLast()) + Array(half(Array(points.reversed())).dropLast())
        }
        func box(_ size: SIMD2<Float>, angle: Float, center: SIMD2<Float>) -> [SIMD2<Float>] {
            let h = size / 2, c = cos(angle), s = sin(angle)
            let corners: [SIMD2<Float>] = [[-h.x, -h.y], [h.x, -h.y], [h.x, h.y], [-h.x, h.y]]
            return corners.map { center + SIMD2(c * $0.x - s * $0.y, s * $0.x + c * $0.y) }
        }
        for _ in 0..<80 {
            let a = box([8, 5], angle: Float.random(in: -3...3, using: &rng), center: .zero)
            let b = box([4, 12], angle: Float.random(in: -3...3, using: &rng), center: [50, Float.random(in: -15...15, using: &rng)])
            let expanded = hull(b.flatMap { target in a.map { target - $0 } })
            let expected = CollisionGeometry.raycast(from: .zero, to: [100, 0], against: Shape(.polygon(expanded)))
            let actual = CollisionGeometry.sweep(Shape(.polygon(a)), by: [100, 0], against: Shape(.polygon(b)))
            #expect((expected == nil) == (actual == nil))
            if let expected, let actual { #expect(close(expected.distance, actual.distance, tolerance: 0.006)) }
        }
    }
    @Test func transformedEllipseSweepsRespectItsSupportExtent() throws {
        let c = cos(Float.pi / 4), s = sin(Float.pi / 4)
        let ellipse = Shape(.circle(radius: 1), xAxis: [2 * c, 2 * s], yAxis: [-s, c])
        let hit = try #require(CollisionGeometry.sweep(ellipse, by: [100, 0], against: Shape(.rectangle(size: [1, 100]), position: [50, 0])))
        let extent = sqrt(4 * c * c + s * s)
        #expect(close(hit.distance, 49.5 - extent))
    }

    @Test func invalidInputsAndSingularTransformsAreIgnored() {
        let bad: [CollisionShape] = [.circle(radius: -1), .circle(radius: .nan), .rectangle(size: [0, 1]),
            .polygon([[0, 0], [2, 0], [1, 0.5], [2, 2], [0, 2]]),
            .polygon([[0, 0], [1, 0], [0, 1], [0, 0], [1, 0], [0, 1]]), .edgeChain([[0, 0], [0, 0]])]
        for shape in bad {
            #expect(!shape.isValid)
            #expect(CollisionGeometry.raycast(from: [-10, 0], to: [10, 0], against: Shape(shape)) == nil)
        }
        #expect(CollisionGeometry.raycast(from: [.nan, 0], to: [10, 0], against: Shape(.circle(radius: 1))) == nil)
        #expect(!CollisionGeometry.contains(.zero, in: Shape(.circle(radius: 1), xAxis: .zero)))
    }
    @Test func repeatedClosingVerticesAndGrazingSweepsAreSupported() throws {
        let points: [SIMD2<Float>] = [[-2, -2], [2, -2], [2, 2], [-2, 2], [-2, -2]]
        #expect(CollisionShape.polygon(points).isValid && CollisionShape.edgeLoop(points).isValid)
        #expect(CollisionGeometry.raycast(from: [-5, 0], to: [5, 0], against: Shape(.polygon(points)))?.distance == 3)
        #expect(!CollisionGeometry.contains(.zero, in: Shape(.edgeLoop(points))))
        let tangent = try #require(CollisionGeometry.sweep(Shape(.circle(radius: 1)), by: [100, 0], against: Shape(.circle(radius: 1), position: [50, 2])))
        #expect(abs(tangent.distance - 50) < 0.02)
        #expect(CollisionGeometry.sweep(Shape(.circle(radius: 1)), by: [100, 0], against: Shape(.circle(radius: 1), position: [50, 2.01])) == nil)
    }

    @Test func zeroLengthQueriesReportOnlyInitialOverlap() {
        let shape = Shape(.rectangle(size: [2, 2]))
        #expect(CollisionGeometry.raycast(from: .zero, to: .zero, against: shape)?.distance == 0)
        #expect(CollisionGeometry.sweep(shape, by: .zero, against: shape)?.distance == 0)
        #expect(CollisionGeometry.sweep(shape, by: .zero, against: Shape(.circle(radius: 1), position: [10, 0])) == nil)
    }
}
