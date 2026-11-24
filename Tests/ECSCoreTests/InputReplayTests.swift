import Foundation
@_spi(Backend) @testable import ECSCore
import Testing

private enum ReplayTestFailure: Error, Equatable { case capture, restore, checksum, unavailable }
enum ReplayTestInterrupt: CaseIterable, Sendable { case pause, resetClock, configuration, deactivate, restore }
private let replayTestMove = InputAction("move", kind: .axis)
private let replayTestFire = InputAction("fire")

private struct ReplayTestState: Codable, Equatable {
    var ticks = 0
    var position = 0.0
    var shots = 0
    var late = 0
    var events: [InputActionPhase] = []
}

@MainActor private final class ReplayTestProbe {
    var controller: InputReplayController?
    var state = ReplayTestState()
    var errors: [String] = []
    var finish = true
    var duplicateSample = false
    var samplesMatch = true
    var lateAddition = 0
    var interrupt: ReplayTestInterrupt?
    var captureThrows = false
    var restoreThrows = false
    var checksumThrows = false
    var checksumCalls = 0
    var captureCallback: (() throws -> Void)?
    var checksumCallback: (() throws -> Void)?
    var variableCalls = 0
    var presentationCalls = 0
    var delta: Double = 0
    var unscaledDelta: Double = 0

    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state)
    }
}

private struct ReplayTestRuntime: Component { let probe: ReplayTestProbe }

@MainActor private struct ReplayTestSystem: System {
    static var phase: SystemPhase { .fixedSimulation }
    static var dependencies: [SystemDependency] { [.before(ReplayTestLateSystem.self)] }
    init(world: World) {}
    func update(context: UpdateContext) {
        guard let probe = context.world.resources[ReplayTestRuntime.self]?.probe,
              let controller = probe.controller else { return }
        do {
            let sample = try controller.sample(for: context)
            if controller.state == .finished { return }
            if probe.duplicateSample {
                let repeated = try controller.sample(for: context)
                probe.samplesMatch = probe.samplesMatch && repeated == sample
            }
            probe.delta = context.deltaTime
            probe.unscaledDelta = context.unscaledDeltaTime
            probe.state.ticks += 1
            probe.state.position += Double(sample.value(for: replayTestMove).scalar) * context.deltaTime
            probe.state.shots += sample.events.filter { $0.action == replayTestFire && $0.phase == .pressed }.count
            probe.state.events += sample.events.map(\.phase)
            if probe.finish { try controller.finishTick(context) }
        } catch {
            probe.errors.append(String(describing: error))
            context.world.isPaused = true
        }
    }
}

@MainActor private struct ReplayTestLateSystem: System {
    static var phase: SystemPhase { .fixedSimulation }
    init(world: World) {}
    func update(context: UpdateContext) {
        guard let probe = context.world.resources[ReplayTestRuntime.self]?.probe else { return }
        probe.state.late += probe.lateAddition
        switch probe.interrupt {
        case .pause: context.world.isPaused = true
        case .resetClock: context.world.resetFixedStepClock()
        case .configuration: context.world.fixedStep = .init(stepsPerSecond: 30)
        case .deactivate: context.world.root.isEnabled = false
        case .restore: context.world.restore(WorldSnapshot(entities: []))
        case nil: break
        }
    }
}

@MainActor private struct ReplayTestVariableSystem: System {
    init(world: World) {}
    func update(context: UpdateContext) { context.world.resources[ReplayTestRuntime.self]?.probe.variableCalls += 1 }
}

@MainActor private struct ReplayTestPresentationSystem: System {
    static var phase: SystemPhase { .presentation }
    init(world: World) {}
    func update(context: UpdateContext) { context.world.resources[ReplayTestRuntime.self]?.probe.presentationCalls += 1 }
}

@MainActor @Suite struct InputReplayTests {
    @MainActor private final class Fixture {
        let world = World()
        let probe = ReplayTestProbe()
        let input = InputController(contexts: [.init(name: "play", bindings: [
            .init(replayTestMove, control: .virtual("move")),
            .init(replayTestFire, control: .virtual("fire"))
        ])])
        let controller: InputReplayController

