@_spi(Backend) import ECSCore
import Foundation
import Testing

private struct DiagnosticSample: Equatable {
    let phase: SystemPhase
    let delta: TimeInterval
    let unscaledDelta: TimeInterval
    let paused: Bool
    let stepping: Bool
}

private struct DiagnosticTrace: Component {
    var samples: [DiagnosticSample] = []
    var simulationAction: (@MainActor (World) -> Void)?
    var presentationAction: (@MainActor (World) -> Void)?
}

private struct DiagnosticSimulation: System {
    static var dependencies: [SystemDependency] { [.before(DiagnosticSecond.self)] }
    init(world: World) {}
    func update(context: UpdateContext) {
        recordDiagnosticSample(context)
        context.world.resources[DiagnosticTrace.self]?.simulationAction?(context.world)
    }
}

private struct DiagnosticSecond: System {
    init(world: World) {}
    func update(context: UpdateContext) { recordDiagnosticSample(context) }
}

private struct DiagnosticPresentation: System {
    static var phase: SystemPhase { .presentation }
    init(world: World) {}
    func update(context: UpdateContext) {
        recordDiagnosticSample(context)
        context.world.resources[DiagnosticTrace.self]?.presentationAction?(context.world)
    }
}

@MainActor private func recordDiagnosticSample(_ context: UpdateContext) {
    context.world.resources[DiagnosticTrace.self]?.samples.append(
        DiagnosticSample(phase: context.phase, delta: context.deltaTime,
                         unscaledDelta: context.unscaledDeltaTime,
                         paused: context.world.isPaused, stepping: context.world.isDebugStepping)
    )
}

@MainActor private func diagnosticWorld() -> World {
    let world = World()
    world.resources.set(DiagnosticTrace())
    world.addSystem(DiagnosticPresentation.self)
    world.addSystem(DiagnosticSecond.self)
    world.addSystem(DiagnosticSimulation.self)
    return world
}

@MainActor @Suite struct DiagnosticsTests {
    @Test func profilingDefaultsOffAndDoesNotCollect() {
        let world = diagnosticWorld()
        #expect(!world.isProfilingEnabled)
        world.update(deltaTime: 1)
        #expect(world.lastSystemTimings.isEmpty)
        #expect(world.resources[DiagnosticTrace.self]?.samples.count == 3)
    }

