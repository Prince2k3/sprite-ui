@_spi(Backend) @testable import ECSCore
import Foundation
import Testing

private func close(_ lhs: SIMD2<Float>?, _ rhs: SIMD2<Float>) -> Bool {
    guard let lhs else { return false }
    return abs(lhs.x - rhs.x) < 0.001 && abs(lhs.y - rhs.y) < 0.001
}

@MainActor @Suite struct RelativeTransformTests {
    @Test func positionsAndDirectionsRoundTripThroughRotatedScaledAncestors() throws {
        let world = World()
        world.root.transform = Transform(translation: [7, -2], rotation: 0.1)
        let parent = Entity(); parent.transform = Transform(translation: [20, 30], rotation: .pi / 2, scale: [2, 3])
        let child = Entity(); child.transform = Transform(translation: [5, 8], rotation: 0.4, scale: [0.5, 2])
        world.addEntity(parent); parent.addChild(child)
        let point: SIMD2<Float> = [3, -9]
        let expected = world.root.transform.apply(to: parent.transform.apply(to: child.transform.apply(to: point)))
        #expect(close(child.convert(position: point, to: nil), expected))
        #expect(close(child.convert(position: expected, from: nil), point))
        let direction = try #require(child.convert(direction: [1, 2], to: nil))
        #expect(close(child.convert(direction: direction, from: nil), [1, 2]))
        #expect(close(child.position(relativeTo: parent), child.position))
        #expect(child.scene === world)
    }

    @Test func settingRelativePositionRespectsTheWholeParentChain() throws {
        let world = World(); let parent = Entity(); let child = Entity()
        parent.transform = Transform(translation: [10, 20], rotation: .pi / 2, scale: [2, 4])
        parent.addChild(child); world.addEntity(parent)
        try child.setPosition([70, 50], relativeTo: nil)
        #expect(close(child.scenePosition, [70, 50]))
        try child.setPosition([3, 4], relativeTo: parent)
        #expect(child.position == [3, 4])
    }

    @Test func reparentPreservesAllCornersAndDrawOrder() throws {
        let a = Entity(), b = Entity(), child = Entity()
        a.transform = Transform(translation: [15, -30], rotation: 0.3, scale: [2, 2], zPosition: 4)
        b.transform = Transform(translation: [-40, 20], rotation: -0.7, scale: [3, 3], zPosition: -8)
        child.transform = Transform(translation: [6, 9], rotation: 0.8, scale: [2, -1], zPosition: 7)
        a.addChild(child)
        let corners: [SIMD2<Float>] = [[0, 0], [10, 0], [0, 10], [-10, 10]]
        let before = corners.map { child.convert(position: $0, to: nil)! }
        try child.setParent(b, preservingWorldTransform: true)
        for (corner, expected) in zip(corners, before) { #expect(close(child.convert(position: corner, to: nil), expected)) }
        #expect(child.parent === b)
        #expect(abs(child.zPosition + b.zPosition - 11) < 0.001)
        try child.setParent(nil, preservingWorldTransform: true)
        #expect(child.parent == nil)
        #expect(close(child.convert(position: corners[1], to: nil), before[1]))
    }

    @Test func unrepresentableReparentDoesNotChangeAnything() throws {
        let a = Entity(), b = Entity(), child = Entity()
        a.scale = [2, 1]; child.rotation = .pi / 4
        a.addChild(child)
        let original = child.transform
        #expect(throws: EntityTransformError.requiresShear) { try child.setParent(b, preservingWorldTransform: true) }
        #expect(child.parent === a)
        #expect(child.transform == original)
        #expect(b.children.isEmpty)
    }

    @Test func cyclesAndWorldRootMovesAreRejectedAtomically() throws {
        let world = World(); let parent = Entity(); let child = Entity()
        world.addEntity(parent); parent.addChild(child)
        #expect(throws: EntityTransformError.hierarchyCycle) { try parent.setParent(child) }
        #expect(throws: EntityTransformError.hierarchyCycle) { try child.setParent(child) }
        #expect(throws: EntityTransformError.worldRootCannotBeReparented) { try child.addChild(world.root, preservingWorldTransform: false) }
        #expect(parent.parent === world.root && child.parent === parent)
        #expect(world.allEntities.count == 2)
    }

    @Test func singularAndDifferentWorldConversionsFailWithoutNaNs() throws {
        let world = World(), other = World(); let a = Entity(), b = Entity()
        world.addEntity(a); other.addEntity(b)
        #expect(a.position(relativeTo: b) == nil)
        #expect(throws: EntityTransformError.differentWorlds) { try a.setPosition([1, 2], relativeTo: b) }
        let child = Entity(); a.addChild(child); a.scale = [0, 2]
        #expect(child.convert(position: .zero, from: nil) == nil)
        #expect(throws: EntityTransformError.noninvertibleTransform) { try child.setPosition([1, 2], relativeTo: nil) }
        #expect(child.position == .zero)
        #expect(throws: EntityTransformError.nonfiniteTransform) { try child.setPosition([.nan, 0], relativeTo: a) }
    }

    @Test func keepingAComponentSetKeepsItsOwnerAlive() {
        weak var weakEntity: Entity?
        let components: ComponentSet = {
            let entity = Entity(); weakEntity = entity
            return entity.components
        }()
        #expect(weakEntity != nil)
        components.set(Transform(translation: [10, 5]))
        #expect(components[Transform.self]?.translation == [10, 5])
        _ = components
    }
}

private struct ScheduleTrace: Component { var events: [String] = []; var deltas: [Double] = [] }
private struct FirstSystem: System {
    static var dependencies: [SystemDependency] { [.before(SecondSystem.self)] }
    init(world: World) {}
    func update(context: UpdateContext) {
        context.world.resources[ScheduleTrace.self]?.events.append("first")
        context.world.resources[ScheduleTrace.self]?.deltas.append(context.deltaTime)
    }
}
private struct SecondSystem: System {
    init(world: World) {}
    func update(context: UpdateContext) { context.world.resources[ScheduleTrace.self]?.events.append("second") }
}
private struct PresentationSystem: System {
    static var phase: SystemPhase { .presentation }
    init(world: World) {}
    func update(context: UpdateContext) { context.world.resources[ScheduleTrace.self]?.events.append("presentation") }
}
private struct CycleA: System {
    static var dependencies: [SystemDependency] { [.after(CycleB.self)] }
    init(world: World) {}
    func update(context: UpdateContext) {}
}
private struct CycleB: System {
    static var dependencies: [SystemDependency] { [.after(CycleA.self)] }
    init(world: World) {}
    func update(context: UpdateContext) {}
}
private struct InvalidPhaseSystem: System {
    static var dependencies: [SystemDependency] { [.after(PresentationSystem.self)] }
    init(world: World) {}
    func update(context: UpdateContext) {}
}
private struct MutatingScheduleSystem: System {
    static var dependencies: [SystemDependency] { [.before(SecondSystem.self)] }
    init(world: World) {}
    func update(context: UpdateContext) {
        context.world.resources[ScheduleTrace.self]?.events.append("mutator")
        context.world.systems.remove(SecondSystem.self)
        try! context.world.systems.add(FirstSystem.self)
    }
}

@MainActor @Suite struct SceneSchedulingTests {
    @Test func dependenciesAndPhasesOverrideInstallationOrder() throws {
        let world = World(); world.resources.set(ScheduleTrace())
        try world.systems.add(PresentationSystem.self)
        try world.systems.add(SecondSystem.self)
        try world.systems.add(FirstSystem.self)
        world.update(deltaTime: 0.5)
        #expect(world.resources[ScheduleTrace.self]?.events == ["first", "second", "presentation"])
        world.systems.setEnabled(false, for: SecondSystem.self)
        world.resources[ScheduleTrace.self]?.events = []
        world.update(deltaTime: 0.5)
        #expect(world.resources[ScheduleTrace.self]?.events == ["first", "presentation"])
    }