        init(maximumFrames: Int = 36_000, withChecksum: Bool = true) {
            let probe = self.probe
            let checksumProvider: (@MainActor () throws -> Data)?
            if withChecksum {
                checksumProvider = { [weak probe] in
                    guard let probe else { throw ReplayTestFailure.unavailable }
                    if probe.checksumThrows { throw ReplayTestFailure.checksum }
                    probe.checksumCalls += 1
                    try probe.checksumCallback?()
                    return try probe.data()
                }
            } else { checksumProvider = nil }
            controller = InputReplayController(world: world, input: input, maximumFrames: maximumFrames,
                captureState: { [weak probe] in
                    guard let probe else { throw ReplayTestFailure.unavailable }
                    if probe.captureThrows { throw ReplayTestFailure.capture }
                    try probe.captureCallback?()
                    return try probe.data()
                }, restoreState: { [weak probe] data in
                    guard let probe else { throw ReplayTestFailure.unavailable }
                    if probe.restoreThrows { throw ReplayTestFailure.restore }
                    probe.state = try JSONDecoder().decode(ReplayTestState.self, from: data)
                }, checksum: checksumProvider)
            probe.controller = controller
            world.fixedStep = .init(stepsPerSecond: 20)
            world.resources.set(ReplayTestRuntime(probe: probe))
            world.addSystem(ReplayTestSystem.self)
            world.addSystem(ReplayTestLateSystem.self)
            world.addSystem(ReplayTestVariableSystem.self)
            world.addSystem(ReplayTestPresentationSystem.self)
        }

        func tap() {
            input.setValue(.button(true), for: .virtual("fire"), device: .virtual("fire"))
            input.setValue(.button(false), for: .virtual("fire"), device: .virtual("fire"))
        }

        func tape(ticks: Int = 8) throws -> InputRecording {
            try controller.startRecording()
            for index in 0..<ticks {
                input.setValue(.axis(index.isMultiple(of: 2) ? 1 : -1),
                               for: .virtual("move"), device: .virtual("move"))
                if index.isMultiple(of: 3) { tap() }
                world.update(deltaTime: 0.05)
            }
            try controller.stop()
            return try #require(controller.recording)
        }
    }

    @Test(arguments: [30, 60, 120])
    func recordingReplaysTheSameRulesAtDifferentDisplayCadences(fps: Int) throws {
        let f = Fixture()
        let tape = try f.tape()
        let expected = f.probe.state
        let lifetime = f.world.fixedStepState.tick
        try f.controller.startPlayback(tape)
        for _ in 0..<(fps * 2) where f.controller.state == .playing {
            f.world.update(deltaTime: 1.0 / Double(fps))
        }
        #expect(f.controller.state == .finished)
        #expect(f.controller.divergence == nil && f.controller.lastError == nil)
        #expect(f.probe.state == expected)
        #expect(f.world.fixedStepState.tick == lifetime + UInt64(tape.frames.count))
        #expect(f.world.isPaused && f.probe.errors.isEmpty)
        #expect(tape.frames.map(\.tick) == Array(1...8).map(UInt64.init))
    }

    @Test func oneTickSharesOneSampleAndCommitsAfterLaterSystems() throws {
        let f = Fixture()
        f.probe.duplicateSample = true
        f.probe.lateAddition = 5
        try f.controller.startRecording()
        f.tap(); f.tap()
        f.world.update(deltaTime: 0.05)
        let tape = try #require(f.controller.recording)
        #expect(f.probe.samplesMatch && f.probe.state.shots == 2)
        #expect(f.probe.state.events == [.pressed, .released, .pressed, .released])
        #expect(tape.frames.count == 1 && f.probe.checksumCalls == 1)
        #expect(tape.frames[0].checksum == InputRecordingChecksum(data: try f.probe.data()))
        #expect(f.probe.state.late == 5)
    }

