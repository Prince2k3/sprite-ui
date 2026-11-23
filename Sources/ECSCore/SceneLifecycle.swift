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
    fileprivate let isProfilingEnabled: Bool
    fileprivate let profilingRevision: UInt64
    fileprivate var completion: FrameCompletion
}

@MainActor
final class FrameCompletion {
    var finished = false
    var timings: [SystemTiming] = []
}

extension World {
    /// Starts simulation for a backend frame. Ordinary frames honor pause and time
    /// scale. A debug step requires a paused, enabled root and a positive finite
    /// delta, and advances at 1× without changing `isPaused`. Invalid times and
    /// reentrant calls are ignored; a debug step must finish before another begins.
    @_spi(Backend)
    public func beginFrame(deltaTime: TimeInterval, debugStep: Bool = false) -> WorldFrame? {
        guard deltaTime.isFinite, deltaTime >= 0, !isRunningSystems, !isDebugStepping else { return nil }
        if debugStep {
            guard isPaused, deltaTime > 0, root.isEnabledInHierarchy else { return nil }
        } else {
            guard !isPaused, timeScale > 0 else { return nil }
        }
        let scaled = debugStep ? deltaTime : deltaTime * timeScale
        guard scaled.isFinite else { return nil }
        let frame = WorldFrame(world: self, entries: scheduledSystems, deltaTime: scaled,
                               unscaledDeltaTime: deltaTime, isDebugStep: debugStep,
                               isProfilingEnabled: isProfilingEnabled, profilingRevision: profilingRevision,
                               completion: FrameCompletion())
        lastSystemTimings = []
        isDebugStepping = debugStep
        isRunningSystems = true
        defer { isRunningSystems = false }
        publish(WorldEvents.Update(world: self, deltaTime: scaled))
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
        if frame.isDebugStep { isDebugStepping = false }
    }

    private func run(_ frame: WorldFrame, phase: SystemPhase) {
        defer {
            if frame.isProfilingEnabled, isProfilingEnabled, frame.profilingRevision == profilingRevision {
                lastSystemTimings = frame.completion.timings
            }
        }
        let context = UpdateContext(world: self, deltaTime: frame.deltaTime,
                                    unscaledDeltaTime: frame.unscaledDeltaTime, phase: phase)
        for entry in frame.entries where entry.type.phase == phase {
            guard canRun(frame) else { break }
            guard systemEntry(entry.type) === entry, entry.isEnabled else { continue }
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

    private func canRun(_ frame: WorldFrame) -> Bool {
        frame.isDebugStep ? root.isEnabledInHierarchy : (!isPaused && timeScale > 0)
    }
}
