import Foundation
import Dispatch

/// Scene-wide physics settings, independent of a rendering backend. Gravity is
/// measured in meters per second squared; sprite positions remain in points.
public struct PhysicsSimulationSettings: Equatable, Sendable, Codable {
    public var gravity: SIMD2<Float>
    public init(gravity: SIMD2<Float> = [0, -9.8]) { self.gravity = gravity }
}

/// A backend's in-flight frame. Keeps the schedule captured before the update
/// event, so installing a system during an update cannot reorder that frame.
@_spi(Backend)
@MainActor
public struct WorldFrame {
    let world: World
    let entries: [SystemEntry]
    public let deltaTime: TimeInterval
    public let unscaledDeltaTime: TimeInterval
    public let isDebugStep: Bool
    fileprivate let isFixedOnlyStep: Bool
    fileprivate let fixedConfiguration: FixedStepConfiguration?
    fileprivate let fixedEpoch: UInt64
    fileprivate let frameEpoch: UInt64
    fileprivate let frameTimeScale: Double
    fileprivate let isProfilingEnabled: Bool
    fileprivate let profilingRevision: UInt64
    fileprivate var completion: FrameCompletion
}

@MainActor
final class FrameCompletion {
    var finished = false
    var timings: [SystemTiming] = []
    var profileToken: EngineProfileToken?
    var profileFixedSteps = 0
    var profileDroppedTime: Double = 0
}

extension World {
    /// Advances exactly one custom fixed simulation tick at 1× while paused.
    /// Includes `FixedUpdate`, but no variable update, presentation, backend
    /// physics, or actions. Lifetime ticks are never rewound. Returns false when
    /// the root is inactive, the clock is unconfigured, or a frame is running.
    @discardableResult
    public func stepFixedSimulation() -> Bool {
        guard isPaused, root.isActive, let configuration = fixedStep,
              !isRunningSystems, !isDebugStepping, !isFixedUpdating,
              activeFrameCompletion?.finished != false,
              fixedStepState.tick < UInt64.max else { return false }
        resetFixedStepClock()
        fixedFrameEpoch &+= 1
        let frame = WorldFrame(world: self, entries: scheduledSystems,
                               deltaTime: configuration.stepDuration,
                               unscaledDeltaTime: configuration.stepDuration,
                               isDebugStep: false, isFixedOnlyStep: true,
                               fixedConfiguration: configuration, fixedEpoch: fixedStepEpoch,
                               frameEpoch: fixedFrameEpoch, frameTimeScale: 1,
                               isProfilingEnabled: isProfilingEnabled, profilingRevision: profilingRevision,
                               completion: FrameCompletion())
        let previousTick = fixedStepState.tick
        frame.completion.profileToken = profiler.beginWorldFrame(interval: configuration.stepDuration, debugStep: true)
        let profileStart = frame.completion.profileToken.map { _ in profiler.clock() }
        lastSystemTimings = []
        isRunningSystems = true
        isFixedSingleStepping = true
        defer {
            if let profileStart {
                sampleProfileWorkload(frame.completion.profileToken)
                profiler.recordWorldBegin(frame.completion.profileToken, duration: profiler.elapsed(since: profileStart),
                                          ticks: frame.completion.profileFixedSteps, dropped: frame.completion.profileDroppedTime)
                profiler.finishWorldFrame(frame.completion.profileToken, duration: 0,
                                          ticks: frame.completion.profileFixedSteps, dropped: frame.completion.profileDroppedTime)
            }
            isRunningSystems = false
            isFixedSingleStepping = false
            fixedAccumulator = 0
            fixedStepState.interpolationAlpha = 0
            fixedTransformHistory.removeAll(keepingCapacity: true)
            fixedTickStart.removeAll(keepingCapacity: true)
        }
        runFixedSteps(frame, wallDelta: configuration.stepDuration)
        return fixedStepState.tick == previousTick + 1
    }

