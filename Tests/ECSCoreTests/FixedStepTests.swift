@_spi(Backend) import ECSCore
import Foundation
import Testing

private struct FixedTrace: Component {
    var phases: [SystemPhase] = []
    var ticks: [UInt64?] = []
    var deltas: [Double] = []
    var unscaled: [Double] = []
    var alphas: [Double] = []
    var action: (@MainActor (UpdateContext) -> Void)?
}

@MainActor private func recordFixed(_ context: UpdateContext) {
    context.world.resources[FixedTrace.self]?.phases.append(context.phase)
    context.world.resources[FixedTrace.self]?.ticks.append(context.fixedTick)
    context.world.resources[FixedTrace.self]?.deltas.append(context.deltaTime)
    context.world.resources[FixedTrace.self]?.unscaled.append(context.unscaledDeltaTime)
    context.world.resources[FixedTrace.self]?.alphas.append(context.interpolationAlpha)
    context.world.resources[FixedTrace.self]?.action?(context)
}

private struct FixedProbe: System {
    static var phase: SystemPhase { .fixedSimulation }
    init(world: World) {}
    func update(context: UpdateContext) { recordFixed(context) }
}
private struct FixedLateProbe: System {
    static var phase: SystemPhase { .fixedSimulation }
    init(world: World) {}
    func update(context: UpdateContext) { recordFixed(context) }
}
private struct FixedVariableProbe: System {
    init(world: World) {}
    func update(context: UpdateContext) { recordFixed(context) }
}
private struct FixedPresentationProbe: System {
    static var phase: SystemPhase { .presentation }
    init(world: World) {}
    func update(context: UpdateContext) { recordFixed(context) }
}
private struct FixedConflictingProbe: System {
    static var phase: SystemPhase { .fixedSimulation }
    static var dependencies: [SystemDependency] { [.after(FixedVariableProbe.self)] }
    init(world: World) {}
    func update(context: UpdateContext) {}
}

@MainActor private func fixedWorld(_ configuration: FixedStepConfiguration? = .init()) -> World {
    let world = World()
    world.fixedStep = configuration
    world.resources.set(FixedTrace())
    // Deliberately install phases in reverse order.
    world.addSystem(FixedPresentationProbe.self)
    world.addSystem(FixedVariableProbe.self)
    world.addSystem(FixedProbe.self)
    return world
}

private func fixedNear(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-8 }

