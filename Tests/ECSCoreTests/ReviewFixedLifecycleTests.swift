@_spi(Backend) import ECSCore
import Testing

private struct ReviewFixedTrace: Component {
    var phases: [SystemPhase] = []
    var deltas: [Double] = []
    var unscaledDeltas: [Double] = []
    var ticks: [UInt64?] = []
    var fixedAction: (@MainActor (World) -> Void)?
}

@MainActor private func recordReviewFixed(_ context: UpdateContext) {
    context.world.resources[ReviewFixedTrace.self]?.phases.append(context.phase)
    context.world.resources[ReviewFixedTrace.self]?.deltas.append(context.deltaTime)
    context.world.resources[ReviewFixedTrace.self]?.unscaledDeltas.append(context.unscaledDeltaTime)
    context.world.resources[ReviewFixedTrace.self]?.ticks.append(context.fixedTick)
}

private struct ReviewFixedFirst: System {
    static var phase: SystemPhase { .fixedSimulation }
    static var dependencies: [SystemDependency] { [.before(ReviewFixedSecond.self)] }
    init(world: World) {}
    func update(context: UpdateContext) {
        recordReviewFixed(context)
        for entity in context.entities(matching: EntityQuery(where: .has(TransformInterpolationComponent.self))) {
            entity.position.x += 1
        }
        context.world.resources[ReviewFixedTrace.self]?.fixedAction?(context.world)
    }
}

private struct ReviewFixedSecond: System {
    static var phase: SystemPhase { .fixedSimulation }
    init(world: World) {}
    func update(context: UpdateContext) { recordReviewFixed(context) }
}

private struct ReviewFixedVariable: System {
    init(world: World) {}
    func update(context: UpdateContext) { recordReviewFixed(context) }
}

private struct ReviewFixedPresentation: System {
    static var phase: SystemPhase { .presentation }
    init(world: World) {}
    func update(context: UpdateContext) { recordReviewFixed(context) }
}

@MainActor private func reviewFixedWorld() -> World {
    let world = World()
    world.fixedStep = .init(stepsPerSecond: 8)
    world.resources.set(ReviewFixedTrace())
    world.addSystem(ReviewFixedFirst.self)
    world.addSystem(ReviewFixedSecond.self)
    world.addSystem(ReviewFixedVariable.self)
    world.addSystem(ReviewFixedPresentation.self)
    return world
}