    @Test func pausedSteppingChangesOnlyCustomFixedSimulationAndKeepsArchiveImmutable() throws {
        let f = Fixture()
        let tape = try f.tape(ticks: 3)
        let bytes = try tape.jsonData()
        try f.controller.startPlayback(tape, paused: true)
        let initialTick = f.world.fixedStepState.tick
        let variable = f.probe.variableCalls, presentation = f.probe.presentationCalls
        var updates = 0
        let token = f.world.subscribe(to: WorldEvents.Update.self) { _ in updates += 1 }
        defer { token.cancel() }
        try f.controller.setPlaybackSpeed(4)
        for index in 1...3 {
            try f.controller.step()
            #expect(f.probe.state.ticks == index)
            #expect(f.world.fixedStepState.tick == initialTick + UInt64(index))
            #expect(f.probe.delta == 0.05 && f.probe.unscaledDelta == 0.05)
            #expect(f.probe.variableCalls == variable && f.probe.presentationCalls == presentation)
            #expect(!f.world.isDebugStepping && f.world.isPaused && updates == 0)
        }
        #expect(f.controller.state == .finished)
        #expect(try f.controller.recording?.jsonData() == bytes)
    }

    @Test func pausePlayAndSpeedChangePacingWithoutChangingFixedDelta() throws {
        let f = Fixture()
        let tape = try f.tape(ticks: 8)
        try f.controller.startPlayback(tape)
        f.world.update(deltaTime: 0.05)
        try f.controller.pause()
        let tick = f.world.fixedStepState.tick
        f.world.update(deltaTime: 10)
        #expect(f.world.fixedStepState.tick == tick)
        try f.controller.setPlaybackSpeed(2)
        try f.controller.play()
        f.world.update(deltaTime: 0.05)
        #expect(f.world.fixedStepState.tick == tick + 2 && f.probe.delta == 0.05)
        #expect(f.controller.playbackSpeed == 2 && f.world.timeScale == 2)
        for invalid in [Double.nan, .infinity, 0, 0.09, 4.01] {
            #expect(throws: InputReplayError.invalidPlaybackSpeed) { try f.controller.setPlaybackSpeed(invalid) }
            #expect(f.controller.playbackSpeed == 2 && f.world.timeScale == 2)
        }
    }

    @Test func liveInputCannotLeakIntoPlaybackAndMustReturnToNeutralAfterStop() throws {
        let f = Fixture()
        let tape = try f.tape(ticks: 4)
        let expected = f.probe.state
        try f.controller.startPlayback(tape)
        f.input.setValue(.button(true), for: .virtual("fire"), device: .virtual("fire"))
        #expect(!f.input.value(for: replayTestFire).isPressed)
        f.world.update(deltaTime: 0.2)
        #expect(f.controller.state == .finished && f.probe.state == expected)
        try f.controller.stop()
        f.input.setValue(.button(true), for: .virtual("fire"), device: .virtual("fire"))
        #expect(!f.input.value(for: replayTestFire).isPressed)
        f.input.setValue(.button(false), for: .virtual("fire"), device: .virtual("fire"))
        f.tap()
        f.world.update(deltaTime: 0.05)
        #expect(f.probe.state.shots == expected.shots + 1)
    }

    @Test(arguments: [false, true])
    func harmlessHostClockResetsAtCompletedBoundariesKeepTheSession(recording: Bool) throws {
        let f = Fixture()
        if recording { try f.controller.startRecording() }
        else { try f.controller.startPlayback(f.tape(ticks: 5)) }
        f.world.update(deltaTime: 0.05)
        f.world.resetFixedStepClock()
        f.world.isPaused = true
        f.world.root.isEnabled = false
        f.world.root.isEnabled = true
        f.world.isPaused = false
        f.world.update(deltaTime: 0.05)
        #expect(f.controller.state == (recording ? .recording : .playing))
        #expect(f.controller.lastError == nil && f.probe.errors.isEmpty)
        #expect(f.controller.recording?.frames.count == (recording ? 2 : 5))
    }

