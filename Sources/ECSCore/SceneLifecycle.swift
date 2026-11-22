import Foundation

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
    fileprivate var completion: FrameCompletion
}

@MainActor
final class FrameCompletion { var finished = false }

extension World {
    /// Starts simulation for a backend frame. Paused scenes and a zero time scale
    /// do not publish update events or run systems. Invalid delta times are ignored.
    @_spi(Backend)
    public func beginFrame(deltaTime: TimeInterval) -> WorldFrame? {
        guard !isPaused, timeScale > 0, deltaTime.isFinite, deltaTime >= 0, !isRunningSystems else { return nil }
        let scaled = deltaTime * timeScale
        guard scaled.isFinite else { return nil }
        let frame = WorldFrame(world: self, entries: scheduledSystems, deltaTime: scaled,
                               unscaledDeltaTime: deltaTime, completion: FrameCompletion())
        isRunningSystems = true
        defer { isRunningSystems = false }
        publish(WorldEvents.Update(world: self, deltaTime: scaled))
        run(frame, phase: .simulation)
        return frame
    }

    /// Runs presentation after backend physics. A frame can be finished once and
    /// only by the world that created it. Pausing mid-frame skips presentation.
    @_spi(Backend)
    public func finishFrame(_ frame: WorldFrame) {
        guard frame.world === self, !frame.completion.finished, !isRunningSystems else { return }
        frame.completion.finished = true
        guard !isPaused, timeScale > 0 else { return }
        isRunningSystems = true
        defer { isRunningSystems = false }
        run(frame, phase: .presentation)
    }

    private func run(_ frame: WorldFrame, phase: SystemPhase) {
        let context = UpdateContext(world: self, deltaTime: frame.deltaTime,
                                    unscaledDeltaTime: frame.unscaledDeltaTime, phase: phase)
        for entry in frame.entries where entry.type.phase == phase {
            guard !isPaused, timeScale > 0 else { break }
            guard systemEntry(entry.type) === entry, entry.isEnabled else { continue }
            entry.instance.update(context: context)
        }
    }
}