    @Test func badSchedulesAreRejectedWithoutInstallingTheSystem() throws {
        let world = World()
        try world.systems.add(CycleA.self)
        #expect(throws: SystemSchedulingError.self) { try world.systems.add(CycleB.self) }
        #expect(!world.systems.contains(CycleB.self))
        try world.systems.add(PresentationSystem.self)
        #expect(throws: SystemSchedulingError.self) { try world.systems.add(InvalidPhaseSystem.self) }
        #expect(!world.systems.contains(InvalidPhaseSystem.self))
    }

    @Test func pausedScenesAndTimeScaleAffectEventsAndBothPhases() throws {
        let world = World(); world.resources.set(ScheduleTrace())
        try world.systems.add(FirstSystem.self); try world.systems.add(PresentationSystem.self)
        var events: [Double] = []
        let token = world.subscribe(to: WorldEvents.Update.self) { events.append($0.deltaTime) }
        world.timeScale = 0.25; world.update(deltaTime: 2)
        #expect(events == [0.5])
        #expect(world.resources[ScheduleTrace.self]?.deltas == [0.5])
        world.isPaused = true; world.update(deltaTime: 2)
        world.isPaused = false; world.timeScale = 0; world.update(deltaTime: 2)
        #expect(events == [0.5])
        world.timeScale = 1; world.update(deltaTime: 0)
        #expect(events == [0.5, 0])
        _ = token
    }

    @Test func mutationsDuringAnUpdateUseAStableFrameSchedule() throws {
        let world = World(); world.resources.set(ScheduleTrace())
        try world.systems.add(SecondSystem.self); try world.systems.add(MutatingScheduleSystem.self)
        world.update(deltaTime: 0.1)
        #expect(world.resources[ScheduleTrace.self]?.events == ["mutator"])
        world.resources[ScheduleTrace.self]?.events = []
        world.update(deltaTime: 0.1)
        #expect(world.resources[ScheduleTrace.self]?.events == ["mutator", "first"])
    }

    @Test func backendPresentationIsDeferredAndFinishesOnce() throws {
        let world = World(); world.resources.set(ScheduleTrace())
        try world.systems.add(FirstSystem.self); try world.systems.add(PresentationSystem.self)
        let frame = try #require(world.beginFrame(deltaTime: 0.1))
        #expect(world.resources[ScheduleTrace.self]?.events == ["first"])
        world.finishFrame(frame); world.finishFrame(frame)
        #expect(world.resources[ScheduleTrace.self]?.events == ["first", "presentation"])
    }

    @Test func invalidTimesAreIgnored() {
        let world = World(); world.timeScale = 2
        world.timeScale = -.infinity; #expect(world.timeScale == 2)
        world.timeScale = .nan; #expect(world.timeScale == 2)
        var count = 0
        let token = world.subscribe(to: WorldEvents.Update.self) { _ in count += 1 }
        world.update(deltaTime: -.infinity); world.update(deltaTime: -1); world.update(deltaTime: .nan)
        #expect(count == 0)
        _ = token
    }
}