    /// Starts simulation for a backend frame. Ordinary frames honor pause and time
    /// scale. A debug step requires a paused, enabled root and a positive finite
    /// delta, and advances at 1× without changing `isPaused`. Invalid times and
    /// reentrant calls are ignored; a debug step must finish before another begins.
    @_spi(Backend)
    public func beginFrame(deltaTime: TimeInterval, debugStep: Bool = false,
                           fixedDeltaTime: TimeInterval? = nil) -> WorldFrame? {
        guard deltaTime.isFinite, deltaTime >= 0, !isRunningSystems, !isDebugStepping,
              activeFrameCompletion?.finished != false else { return nil }
        if debugStep {
            guard isPaused, deltaTime > 0, root.isEnabledInHierarchy else { return nil }
        } else {
            guard !isPaused, timeScale > 0 else { return nil }
        }
        if fixedStep != nil, !debugStep, let fixedDeltaTime {
            guard fixedDeltaTime.isFinite, fixedDeltaTime >= 0 else { return nil }
        }
        let scaled = debugStep ? deltaTime : deltaTime * timeScale
        guard scaled.isFinite else { return nil }
        if debugStep { resetFixedStepClock() }
        fixedFrameEpoch &+= 1
        fixedStepState.ticksThisFrame = 0
        fixedStepState.droppedTime = 0
        let frame = WorldFrame(world: self, entries: scheduledSystems, deltaTime: scaled,
                               unscaledDeltaTime: deltaTime, isDebugStep: debugStep, isFixedOnlyStep: false,
                               fixedConfiguration: fixedStep, fixedEpoch: fixedStepEpoch,
                               frameEpoch: fixedFrameEpoch, frameTimeScale: debugStep ? 1 : timeScale,
                               isProfilingEnabled: isProfilingEnabled, profilingRevision: profilingRevision,
                               completion: FrameCompletion())
        lastSystemTimings = []
        activeFrameCompletion = frame.completion
        frame.completion.profileToken = profiler.beginWorldFrame(interval: fixedDeltaTime ?? deltaTime, debugStep: debugStep)
        let profileStart = frame.completion.profileToken.map { _ in profiler.clock() }
        isDebugStepping = debugStep
        isRunningSystems = true
        defer {
            if let profileStart {
                profiler.recordWorldBegin(frame.completion.profileToken, duration: profiler.elapsed(since: profileStart),
                                          ticks: frame.completion.profileFixedSteps, dropped: frame.completion.profileDroppedTime)
            }
            isRunningSystems = false
        }
        publish(WorldEvents.Update(world: self, deltaTime: scaled))
        runFixedSteps(frame, wallDelta: fixedDeltaTime ?? deltaTime)
        run(frame, phase: .simulation)
        return frame
    }

    /// Runs presentation after backend physics. A frame can be finished once and
    /// only by the world that created it. Pausing mid-frame skips ordinary
    /// presentation; debug steps ignore pause and time scale, and always clear
    /// `isDebugStepping` on completion, including when the root was disabled.
    @_spi(Backend)
    public func finishFrame(_ frame: WorldFrame) {
        guard frame.world === self, !frame.completion.finished, !isRunningSystems else { return }
        frame.completion.finished = true
        let profileStart = frame.completion.profileToken.map { _ in profiler.clock() }
        defer {
            if let profileStart {
                sampleProfileWorkload(frame.completion.profileToken)
                profiler.finishWorldFrame(frame.completion.profileToken, duration: profiler.elapsed(since: profileStart),
                                          ticks: frame.completion.profileFixedSteps, dropped: frame.completion.profileDroppedTime)
            }
        }
        defer { if frame.isDebugStep { isDebugStepping = false } }
        guard canRun(frame) else { return }
        isRunningSystems = true
        defer { isRunningSystems = false }
        run(frame, phase: .presentation)
    }

    /// Abandons a backend frame without running more game code, for teardown.
    @_spi(Backend)
    public func cancelFrame(_ frame: WorldFrame) {
        guard frame.world === self, !frame.completion.finished, !isRunningSystems else { return }
        frame.completion.finished = true
        profiler.cancelWorldFrame(frame.completion.profileToken)
        if frame.isDebugStep { isDebugStepping = false }
    }

    private func run(_ frame: WorldFrame, phase: SystemPhase,
                     fixedDelta: TimeInterval? = nil, fixedUnscaledDelta: TimeInterval? = nil,
                     fixedTick: UInt64? = nil) {
        defer {
            if frame.isProfilingEnabled, isProfilingEnabled, frame.profilingRevision == profilingRevision {
                lastSystemTimings = frame.completion.timings
            }
        }
        let context = UpdateContext(world: self, deltaTime: fixedDelta ?? frame.deltaTime,
                                    unscaledDeltaTime: fixedUnscaledDelta ?? frame.unscaledDeltaTime, phase: phase,
                                    fixedTick: fixedTick, interpolationAlpha: fixedStepState.interpolationAlpha)
        for entry in frame.entries where entry.type.phase == phase {
            guard canRun(frame) else { break }
            if phase == .fixedSimulation && !canRunFixed(frame) { break }
            guard systemEntry(entry.type) === entry, entry.isEnabled else { continue }
            let profileSystem = profiler.isRecording ? profiler.beginSystem(name: String(reflecting: entry.type), phase: phase) : nil
            defer { profiler.endSystem(profileSystem) }
            if frame.isProfilingEnabled, isProfilingEnabled, frame.profilingRevision == profilingRevision {
                let start = DispatchTime.now().uptimeNanoseconds
                entry.instance.update(context: context)
                let end = DispatchTime.now().uptimeNanoseconds
                frame.completion.timings.append(SystemTiming(name: String(reflecting: entry.type), phase: phase,
                                                            duration: Double(end - start) / 1_000_000_000))
            } else {
                entry.instance.update(context: context)
            }
        }
    }