    @Test func timingsFollowResolvedOrderAndReplaceThePreviousFrame() throws {
        let world = diagnosticWorld()
        world.isProfilingEnabled = true
        let frame = try #require(world.beginFrame(deltaTime: 100))
        #expect(world.lastSystemTimings.map(\.name) == [String(reflecting: DiagnosticSimulation.self),
                                                      String(reflecting: DiagnosticSecond.self)])
        world.finishFrame(frame)
        #expect(world.lastSystemTimings.map(\.name) == [String(reflecting: DiagnosticSimulation.self),
                                                      String(reflecting: DiagnosticSecond.self),
                                                      String(reflecting: DiagnosticPresentation.self)])
        #expect(world.lastSystemTimings.map(\.phase) == [.simulation, .simulation, .presentation])
        #expect(world.lastSystemTimings.allSatisfy { $0.duration.isFinite && $0.duration > 0 && $0.duration < 100 })
        world.systems.remove(DiagnosticSecond.self)
        world.update(deltaTime: 100)
        #expect(world.lastSystemTimings.map(\.phase) == [.simulation, .presentation])
        world.systems.remove(DiagnosticSimulation.self)
        world.systems.remove(DiagnosticPresentation.self)
        world.update(deltaTime: 100)
        #expect(world.lastSystemTimings.isEmpty)
    }

    @Test func timingsExcludeDisabledAndRemovedSystemsImmediately() {
        let world = diagnosticWorld()
        world.isProfilingEnabled = true
        world.resources[DiagnosticTrace.self]?.simulationAction = { world in
            world.systems.remove(DiagnosticSecond.self)
            world.systems.setEnabled(false, for: DiagnosticPresentation.self)
        }
        world.update(deltaTime: 1)
        #expect(world.lastSystemTimings.map(\.name) == [String(reflecting: DiagnosticSimulation.self)])
        #expect(world.resources[DiagnosticTrace.self]?.samples.count == 1)
    }

    @Test func disablingProfilingClearsAndCannotRestoreInflightMeasurements() throws {
        let world = diagnosticWorld()
        world.isProfilingEnabled = true
        let frame = try #require(world.beginFrame(deltaTime: 1))
        #expect(world.lastSystemTimings.count == 2)
        world.isProfilingEnabled = false
        #expect(world.lastSystemTimings.isEmpty)
        world.isProfilingEnabled = true
        world.finishFrame(frame)
        #expect(world.lastSystemTimings.isEmpty)
        world.update(deltaTime: 1)
        #expect(world.lastSystemTimings.count == 3)
        world.isProfilingEnabled = false
        world.update(deltaTime: 1)
        #expect(world.lastSystemTimings.isEmpty)
    }

    @Test func enablingProfilingMidframeTakesEffectNextFrame() throws {
        let world = diagnosticWorld()
        let frame = try #require(world.beginFrame(deltaTime: 1))
        world.isProfilingEnabled = true
        world.finishFrame(frame)
        #expect(world.lastSystemTimings.isEmpty)
        world.update(deltaTime: 1)
        #expect(world.lastSystemTimings.count == 3)
    }

    @Test(arguments: [SystemPhase.simulation, .presentation])
    func disablingProfilingInsideSystemCannotPublishStaleTimings(phase: SystemPhase) {
        let world = diagnosticWorld()
        world.isProfilingEnabled = true
        let disable: @MainActor (World) -> Void = { world in
            world.isProfilingEnabled = false
            world.isProfilingEnabled = true
        }
        if phase == .simulation {
            world.resources[DiagnosticTrace.self]?.simulationAction = disable
        } else {
            world.resources[DiagnosticTrace.self]?.presentationAction = disable
        }
        world.update(deltaTime: 1)
        #expect(world.lastSystemTimings.isEmpty)
    }

    @Test(arguments: [0.0, 0.25, 4.0])
    func debugStepRunsBothPhasesAtOneTimescaleWithoutPauseCallbacks(scale: Double) throws {
        let world = diagnosticWorld()
        world.isPaused = true
        world.timeScale = scale
        world.isProfilingEnabled = true
        var changes = 0
        var updateDeltas: [TimeInterval] = []
        let simulationToken = world.subscribe(to: WorldEvents.SimulationDidChange.self) { _ in changes += 1 }
        let updateToken = world.subscribe(to: WorldEvents.Update.self) { event in
            #expect(world.isPaused && world.isDebugStepping)
            updateDeltas.append(event.deltaTime)
        }
        let frame = try #require(world.beginFrame(deltaTime: 0.012, debugStep: true))
        #expect(frame.isDebugStep && world.isDebugStepping && world.isPaused)
        #expect(frame.deltaTime == 0.012 && frame.unscaledDeltaTime == 0.012)
        #expect(world.resources[DiagnosticTrace.self]?.samples.count == 2)
        world.resources[DiagnosticTrace.self]?.presentationAction = { world in
            #expect(world.isDebugStepping && world.isPaused)
        }
        world.finishFrame(frame)
        world.finishFrame(frame)
        #expect(!world.isDebugStepping && world.isPaused && world.timeScale == scale)
        #expect(updateDeltas == [0.012] && changes == 0)
        #expect(world.resources[DiagnosticTrace.self]?.samples == [
            DiagnosticSample(phase: .simulation, delta: 0.012, unscaledDelta: 0.012, paused: true, stepping: true),
            DiagnosticSample(phase: .simulation, delta: 0.012, unscaledDelta: 0.012, paused: true, stepping: true),
            DiagnosticSample(phase: .presentation, delta: 0.012, unscaledDelta: 0.012, paused: true, stepping: true)
        ])
        #expect(world.lastSystemTimings.map(\.phase) == [.simulation, .simulation, .presentation])
        withExtendedLifetime((simulationToken, updateToken)) {}
    }

    @Test func debugStepRejectsReentryInCallbacksSystemsAndBetweenPhases() throws {
        let world = diagnosticWorld()
        world.isPaused = true
        var callbacks = 0
        let token = world.subscribe(to: WorldEvents.Update.self) { _ in
            callbacks += 1
            #expect(world.beginFrame(deltaTime: 1, debugStep: true) == nil)
            #expect(world.beginFrame(deltaTime: 1) == nil)
            world.update(deltaTime: 1)
        }
        world.resources[DiagnosticTrace.self]?.simulationAction = { world in
            #expect(world.beginFrame(deltaTime: 1, debugStep: true) == nil)
        }
        let frame = try #require(world.beginFrame(deltaTime: 1, debugStep: true))
        #expect(world.beginFrame(deltaTime: 1, debugStep: true) == nil)
        world.isPaused = false
        #expect(world.beginFrame(deltaTime: 1) == nil)
        world.isPaused = true
        let otherWorld = World()
        otherWorld.finishFrame(frame)
        #expect(world.isDebugStepping)
        world.resources[DiagnosticTrace.self]?.presentationAction = { world in
            world.finishFrame(frame)
            #expect(world.isDebugStepping)
            #expect(world.beginFrame(deltaTime: 1, debugStep: true) == nil)
        }
        world.finishFrame(frame)
        #expect(!world.isDebugStepping && callbacks == 1)
        let next = try #require(world.beginFrame(deltaTime: 1, debugStep: true))
        world.finishFrame(next)
        #expect(!world.isDebugStepping && callbacks == 2)
        withExtendedLifetime(token) {}
    }

    @Test func debugStepRequiresPausedEnabledWorldAndNoRunningSystems() throws {
        let world = diagnosticWorld()
        #expect(world.beginFrame(deltaTime: 1, debugStep: true) == nil)
        world.isPaused = true
        world.root.isEnabled = false
        #expect(world.beginFrame(deltaTime: 1, debugStep: true) == nil)
        #expect(!world.isDebugStepping)
        world.root.isEnabled = true
        world.isPaused = false
        world.resources[DiagnosticTrace.self]?.simulationAction = { world in
            world.isPaused = true
            #expect(world.beginFrame(deltaTime: 1, debugStep: true) == nil)
        }
        let normal = try #require(world.beginFrame(deltaTime: 1))
        #expect(!normal.isDebugStep && !world.isDebugStepping)
        world.finishFrame(normal)
    }

    @Test(arguments: [0.0, -1.0, Double.nan, Double.infinity, -Double.infinity])
    func debugStepRejectsInvalidDeltaWithoutEvents(delta: Double) {
        let world = diagnosticWorld()
        world.isPaused = true
        var events = 0
        let token = world.subscribe(to: WorldEvents.Update.self) { _ in events += 1 }
        #expect(world.beginFrame(deltaTime: delta, debugStep: true) == nil)
        #expect(!world.isDebugStepping && world.isPaused && events == 0)
        #expect(world.resources[DiagnosticTrace.self]?.samples.isEmpty == true)
        withExtendedLifetime(token) {}
    }

    @Test func finishingDisabledDebugFrameResetsFlagAndSkipsPresentation() throws {
        let world = diagnosticWorld()
        world.isPaused = true
        world.isProfilingEnabled = true
        let frame = try #require(world.beginFrame(deltaTime: 1, debugStep: true))
        world.root.isEnabled = false
        world.finishFrame(frame)
        #expect(!world.isDebugStepping && world.isPaused)
        #expect(world.resources[DiagnosticTrace.self]?.samples.count == 2)
        #expect(world.lastSystemTimings.map(\.phase) == [.simulation, .simulation])
        world.root.isEnabled = true
        world.finishFrame(frame)
        #expect(world.resources[DiagnosticTrace.self]?.samples.count == 2)
        let next = try #require(world.beginFrame(deltaTime: 1, debugStep: true))
        world.finishFrame(next)
        #expect(!world.isDebugStepping)
    }

    @Test func disablingRootDuringUpdateSkipsBothDebugPhasesAndStillFinishes() throws {
        let world = diagnosticWorld()
        world.isPaused = true
        let token = world.subscribe(to: WorldEvents.Update.self) { _ in world.root.isEnabled = false }
        let frame = try #require(world.beginFrame(deltaTime: 1, debugStep: true))
        #expect(world.isDebugStepping)
        #expect(world.resources[DiagnosticTrace.self]?.samples.isEmpty == true)
        world.finishFrame(frame)
        #expect(!world.isDebugStepping && world.isPaused)
        #expect(world.resources[DiagnosticTrace.self]?.samples.isEmpty == true)
        withExtendedLifetime(token) {}
    }

    @Test func ordinaryPresentationUsesCurrentPauseState() throws {
        let world = diagnosticWorld()
        world.resources[DiagnosticTrace.self]?.simulationAction = { $0.isPaused = true }
        let frame = try #require(world.beginFrame(deltaTime: 1))
        world.isPaused = false
        world.finishFrame(frame)
        #expect(world.resources[DiagnosticTrace.self]?.samples.map(\.phase) == [.simulation, .presentation])
    }

    @Test func defaultFramesStillHonorPauseAndTimescaleChangesDuringFrame() throws {
        let world = diagnosticWorld()
        world.isProfilingEnabled = true
        world.timeScale = 0.5
        world.resources[DiagnosticTrace.self]?.simulationAction = { $0.isPaused = true }
        let frame = try #require(world.beginFrame(deltaTime: 2))
        #expect(!frame.isDebugStep && frame.deltaTime == 1 && frame.unscaledDeltaTime == 2)
        world.finishFrame(frame)
        #expect(world.resources[DiagnosticTrace.self]?.samples.count == 1)
        #expect(world.lastSystemTimings.count == 1 && !world.isDebugStepping)
        world.isPaused = false
        world.resources[DiagnosticTrace.self]?.simulationAction = nil
        let second = try #require(world.beginFrame(deltaTime: 2))
        world.timeScale = 0
        world.finishFrame(second)
        #expect(world.lastSystemTimings.map(\.phase) == [.simulation, .simulation])
        #expect(world.resources[DiagnosticTrace.self]?.samples.count == 3)
    }
}
