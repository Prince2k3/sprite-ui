import Foundation
import SpriteUI
import Testing
@testable import DemoBotsGame

@MainActor @Suite(.serialized) struct DemoBotsNavigationTests {
    @Test func rejectsEndpointsWithoutCharacterClearance() {
        let navigation = BotNavigation(bounds: BoundingBox(min: .zero, max: [400, 400]), obstacles: [])
        for goal: SIMD2<Float> in [[10, 200], [390, 200], [200, 10], [200, 390], [450, 200]] {
            #expect(navigation.path(from: [200, 200], to: goal).isEmpty)
            #expect(!navigation.isClear(from: [200, 200], to: goal))
        }
    }

    @Test func unreachableGoalNeverReturnsAPartialRoute() {
        let wall = PolygonObstacle(BoundingBox(min: [180, 0], max: [220, 400]))
        let navigation = BotNavigation(bounds: BoundingBox(min: .zero, max: [400, 400]), obstacles: [wall])
        #expect(navigation.path(from: [80, 200], to: [320, 200]).isEmpty)
        #expect(navigation.path(from: [80, 200], to: [200, 200]).isEmpty)
    }

    @Test func narrowPassageUsesPhysicalClearanceInsteadOfGridCellPadding() {
        let walls = [
            PolygonObstacle(BoundingBox(min: [0, 180], max: [173, 220])),
            PolygonObstacle(BoundingBox(min: [227, 180], max: [400, 220])),
        ]
        let bounds = BoundingBox(min: .zero, max: [400, 400])
        let navigation = BotNavigation(bounds: bounds, obstacles: walls)
        let path = navigation.path(from: [80, 80], to: [320, 320])
        #expect(path.first == [80, 80] && path.last == [320, 320])
        #expect(path.count > 2)
        let wider = BotNavigation(bounds: bounds, obstacles: walls, radius: 27)
        #expect(wider.path(from: [80, 80], to: [320, 320]).isEmpty)
    }

    @Test func walkabilityIncludesSkinMarginAndRejectsInvalidStarts() {
        let wall = PolygonObstacle(BoundingBox(min: [180, 180], max: [220, 220]))
        let navigation = BotNavigation(bounds: BoundingBox(min: .zero, max: [400, 400]), obstacles: [wall])
        #expect(!navigation.isWalkable([25.01, 100]))
        #expect(navigation.isWalkable([26, 100]))
        #expect(!navigation.isWalkable([154.5, 200]))
        #expect(navigation.isWalkable([154, 200]))
        for start: SIMD2<Float> in [[10, 100], [200, 200], [.nan, 100], [.infinity, 100]] {
            #expect(!navigation.isWalkable(start))
            #expect(!navigation.isClear(from: start, to: [80, 80]))
            #expect(navigation.path(from: start, to: [80, 80]).isEmpty)
            #expect(navigation.path(from: [80, 80], to: start).isEmpty)
        }
        #expect(navigation.path(from: [80, 80], to: [80, 80]) == [[80, 80]])
    }

    @Test func changingBoundsOrObstaclesRebuildsTheCachedFloor() {
        var navigation = BotNavigation(bounds: BoundingBox(min: .zero, max: [400, 400]), obstacles: [])
        #expect(navigation.isClear(from: [80, 200], to: [320, 200]))
        navigation.obstacles = [PolygonObstacle(BoundingBox(min: [180, 0], max: [220, 400]))]
        #expect(navigation.padded.count == 1)
        #expect(navigation.path(from: [80, 200], to: [320, 200]).isEmpty)
        navigation.obstacles = []
        navigation.bounds = BoundingBox(min: .zero, max: [200, 400])
        #expect(!navigation.isWalkable([190, 200]))
        #expect(navigation.path(from: [80, 200], to: [320, 200]).isEmpty)
    }

    private struct Level {
        let bounds: BoundingBox
        let obstacles: [PolygonObstacle]
        let markers: [(name: String, point: SIMD2<Float>)]
        let patrols: [[String]]
    }