    @Test(arguments: ReplayTestInterrupt.allCases)
    func interruptedTicksNeverEnterTheArchive(interrupt: ReplayTestInterrupt) throws {
        let f = Fixture()
        try f.controller.startRecording()
        f.probe.interrupt = interrupt
        f.world.update(deltaTime: 0.05)
        #expect(f.controller.state == .failed && f.world.isPaused)
        #expect(f.controller.recording?.frames.isEmpty == true)
        #expect(f.controller.lastError as? InputReplayError == .incompleteTick)
        // Partial application rules are not rolled back by rejecting the tape tick.
        #expect(f.probe.state.ticks == 1)
    }

    @Test func missingFinishFailsClosedAndDoesNotLeakCompletionIntoAnotherSession() throws {
        let f = Fixture()
        f.probe.finish = false
        try f.controller.startRecording()
        f.world.update(deltaTime: 0.05)
        #expect(f.controller.state == .failed && f.controller.recording?.frames.isEmpty == true)
        try f.controller.stop()
        f.probe.finish = true
        try f.controller.startRecording()
        f.world.update(deltaTime: 0.05)
        #expect(f.controller.state == .recording && f.controller.recording?.frames.count == 1)
    }

    @Test func overflowAndCapacityFailuresDoNotRunAnotherOwnedRule() throws {
        let overflow = Fixture()
        try overflow.controller.startRecording()
        for _ in 0..<129 { overflow.tap() }
        overflow.world.update(deltaTime: 0.05)
        #expect(overflow.controller.lastError as? InputRecordingError == .inputOverflow)
        #expect(overflow.controller.recording?.frames.isEmpty == true && overflow.probe.state.ticks == 0)

        let limited = Fixture(maximumFrames: 1)
        try limited.controller.startRecording()
        limited.world.update(deltaTime: 0.1)
        #expect(limited.controller.lastError as? InputRecordingError == .frameLimitReached)
        #expect(limited.controller.recording?.frames.count == 1 && limited.probe.state.ticks == 1)
    }

    @Test func divergenceReportsTheFirstRelativeTickAndPausesBeforeAnotherTick() throws {
        let f = Fixture()
        let tape = try f.tape(ticks: 4)
        try f.controller.startPlayback(tape, paused: true)
        f.probe.state.shots += 1
        try f.controller.step()
        let mismatch = try #require(f.controller.divergence)
        #expect(f.controller.state == .diverged && f.world.isPaused)
        #expect(mismatch.tick == 1 && mismatch.expected == tape.frames[0].checksum)
        #expect(mismatch.actual != mismatch.expected)
        let tick = f.world.fixedStepState.tick
        f.world.update(deltaTime: 1)
        #expect(f.world.fixedStepState.tick == tick)
    }

    @Test func tapesWithChecksumsRequireAProviderBeforeStateIsRestored() throws {
        let source = Fixture()
        let tape = try source.tape(ticks: 1)
        let destination = Fixture(withChecksum: false)
        destination.probe.state.shots = 99
        #expect(throws: InputReplayError.checksumUnavailable) { try destination.controller.startPlayback(tape) }
        #expect(destination.probe.state.shots == 99 && destination.controller.state == .live)
        #expect(!destination.world.isPaused)
    }

    @Test func providerFailuresPauseAndRemainInspectable() throws {
        let capture = Fixture()
        capture.probe.captureThrows = true
        #expect(throws: ReplayTestFailure.capture) { try capture.controller.startRecording() }
        #expect(capture.controller.state == .failed && capture.world.isPaused)
        try capture.controller.stop()
        #expect(capture.controller.state == .live && !capture.world.isPaused)

        let f = Fixture()
        let tape = try f.tape(ticks: 1)
        f.probe.restoreThrows = true
        let before = f.probe.state
        #expect(throws: ReplayTestFailure.restore) { try f.controller.startPlayback(tape) }
        #expect(f.controller.state == .failed && f.probe.state == before)
        try f.controller.stop()
        f.probe.restoreThrows = false
        f.probe.checksumThrows = true
        try f.controller.startRecording()
        f.world.update(deltaTime: 0.05)
        #expect(f.controller.lastError as? ReplayTestFailure == .checksum)
        #expect(f.controller.recording?.frames.isEmpty == true)
    }