@MainActor @Suite struct FixedStepTests {
    @Test func configurationSanitizesAndRoundTrips() throws {
        let defaults = FixedStepConfiguration()
        #expect(defaults.stepsPerSecond == 60 && defaults.maximumCatchUpSteps == 8)
        #expect(defaults.maximumFrameDeltaTime == 0.25)
        #expect(defaults.stepDuration == 1.0 / 60)
        #expect(FixedStepConfiguration(stepsPerSecond: .nan, maximumFrameDeltaTime: .infinity) == defaults)
        let low = FixedStepConfiguration(stepsPerSecond: -4, maximumCatchUpSteps: -8, maximumFrameDeltaTime: -1)
        #expect(low.stepsPerSecond == 1 && low.maximumCatchUpSteps == 1 && low.maximumFrameDeltaTime == 0.001)
        let high = FixedStepConfiguration(stepsPerSecond: 4000, maximumCatchUpSteps: 999, maximumFrameDeltaTime: 90)
        #expect(high.stepsPerSecond == 1000 && high.maximumCatchUpSteps == 120 && high.maximumFrameDeltaTime == 10)
        #expect(try JSONDecoder().decode(FixedStepConfiguration.self, from: JSONEncoder().encode(high)) == high)
        let decoded = try JSONDecoder().decode(FixedStepConfiguration.self,
            from: Data(#"{"stepsPerSecond":-5,"maximumCatchUpSteps":999,"maximumFrameDeltaTime":99}"#.utf8))
        #expect(decoded.stepsPerSecond == 1 && decoded.maximumCatchUpSteps == 120 && decoded.maximumFrameDeltaTime == 10)
    }

    @Test(arguments: [30, 60, 120]) func equalTicksAtDisplayRates(fps: Int) {
        let world = fixedWorld()
        var lastTime = 0.0
        for index in 1...fps {
            let timestamp = Double(index) / Double(fps)
            world.update(deltaTime: timestamp - lastTime)
            lastTime = timestamp
        }
        #expect(world.fixedStepState.tick == 60)
        #expect(fixedNear(world.fixedStepState.simulationTime, 1))
        #expect(fixedNear(world.fixedStepState.interpolationAlpha, 0))
        #expect(world.resources[FixedTrace.self]?.phases.filter { $0 == .simulation }.count == fps)
    }

    @Test func nilConfigurationPreservesVariableFramesAndRawPhases() {
        let world = fixedWorld(nil)
        #expect(World().fixedStep == nil)
        #expect(SystemPhase.fixedSimulation.rawValue == -1)
        #expect(SystemPhase.simulation.rawValue == 0 && SystemPhase.presentation.rawValue == 1)
        world.timeScale = 2
        world.update(deltaTime: 1)
        #expect(world.resources[FixedTrace.self]?.phases == [.simulation, .presentation])
        #expect(world.resources[FixedTrace.self]?.deltas == [2, 2])
        #expect(world.resources[FixedTrace.self]?.ticks == [nil, nil])
        #expect(world.fixedStepState.tick == 0)
    }

    @Test func zeroTickFramesAndMultipleTicksPublishInOrder() {
        let world = fixedWorld(.init(stepsPerSecond: 10))
        var events: [String] = []
        let update = world.subscribe(to: WorldEvents.Update.self) { _ in
            #expect(!world.isFixedUpdating)
            events.append("update")
        }
        let fixed = world.subscribe(to: WorldEvents.FixedUpdate.self) { event in
            #expect(world.isFixedUpdating && event.world === world)
            #expect(event.deltaTime == 0.1 && event.unscaledDeltaTime == 0.1)
            events.append("fixed\(event.tick)")
        }
        world.update(deltaTime: 0.05)
        #expect(world.fixedStepState.ticksThisFrame == 0)
        #expect(fixedNear(world.fixedStepState.interpolationAlpha, 0.5))
        world.update(deltaTime: 0.2)
        #expect(events == ["update", "update", "fixed1", "fixed2"])
        #expect(world.fixedStepState.tick == 2 && world.fixedStepState.ticksThisFrame == 2)
        #expect(world.resources[FixedTrace.self]?.phases == [.simulation, .presentation, .fixedSimulation, .fixedSimulation, .simulation, .presentation])
        #expect(world.resources[FixedTrace.self]?.ticks == [nil, nil, 1, 2, nil, nil])
        #expect(!world.isFixedUpdating)
        withExtendedLifetime((update, fixed)) {}
    }

    @Test func defaultStallDropsClampedAndOverBudgetTime() {
        let world = fixedWorld()
        world.update(deltaTime: 0.5)
        #expect(world.fixedStepState.tick == 8)
        #expect(fixedNear(world.fixedStepState.droppedTime, 0.5 - 8.0 / 60))
        #expect(fixedNear(world.fixedStepState.interpolationAlpha, 0))
        world.update(deltaTime: 0)
        #expect(world.fixedStepState.ticksThisFrame == 0 && world.fixedStepState.droppedTime == 0)
    }

    @Test func clampPrecedesScalingAndBudgetPreservesFraction() throws {
        let world = fixedWorld(.init(stepsPerSecond: 10, maximumCatchUpSteps: 2, maximumFrameDeltaTime: 0.25))
        world.timeScale = 2
        let frame = try #require(world.beginFrame(deltaTime: 0.01, fixedDeltaTime: 0.525))
        world.finishFrame(frame)
        #expect(frame.deltaTime == 0.02 && frame.unscaledDeltaTime == 0.01)
        #expect(world.fixedStepState.tick == 2)
        #expect(fixedNear(world.fixedStepState.droppedTime, 0.85))
        #expect(world.resources[FixedTrace.self]?.deltas == [0.1, 0.1, 0.02, 0.02])
        #expect(world.resources[FixedTrace.self]?.unscaled == [0.05, 0.05, 0.01, 0.01])
        world.timeScale = 1
        let fractional = try #require(world.beginFrame(deltaTime: 0, fixedDeltaTime: 0.24))
        world.finishFrame(fractional)
        #expect(fixedNear(world.fixedStepState.interpolationAlpha, 0.4))
        let overflow = try #require(world.beginFrame(deltaTime: 0, fixedDeltaTime: 0.25))
        world.finishFrame(overflow)
        #expect(world.fixedStepState.ticksThisFrame == 2)
        #expect(fixedNear(world.fixedStepState.interpolationAlpha, 0.9))
    }

    @Test func catchUpDiscardsWholeStepsAndRetainsFraction() {
        let world = fixedWorld(.init(stepsPerSecond: 10, maximumCatchUpSteps: 2, maximumFrameDeltaTime: 10))
        world.update(deltaTime: 0.55)
        #expect(world.fixedStepState.tick == 2)
        #expect(fixedNear(world.fixedStepState.droppedTime, 0.3))
        #expect(fixedNear(world.fixedStepState.interpolationAlpha, 0.5))
        world.update(deltaTime: 0.05)
        #expect(world.fixedStepState.tick == 3)
        #expect(fixedNear(world.fixedStepState.interpolationAlpha, 0))
    }

    @Test func pauseConfigurationScaleRootAndExplicitResetClearDebtWithoutRewinding() {
        let world = fixedWorld(.init(stepsPerSecond: 10))
        world.update(deltaTime: 0.15)
        #expect(world.fixedStepState.tick == 1)
        world.isPaused = true
        world.update(deltaTime: 10)
        world.isPaused = false
        world.update(deltaTime: 0.05)
        #expect(world.fixedStepState.tick == 1)
        world.timeScale = 2
        world.update(deltaTime: 0.025)
        #expect(world.fixedStepState.tick == 1)
        world.fixedStep = .init(stepsPerSecond: 20)
        world.update(deltaTime: 0)
        #expect(world.fixedStepState.tick == 1)
        world.root.isEnabled = false
        world.update(deltaTime: 1)
        #expect(world.fixedStepState.tick == 1)
        // Root disablement must not suppress legacy variable systems.
        #expect(world.resources[FixedTrace.self]?.phases.suffix(2) == [.simulation, .presentation])
        world.root.isEnabled = true
        world.update(deltaTime: 0.02)
        world.resetFixedStepClock()
        world.update(deltaTime: 0)
        #expect(world.fixedStepState.tick == 1 && world.fixedStepState.ticksThisFrame == 0)
        #expect(fixedNear(world.fixedStepState.simulationTime, 0.1))
        #expect(world.fixedStepState.interpolationAlpha == 0)
    }

    @Test(arguments: [0.001, 0.5, 10.0]) func debugStepIsExactlyOneFixedTick(delta: Double) throws {
        let world = fixedWorld(.init(stepsPerSecond: 10))
        world.update(deltaTime: 0.05)
        world.isPaused = true
        world.timeScale = 0
        let frame = try #require(world.beginFrame(deltaTime: delta, debugStep: true))
        #expect(world.fixedStepState.tick == 1 && world.fixedStepState.ticksThisFrame == 1)
        #expect(frame.deltaTime == delta && frame.unscaledDeltaTime == delta)
        #expect(world.fixedStepState.interpolationAlpha == 1)
        world.finishFrame(frame)
        #expect(!world.isDebugStepping && !world.isFixedUpdating && world.isPaused)
        #expect(world.resources[FixedTrace.self]?.deltas.suffix(3) == [0.1, delta, delta])
        world.timeScale = 1
        world.isPaused = false
        world.update(deltaTime: 0.05)
        #expect(world.fixedStepState.tick == 1)
    }

    @Test(arguments: [-1.0, Double.nan, Double.infinity, -Double.infinity])
    func invalidInputsLeaveClockUntouched(delta: Double) {
        let world = fixedWorld()
        world.update(deltaTime: 0.02)
        let saved = world.fixedStepState
        #expect(world.beginFrame(deltaTime: delta) == nil)
        #expect(world.fixedStepState == saved)
        #expect(world.beginFrame(deltaTime: 0.01, fixedDeltaTime: delta) == nil)
        #expect(world.fixedStepState == saved)
    }

    @Test func extremeFiniteRawAndScaleNeverOverflowCountsOrDiagnostics() throws {
        let world = fixedWorld()
        world.timeScale = Double.greatestFiniteMagnitude
        let frame = try #require(world.beginFrame(deltaTime: 0, fixedDeltaTime: Double.greatestFiniteMagnitude))
        world.finishFrame(frame)
        #expect(world.fixedStepState.tick == 8)
        #expect(world.fixedStepState.droppedTime.isFinite)
        #expect(world.fixedStepState.interpolationAlpha.isFinite)
        #expect((0...1).contains(world.fixedStepState.interpolationAlpha))
        #expect(world.resources[FixedTrace.self]?.unscaled.allSatisfy(\.isFinite) == true)
    }

    @Test func additionsWaitForNextDisplayFrameAndRemovalDisableAreImmediate() {
        let world = fixedWorld(.init(stepsPerSecond: 10))
        var fixedCallbacks = 0
        let update = world.subscribe(to: WorldEvents.Update.self) { _ in world.addSystem(FixedLateProbe.self) }
        let fixed = world.subscribe(to: WorldEvents.FixedUpdate.self) { _ in
            fixedCallbacks += 1
            if fixedCallbacks == 1 { world.systems.setEnabled(false, for: FixedProbe.self) }
            if fixedCallbacks == 2 { world.systems.remove(FixedVariableProbe.self) }
        }
        world.update(deltaTime: 0.2)
        #expect(world.resources[FixedTrace.self]?.phases == [.presentation])
        world.update(deltaTime: 0.1)
        #expect(world.resources[FixedTrace.self]?.phases == [.presentation, .fixedSimulation, .presentation])
        withExtendedLifetime((update, fixed)) {}
    }

    @Test func additionsDuringTickAlsoWaitForNextDisplayFrame() {
        let world = fixedWorld(.init(stepsPerSecond: 10))
        world.resources[FixedTrace.self]?.action = { context in
            if context.phase == .fixedSimulation { context.world.addSystem(FixedLateProbe.self) }
        }
        world.update(deltaTime: 0.2)
        #expect(world.resources[FixedTrace.self]?.phases.filter { $0 == .fixedSimulation }.count == 2)
        world.update(deltaTime: 0.1)
        #expect(world.resources[FixedTrace.self]?.phases.filter { $0 == .fixedSimulation }.count == 4)
    }

    @Test func phaseConstraintsAreGenericAndConflictsLeaveScheduleUntouched() {
        let world = fixedWorld()
        let original = world.systems.types.map(ObjectIdentifier.init)
        #expect(throws: SystemSchedulingError.self) { try world.systems.add(FixedConflictingProbe.self) }
        #expect(world.systems.types.map(ObjectIdentifier.init) == original)
        #expect(world.systems.types.map { $0.phase } == [.fixedSimulation, .simulation, .presentation])
    }

    @Test func reentrantUpdatesAreRejectedAndTickResetCannotRestoreStaleDebt() {
        let world = fixedWorld(.init(stepsPerSecond: 10))
        var events = 0
        let token = world.subscribe(to: WorldEvents.FixedUpdate.self) { _ in
            events += 1
            #expect(world.beginFrame(deltaTime: 1) == nil)
            world.update(deltaTime: 1)
            world.resetFixedStepClock()
        }
        world.update(deltaTime: 0.25)
        #expect(events == 1 && world.fixedStepState.tick == 1)
        #expect(world.fixedStepState.interpolationAlpha == 0)
        #expect(world.fixedStepState.ticksThisFrame == 0)
        token.cancel()
        world.update(deltaTime: 0.05)
        #expect(world.fixedStepState.tick == 1)
    }

    @Test func settingsChangedDuringUpdateOrTickInvalidateFixedWork() {
        let world = fixedWorld(.init(stepsPerSecond: 10))
        let update = world.subscribe(to: WorldEvents.Update.self) { _ in world.timeScale = 2 }
        world.update(deltaTime: 0.2)
        #expect(world.fixedStepState.tick == 0)
        update.cancel()
        world.resources[FixedTrace.self]?.action = { context in
            if context.phase == .fixedSimulation { context.world.fixedStep = .init(stepsPerSecond: 20) }
        }
        world.update(deltaTime: 0.2)
        #expect(world.fixedStepState.tick == 1)
        #expect(world.fixedStepState.interpolationAlpha == 0 && world.fixedStepState.droppedTime == 0)
        world.resources[FixedTrace.self]?.action = nil
        world.update(deltaTime: 0)
        #expect(world.fixedStepState.tick == 1)
    }

    @Test func historyCapturesBeforeEventAndAfterSystemsAndRetainsZeroTickPair() throws {
        let world = fixedWorld(.init(stepsPerSecond: 10))
        let entity = Entity(components: TransformInterpolationComponent())
        world.addEntity(entity)
        let event = world.subscribe(to: WorldEvents.FixedUpdate.self) { _ in entity.position.x += 1 }
        world.resources[FixedTrace.self]?.action = { context in
            if context.phase == .fixedSimulation { entity.position.x += 2 }
        }
        world.update(deltaTime: 0.2)
        let sample = try #require(world.fixedTransformSample(for: entity))
        #expect(sample.previous.translation.x == 3 && sample.current.translation.x == 6)
        #expect(entity.position.x == 6) // Headless presentation never changes the model.
        world.update(deltaTime: 0.05)
        #expect(world.fixedTransformSample(for: entity) == sample)
        entity.position.x = 10
        #expect(world.fixedTransformSample(for: entity) == nil)
        withExtendedLifetime(event) {}
    }

    @Test func firstUnchangedPairIsValidAndSilentNonFixedWritesAreRejected() throws {
        let world = fixedWorld(.init(stepsPerSecond: 10))
        let entity = Entity(components: TransformInterpolationComponent())
        world.addEntity(entity)
        world.update(deltaTime: 0.1)
        let sample = try #require(world.fixedTransformSample(for: entity))
        #expect(sample.previous == .identity && sample.current == .identity)
        entity._setWithoutNotifying(Transform(translation: [4, 0]))
        #expect(world.fixedTransformSample(for: entity) == nil)
        entity._setWithoutNotifying(Transform.identity)
        #expect(world.fixedTransformSample(for: entity) == nil)
    }

    @Test func presentationTransformEditsImmediatelyInvalidateHistory() {
        let world = fixedWorld(.init(stepsPerSecond: 10))
        let entity = Entity(components: TransformInterpolationComponent())
        world.addEntity(entity)
        world.resources[FixedTrace.self]?.action = { context in
            if context.phase == .presentation { entity.position.x += 1 }
        }
        world.update(deltaTime: 0.1)
        #expect(world.fixedTransformSample(for: entity) == nil)
    }

    @Test func teleportMarkerResetDuringTickDiscardsThatPairAndNextTickRecovers() throws {
        let world = fixedWorld(.init(stepsPerSecond: 10))
        let entity = Entity(components: TransformInterpolationComponent())
        world.addEntity(entity)
        world.resources[FixedTrace.self]?.action = { context in
            guard context.phase == .fixedSimulation else { return }
            entity.position.x = 100
            entity.components[TransformInterpolationComponent.self]?.reset()
        }
        world.update(deltaTime: 0.1)
        #expect(world.fixedTransformSample(for: entity) == nil)
        #expect(entity.components[TransformInterpolationComponent.self]?.revision == 1)
        world.resources[FixedTrace.self]?.action = nil
        world.update(deltaTime: 0.1)
        let sample = try #require(world.fixedTransformSample(for: entity))
        #expect(sample.previous.translation.x == 100 && sample.current.translation.x == 100)
        entity.components.remove(TransformInterpolationComponent.self)
        #expect(world.fixedTransformSample(for: entity) == nil)
        entity.components.set(TransformInterpolationComponent())
        #expect(world.fixedTransformSample(for: entity) == nil)
    }

    @Test func activationReparentAndDetachInvalidateSamples() throws {
        let world = fixedWorld(.init(stepsPerSecond: 10))
        let entity = Entity(components: TransformInterpolationComponent())
        let parent = Entity()
        world.addEntity(entity)
        world.addEntity(parent)
        world.update(deltaTime: 0.1)
        #expect(world.fixedTransformSample(for: entity) != nil)
        entity.isEnabled = false
        entity.isEnabled = true
        #expect(world.fixedTransformSample(for: entity) == nil)
        world.update(deltaTime: 0.1)
        #expect(world.fixedTransformSample(for: entity) != nil)
        try entity.setParent(parent)
        #expect(world.fixedTransformSample(for: entity) == nil)
        world.update(deltaTime: 0.1)
        #expect(world.fixedTransformSample(for: entity) != nil)
        entity.removeFromParent()
        #expect(world.fixedTransformSample(for: entity) == nil)
        world.addEntity(entity)
        #expect(world.fixedTransformSample(for: entity) == nil)
    }

    @Test func resetAndDebugClearHistoryAndMarkerIsRegisteredForSnapshots() throws {
        let world = fixedWorld(.init(stepsPerSecond: 10))
        let entity = Entity(components: TransformInterpolationComponent())
        world.addEntity(entity)
        world.update(deltaTime: 0.1)
        #expect(ComponentRegistry.isRegistered(TransformInterpolationComponent.self))
        let saved = try WorldSnapshot(data: world.snapshot().jsonData())
        #expect(saved.entities.first?.components.contains { $0 is TransformInterpolationComponent } == true)
        world.resetFixedStepClock()
        #expect(world.fixedTransformSample(for: entity) == nil)
        world.isPaused = true
        let frame = try #require(world.beginFrame(deltaTime: 0.5, debugStep: true))
        world.finishFrame(frame)
        #expect(world.fixedTransformSample(for: entity) == nil)
        #expect(world.fixedStepState.tick == 2)
        world.restore(saved)
        #expect(world.fixedStepState.tick == 2 && world.fixedStepState.interpolationAlpha == 0)
    }
}
