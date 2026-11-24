import Foundation
import Gameplay
import Testing

private typealias Proxy = HistoricalCollisionBody2D<Int>
private typealias HistoricalScene = HistoricalCollisionScene2D<Int>
private let historicalSource = Proxy(id: 0, shape: .circle(radius: 3), position: .zero, isTarget: false)
@Suite struct HistoricalCollisionTests {
    @Test func exactOldQueriesHitWithoutMutatingCurrentData() throws {
        let old = HistoricalScene(bodies: [historicalSource, .init(id: 1, shape: .circle(radius: 5), position: [100, 0])])
        let current = HistoricalScene(bodies: [historicalSource, .init(id: 1, shape: .circle(radius: 5), position: [100, 40])])
        #expect(try old.raycast(from: 0, direction: [1, 0], range: 200)?.id == 1)
        #expect(try current.raycast(from: 0, direction: [1, 0], range: 200) == nil)
        #expect(current.bodies[1].position == [100, 40])
    }
    @Test func closestBlockerOccludesTheTargetAndTiesUseStableIdentity() throws {
        let wall = Proxy(id: 2, shape: .rectangle(size: [2, 80]), position: [50, 0], isTarget: false)
        let target = Proxy(id: 1, shape: .circle(radius: 5), position: [100, 0])
        let scene = HistoricalScene(bodies: [target, wall, historicalSource])
        let hit = try #require(try scene.raycast(from: 0, direction: [1, 0], range: 200))
        #expect(hit.id == 2 && !hit.isTarget && abs(hit.distance - 49) < 0.001)
        let tie = HistoricalScene(bodies: [.init(id: 2, shape: target.shape, position: target.position), target, historicalSource])
        #expect(try tie.raycast(from: 0, direction: [1, 0], range: 200)?.id == 1)
    }
    @Test func affineShapesAndReflectionsUseTheExistingCollisionGeometry() throws {
        let scene = HistoricalScene(bodies: [historicalSource, .init(id: 1, shape: .rectangle(size: [10, 10]), position: [40, 0], xAxis: [-2, 0], yAxis: [0.5, 1])])
        let hit = try #require(try scene.raycast(from: 0, direction: [1, 0], range: 100))
        #expect(hit.id == 1 && hit.distance > 25 && hit.distance < 40)
    }
    @Test func rangesAndNonunitDirectionsCannotExtendQueries() throws {
        let scene = HistoricalScene(bodies: [historicalSource, .init(id: 1, shape: .circle(radius: 5), position: [100, 0])])
        #expect(try scene.raycast(from: 0, direction: [1, 0], range: 90) == nil)
        for direction: SIMD2<Float> in [[.nan, 0], [0, 0], [2, 0]] {
            #expect(throws: HistoricalCollisionError.invalidQuery) { try scene.raycast(from: 0, direction: direction, range: 100) }
        }
        #expect(throws: HistoricalCollisionError.invalidQuery) { try scene.raycast(from: 0, direction: [1, 0], range: .infinity) }
        #expect(throws: HistoricalCollisionError.missingSource) { try scene.raycast(from: 999, direction: [1, 0], range: 100) }
    }
    @Test func proximityRequiresEligibilityRangeAndVisibility() throws {
        let target = Proxy(id: 1, shape: .circle(radius: 5), position: [40, 0], isTarget: false, canInteract: true)
        let scene = HistoricalScene(bodies: [historicalSource, target])
        #expect(try scene.interaction(from: 0, with: 1, range: 50)?.isTarget == true)
        #expect(try scene.interaction(from: 0, with: 1, range: 30) == nil)
        let blocked = HistoricalScene(bodies: scene.bodies + [.init(id: 2, shape: .rectangle(size: [2, 20]), position: [20, 0], isTarget: false)])
        #expect(try blocked.interaction(from: 0, with: 1, range: 50)?.isTarget == false)
        let disabled = HistoricalScene(bodies: [historicalSource, .init(id: 1, shape: .circle(radius: 5), position: [40, 0])])
        #expect(try disabled.interaction(from: 0, with: 1, range: 50) == nil)
    }
    @Test func excessiveDuplicateAndNonfiniteGeometryFailsClosed() {
        let duplicate = HistoricalScene(bodies: [historicalSource, historicalSource])
        #expect(throws: HistoricalCollisionError.invalidScene) { try duplicate.validate() }
        for body in [Proxy(id: 1, shape: .circle(radius: .infinity), position: .zero),
                     Proxy(id: 1, shape: .polygon(Array(repeating: .zero, count: 1000)), position: .zero),
                     Proxy(id: 1, shape: .circle(radius: 1), position: [.nan, 0]),
                     Proxy(id: 1, shape: .circle(radius: 1), position: .zero, xAxis: .zero)] {
            #expect(throws: HistoricalCollisionError.invalidScene) { try HistoricalScene(bodies: [body]).validate() }
        }
        let tooMany = HistoricalScene(bodies: (0..<65).map { Proxy(id: $0, shape: .circle(radius: 1), position: .zero) })
        #expect(throws: HistoricalCollisionError.invalidScene) { try tooMany.validate() }
    }
}