    private func canRunFixed(_ frame: WorldFrame) -> Bool {
        canRun(frame) && root.isActive && frame.fixedEpoch == fixedStepEpoch
            && frame.frameEpoch == fixedFrameEpoch
    }

    private func runFixedSteps(_ frame: WorldFrame, wallDelta: TimeInterval) {
        guard let configuration = frame.fixedConfiguration, canRunFixed(frame) else { return }
        let step = configuration.stepDuration
        let tolerance = step * 1e-9
        let count: Int
        if frame.isDebugStep || frame.isFixedOnlyStep {
            count = 1
            fixedAccumulator = 0
            fixedStepState.interpolationAlpha = 1
        } else {
            let raw = wallDelta
            let clamped = min(raw, configuration.maximumFrameDeltaTime)
            let scaled = fixedFiniteProduct(clamped, frame.frameTimeScale)
            let total = fixedFiniteSum(fixedAccumulator, scaled)
            var remainder = total.truncatingRemainder(dividingBy: step)
            let whole = floor(total / step + 1e-9)
            // Round a fractional step at the upper boundary up, but never turn a
            // huge quotient into an Int before applying the bounded tick budget.
            let roundsUp = step - remainder <= tolerance
            let available = whole
            if roundsUp || remainder <= tolerance { remainder = 0 }
            count = Int(min(Double(configuration.maximumCatchUpSteps), available))
            fixedAccumulator = remainder
            fixedStepState.interpolationAlpha = min(1, max(0, remainder / step))
            let budgetDrop = available > Double(count) ? max(0, total - remainder - Double(count) * step) : 0
            fixedStepState.droppedTime = fixedFiniteSum(
                fixedFiniteProduct(raw - clamped, frame.frameTimeScale), budgetDrop)
        }
        frame.completion.profileDroppedTime = fixedStepState.droppedTime
        let unscaled = min(Double.greatestFiniteMagnitude, step / frame.frameTimeScale)
        for _ in 0..<count {
            guard canRunFixed(frame), fixedStepState.tick < UInt64.max else { break }
            isFixedUpdating = true
            captureFixedTickStart()
            fixedStepState.tick += 1
            fixedStepState.ticksThisFrame += 1
            if frame.completion.profileToken != nil { frame.completion.profileFixedSteps += 1 }
            fixedStepState.simulationTime = fixedFiniteSum(fixedStepState.simulationTime, step)
            let tick = fixedStepState.tick
            publish(WorldEvents.FixedUpdate(world: self, deltaTime: step,
                                            unscaledDeltaTime: unscaled, tick: tick))
            if canRunFixed(frame) {
                run(frame, phase: .fixedSimulation, fixedDelta: step,
                    fixedUnscaledDelta: unscaled, fixedTick: tick)
            }
            if canRunFixed(frame) { captureFixedTickEnd() }
            isFixedUpdating = false
            // Replay commits only after every fixed system and transform capture.
            // Take the queue first so callbacks cannot join this completed tick.
            let completed = canRunFixed(frame)
            let completions = fixedTickCompletions
            fixedTickCompletions.removeAll(keepingCapacity: true)
            for completion in completions { completion(completed) }
            // Callbacks may have reset the clock. Never publish an old tick's
            // transform pair or accumulator over that newer reset.
            guard canRunFixed(frame) else { break }
        }
        if frame.isDebugStep && canRunFixed(frame) {
            fixedTransformHistory.removeAll(keepingCapacity: true)
            fixedTickStart.removeAll(keepingCapacity: true)
        }
    }

    private func canRun(_ frame: WorldFrame) -> Bool {
        if frame.isFixedOnlyStep { return isPaused && root.isActive }
        return frame.isDebugStep ? root.isEnabledInHierarchy : (!isPaused && timeScale > 0)
    }
}