@MainActor @Suite struct ReviewFixedLifecycleTests {
    @Test(arguments: ["updateEvent", "fixedEvent", "fixedSystem"])
    func debugTimeScaleChangesPreserveOneCompleteFixedTick(stage: String) throws {
        let world = reviewFixedWorld()
        world.isPaused = true
        var tokens: [EventSubscription] = []
        switch stage {
        case "updateEvent":
            tokens.append(world.subscribe(to: WorldEvents.Update.self) { _ in world.timeScale = 0 })
        case "fixedEvent":
            tokens.append(world.subscribe(to: WorldEvents.FixedUpdate.self) { _ in world.timeScale = 0 })
        default:
            world.resources[ReviewFixedTrace.self]?.fixedAction = { $0.timeScale = 0 }
        }
        defer { tokens.forEach { $0.cancel() } }

        let frame = try #require(world.beginFrame(deltaTime: 0.0625, debugStep: true))
        world.finishFrame(frame)

        #expect(world.resources[ReviewFixedTrace.self]?.phases == [
            .fixedSimulation, .fixedSimulation, .simulation, .presentation
        ])
        #expect(world.resources[ReviewFixedTrace.self]?.deltas == [0.125, 0.125, 0.0625, 0.0625])
        #expect(world.resources[ReviewFixedTrace.self]?.unscaledDeltas == [0.125, 0.125, 0.0625, 0.0625])
        #expect(world.resources[ReviewFixedTrace.self]?.ticks == [1, 1, nil, nil])
        #expect(world.fixedStepState.tick == 1 && world.fixedStepState.ticksThisFrame == 1)
        #expect(world.fixedStepState.simulationTime == 0.125)
        #expect(world.fixedStepState.interpolationAlpha == 1)
        #expect(world.isPaused && world.timeScale == 0)
        #expect(!world.isDebugStepping && !world.isFixedUpdating)
    }

    @Test(arguments: ["updateEvent", "fixedEvent", "fixedSystem"])
    func debugConfigurationChangesStillInvalidateFixedWork(stage: String) throws {
        let world = reviewFixedWorld()
        world.isPaused = true
        let change: @MainActor (World) -> Void = { $0.fixedStep = .init(stepsPerSecond: 16) }
        var tokens: [EventSubscription] = []
        switch stage {
        case "updateEvent":
            tokens.append(world.subscribe(to: WorldEvents.Update.self) { _ in change(world) })
        case "fixedEvent":
            tokens.append(world.subscribe(to: WorldEvents.FixedUpdate.self) { _ in change(world) })
        default:
            world.resources[ReviewFixedTrace.self]?.fixedAction = change
        }
        defer { tokens.forEach { $0.cancel() } }

        let frame = try #require(world.beginFrame(deltaTime: 0.0625, debugStep: true))
        world.finishFrame(frame)

        let expectedPhases: [SystemPhase] = stage == "fixedSystem"
            ? [.fixedSimulation, .simulation, .presentation] : [.simulation, .presentation]
        #expect(world.resources[ReviewFixedTrace.self]?.phases == expectedPhases)
        #expect(world.fixedStepState.tick == (stage == "updateEvent" ? 0 : 1))
        #expect(world.fixedStepState.ticksThisFrame == 0)
        #expect(world.fixedStepState.interpolationAlpha == 0)
        #expect(world.isPaused && !world.isDebugStepping && !world.isFixedUpdating)
    }

    @Test func rootActivationCallbackKeepsFreshDescendantSamplesAndRemainder() throws {
        let world = reviewFixedWorld()
        let parent = Entity(components: TransformInterpolationComponent())
        let child = Entity(components: TransformInterpolationComponent())
        parent.addChild(child)
        world.addEntity(parent)
        world.update(deltaTime: 0.125)
        let oldSample = try #require(world.fixedTransformSample(for: child))
        world.root.isEnabled = false
        #expect(world.fixedTransformSample(for: child) == nil)

        var captured: [FixedTransformSample?] = []
        let token = world.subscribe(to: WorldEvents.DidChangeEntityActivation.self) { event in
            guard event.entity === world.root, event.isEnabledInHierarchy else { return }
            world.update(deltaTime: 0.1875)
            captured = [parent, child].map { world.fixedTransformSample(for: $0) }
        }
        defer { token.cancel() }

        world.root.isEnabled = true

        try #require(captured.count == 2)
        for (index, entity) in [parent, child].enumerated() {
            let fresh = try #require(captured[index])
            #expect(fresh.previous.translation.x == 1 && fresh.current.translation.x == 2)
            #expect(fresh != oldSample)
            #expect(world.fixedTransformSample(for: entity) == fresh)
        }
        #expect(world.fixedStepState.tick == 2 && world.fixedStepState.ticksThisFrame == 1)
        #expect(world.fixedStepState.interpolationAlpha == 0.5)

        world.update(deltaTime: 0)
        #expect(world.fixedStepState.tick == 2 && world.fixedStepState.ticksThisFrame == 0)
        #expect(world.fixedStepState.interpolationAlpha == 0.5)
        #expect(world.fixedTransformSample(for: parent) == captured[0])
        #expect(world.fixedTransformSample(for: child) == captured[1])
    }

    @Test(arguments: [false, true])
    func reentrantActivationRejectsOldSamplesAndPreservesOnlyFreshOnes(advanceDuringReactivation: Bool) throws {
        let world = reviewFixedWorld()
        let parent = Entity(components: TransformInterpolationComponent())
        let child = Entity(components: TransformInterpolationComponent())
        parent.addChild(child)
        world.addEntity(parent)
        world.update(deltaTime: 0.125)
        let oldSample = try #require(world.fixedTransformSample(for: child))
        var childTransitions: [Bool] = []
        var captured: FixedTransformSample?
        let token = world.subscribe(to: WorldEvents.DidChangeEntityActivation.self) { event in
            if event.entity === parent {
                if !event.isEnabledInHierarchy {
                    parent.isEnabled = true
                } else if advanceDuringReactivation {
                    world.update(deltaTime: 0.1875)
                    captured = world.fixedTransformSample(for: child)
                }
            }
            if event.entity === child { childTransitions.append(event.isEnabledInHierarchy) }
        }
        defer { token.cancel() }

        parent.isEnabled = false

        #expect(parent.isActive && child.isActive)
        #expect(childTransitions == [true])
        if advanceDuringReactivation {
            let fresh = try #require(captured)
            #expect(fresh != oldSample)
            #expect(fresh.previous.translation.x == 1 && fresh.current.translation.x == 2)
            #expect(world.fixedTransformSample(for: child) == fresh)
            world.update(deltaTime: 0)
            #expect(world.fixedTransformSample(for: child) == fresh)
            #expect(world.fixedStepState.tick == 2)
        } else {
            #expect(world.fixedTransformSample(for: parent) == nil)
            #expect(world.fixedTransformSample(for: child) == nil)
            #expect(world.fixedStepState.tick == 1)
        }
    }
}