    private func load(_ number: Int) throws -> Level {
        let config = try BotLevelConfiguration.load(number)
        let scene = try SceneLoader().load(contentsOf: DemoBotsResources.url("Level\(number)", extension: "sks"))
        scene.position = .zero
        let layer = try #require(scene.findEntity(named: "obstacles"))
        for entity in layer.children {
            guard let size = entity.components[SpriteComponent.self]?.size else { continue }
            entity.components.set(PolygonObstacleComponent(rectangle: size))
        }
        let world = World()
        world.addEntity(scene)
        let bounds: BoundingBox
        switch number {
        case 1: bounds = BoundingBox(min: [128, -1064], max: [1376, 640])
        case 2: bounds = BoundingBox(min: [64, -1152], max: [2848, 1056])
        default: bounds = BoundingBox(min: [128, -1280], max: [2048, 640])
        }
        let names = Set(["transporter_coordinate"] + config.taskBotConfigurations.flatMap {
            $0.goodPathNodeNames + $0.badPathNodeNames
        }).sorted()
        let markers = try names.map { name in
            let entity = try #require(scene.findEntity(named: name), "Level \(number): missing \(name)")
            return (name: name, point: entity.scenePosition)
        }
        return Level(bounds: bounds, obstacles: world.polygonObstacles, markers: markers,
                     patrols: config.taskBotConfigurations.flatMap { [$0.goodPathNodeNames, $0.badPathNodeNames] })
    }

    @Test func originalSceneMarkerRoutesKeepTheirEndpointsAndClearance() throws {
        for number in 1...3 {
            let level = try load(number)
            let clock = ContinuousClock()
            let buildStart = clock.now
            let navigation = BotNavigation(bounds: level.bounds, obstacles: level.obstacles)
            let buildTime = buildStart.duration(to: clock.now)
            let offFloor = Set(level.markers.filter { !navigation.isWalkable($0.point) }.map(\.name))
            #expect(offFloor.isEmpty, "Level \(number) off-floor markers: \(offFloor.sorted())")
            let positions = Dictionary(uniqueKeysWithValues: level.markers.map { ($0.name, $0.point) })
            for (index, patrol) in level.patrols.enumerated() {
                for (start, end) in zip(patrol, patrol.dropFirst() + patrol.prefix(1)) {
                    let a = try #require(positions[start]), b = try #require(positions[end])
                    let path = navigation.path(from: a, to: b)
                    #expect(!path.isEmpty && path.first == a && path.last == b,
                            "Level \(number), patrol \(index): \(start) → \(end)")
                }
            }
            let physicalFloor = BoundingBox(min: level.bounds.min + SIMD2(repeating: 25.01),
                                            max: level.bounds.max - SIMD2(repeating: 25.01))
            let colliders = level.obstacles.map { CollisionGeometry.Shape(.polygon($0.points)) }
            var checkedSegments: Set<[SIMD2<Float>]> = []
            var routed = 0
            var unreachable: [String] = []
            let searchStart = clock.now
            var searchTime = Duration.zero
            for start in level.markers {
                for goal in level.markers {
                    let began = clock.now
                    let path = navigation.path(from: start.point, to: goal.point)
                    searchTime += began.duration(to: clock.now)
                    if offFloor.contains(start.name) || offFloor.contains(goal.name) {
                        #expect(path.isEmpty, "An unsafe original marker must not be projected or truncated")
                        unreachable.append("\(start.name) → \(goal.name)")
                        continue
                    }
                    #expect(!path.isEmpty, "Level \(number): \(start.name) → \(goal.name)")
                    if path.isEmpty {
                        unreachable.append("\(start.name) → \(goal.name)")
                        continue
                    }
                    routed += 1
                    #expect(path.first == start.point && path.last == goal.point,
                            "Level \(number): \(start.name) → \(goal.name)")
                    for (a, b) in zip(path, path.dropFirst()) {
                        guard checkedSegments.insert([a, b]).inserted else { continue }
                        #expect(navigation.isClear(from: a, to: b))
                        // Check the actual swept disk, independently of polygon padding.
                        // Convex board bounds contain the whole segment if they contain its ends.
                        #expect(physicalFloor.contains(a) && physicalFloor.contains(b))
                        let disk = CollisionGeometry.Shape(.circle(radius: 25.01), position: a)
                        #expect(colliders.allSatisfy { CollisionGeometry.sweep(disk, by: b - a, against: $0) == nil },
                                "Level \(number): insufficient controller clearance from \(a) to \(b)")
                    }
                }
            }
            print("NAV Level \(number): markers=\(level.markers.count), obstacles=\(level.obstacles.count), build=\(buildTime), search=\(searchTime), routed=\(routed), unreachable=\(unreachable.count), validation=\(searchStart.duration(to: clock.now))")
            if !offFloor.isEmpty { print("NAV Level \(number) off-floor markers: \(offFloor.sorted())") }
        }
    }
}