    @Test func providersCannotReenterReplayControls() throws {
        let f = Fixture()
        var rejected = false
        f.probe.captureCallback = { [weak controller = f.controller] in
            do { try controller?.startRecording() }
            catch { rejected = error as? InputReplayError == .reentrantOperation }
        }
        try f.controller.startRecording()
        #expect(rejected && f.controller.state == .recording)
        f.probe.checksumCallback = { [weak controller = f.controller] in
            #expect(throws: InputReplayError.reentrantOperation) { try controller?.stop() }
        }
        f.world.update(deltaTime: 0.05)
        #expect(f.controller.recording?.frames.count == 1)
    }

    @Test func wrongContextsAndChangedConfigurationFailClosed() throws {
        let f = Fixture()
        let wrong = UpdateContext(world: f.world, deltaTime: 0.05, unscaledDeltaTime: 0.05,
                                  phase: .fixedSimulation, fixedTick: 0)
        #expect(throws: InputReplayError.invalidContext) { _ = try f.controller.sample(for: wrong) }
        try f.controller.startRecording()
        f.world.fixedStep = .init(stepsPerSecond: 30)
        f.world.update(deltaTime: 1.0 / 30)
        #expect(f.controller.state == .failed && f.world.isPaused)
        #expect(f.controller.lastError as? InputReplayError == .configurationChanged)
    }

    @Test func unfinishedBackendFrameCannotBeReplacedToBypassControlGuards() throws {
        let f = Fixture()
        let frame = try #require(f.world.beginFrame(deltaTime: 0))
        let calls = f.probe.variableCalls
        f.world.update(deltaTime: 0)
        #expect(f.probe.variableCalls == calls)
        #expect(throws: InputReplayError.reentrantOperation) { try f.controller.startRecording() }
        f.world.isPaused = true
        #expect(!f.world.stepFixedSimulation())
        f.world.cancelFrame(frame)
        #expect(f.world.stepFixedSimulation())
        #expect(!f.world.isDebugStepping)
    }

    @Test func oneWorldHasOneActiveSessionAndStopRestoresPreferences() throws {
        let f = Fixture()
        let other = InputReplayController(world: f.world, input: InputController(),
            captureState: { Data() }, restoreState: { _ in })
        let tape = try f.tape(ticks: 4)
        f.world.timeScale = 0.5
        try f.controller.startPlayback(tape, paused: true)
        #expect(throws: InputReplayError.worldInUse) { try other.startRecording() }
        try f.controller.setPlaybackSpeed(3)
        try f.controller.stop()
        #expect(f.world.timeScale == 0.5 && !f.world.isPaused)
        try other.startRecording()
        try other.stop()
    }

    @Test func firstStopStillReleasesSessionAndInputAfterASkippedTick() throws {
        let f = Fixture()
        let tape = try f.tape(ticks: 3)
        try f.controller.startPlayback(tape)
        f.world.systems.setEnabled(false, for: ReplayTestSystem.self)
        f.world.update(deltaTime: 0.05)
        #expect(throws: InputReplayError.skippedTick) { try f.controller.stop() }
        #expect(f.controller.state == .live && !f.world.isPaused)
        #expect(f.input.acceptsInput && f.world.inputReplayOwner == nil)
        let other = InputReplayController(world: f.world, input: InputController(),
            captureState: { Data() }, restoreState: { _ in })
        try other.startRecording()
        try other.stop()
    }

    @Test func aDestroyedWorldIsNotKeptAliveByTheController() throws {
        var world: World? = World()
        weak var weakWorld = world
        let controller = InputReplayController(world: try #require(world), input: InputController(),
            captureState: { Data() }, restoreState: { _ in })
        world = nil
        #expect(weakWorld == nil)
        #expect(throws: InputReplayError.worldUnavailable) { try controller.startRecording() }
    }
}
