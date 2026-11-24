import Foundation

/// Opt-in simulation cadence, independent of the display refresh rate.
public struct FixedStepConfiguration: Hashable, Codable, Sendable {
    public let stepsPerSecond: Double
    public let maximumCatchUpSteps: Int
    public let maximumFrameDeltaTime: TimeInterval
    public var stepDuration: TimeInterval { 1 / stepsPerSecond }

    public init(stepsPerSecond: Double = 60, maximumCatchUpSteps: Int = 8,
                maximumFrameDeltaTime: TimeInterval = 0.25) {
        self.stepsPerSecond = stepsPerSecond.isFinite ? min(1000, max(1, stepsPerSecond)) : 60
        self.maximumCatchUpSteps = min(120, max(1, maximumCatchUpSteps))
        self.maximumFrameDeltaTime = maximumFrameDeltaTime.isFinite
            ? min(10, max(0.001, maximumFrameDeltaTime)) : 0.25
    }

    private enum CodingKeys: String, CodingKey {
        case stepsPerSecond, maximumCatchUpSteps, maximumFrameDeltaTime
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(stepsPerSecond: try values.decode(Double.self, forKey: .stepsPerSecond),
                  maximumCatchUpSteps: try values.decode(Int.self, forKey: .maximumCatchUpSteps),
                  maximumFrameDeltaTime: try values.decode(Double.self, forKey: .maximumFrameDeltaTime))
    }
}

/// Lifetime tick counters and the results of the latest display frame.
public struct FixedStepState: Equatable, Sendable {
    public internal(set) var tick: UInt64 = 0
    public internal(set) var ticksThisFrame: Int = 0
    public internal(set) var interpolationAlpha: Double = 0
    /// Scaled time discarded by the wall-clock clamp and catch-up budget this frame.
    /// Extreme products and sums saturate at the largest finite time interval.
    public internal(set) var droppedTime: TimeInterval = 0
    public internal(set) var simulationTime: TimeInterval = 0
}

/// Marks an entity whose last two fixed poses may be interpolated by a backend.
public struct TransformInterpolationComponent: Component, Hashable, Codable, Sendable {
    public var isEnabled: Bool
    public private(set) var revision: UInt64 = 0
    public init(isEnabled: Bool = true) { self.isEnabled = isEnabled }
    /// Call after a teleport inside a fixed tick to discard the pre-teleport pose.
    public mutating func reset() { revision &+= 1 }
}

@_spi(Backend)
public struct FixedTransformSample: Equatable, Sendable {
    public let previous: Transform
    public let current: Transform
    public init(previous: Transform, current: Transform) {
        self.previous = previous
        self.current = current
    }
}

struct FixedTransformHistory {
    let parentID: Entity.ID?
    let activationRevision: UInt64
    let markerRevision: UInt64
    let sample: FixedTransformSample
}

extension World {
    /// Discards clock debt and interpolation history without rewinding lifetime counters.
    @_spi(Backend)
    public func resetFixedStepClock() {
        fixedStepEpoch &+= 1
        fixedAccumulator = 0
        fixedStepState.ticksThisFrame = 0
        fixedStepState.interpolationAlpha = 0
        fixedStepState.droppedTime = 0
        fixedTransformHistory.removeAll(keepingCapacity: true)
        fixedTickStart.removeAll(keepingCapacity: true)
    }

    /// Discards one entity's interpolation history without changing the world clock.
    @_spi(Backend)
    public func resetFixedTransformHistory(for entity: Entity) {
        guard entity.world === self else { return }
        invalidateFixedTransform(for: entity)
    }

    /// Returns local model poses only while their hierarchy and latest model still match.
    @_spi(Backend)
    public func fixedTransformSample(for entity: Entity) -> FixedTransformSample? {
        guard fixedStep != nil, root.isActive, entity.world === self, entity.isActive,
              let marker = entity.components[TransformInterpolationComponent.self], marker.isEnabled,
              let history = fixedTransformHistory[entity.id],
              history.parentID == entity.parent?.id,
              history.activationRevision == entity.activationRevision,
              history.markerRevision == marker.revision,
              history.sample.current == entity.transform else {
            fixedTransformHistory[entity.id] = nil
            return nil
        }
        return history.sample
    }

    func invalidateFixedTransform(for entity: Entity) {
        fixedTransformHistory[entity.id] = nil
        fixedTickStart[entity.id] = nil
    }

    func captureFixedTickStart() {
        fixedTickStart.removeAll(keepingCapacity: true)
        for entity in allEntities where entity.isActive {
            guard let marker = entity.components[TransformInterpolationComponent.self], marker.isEnabled else { continue }
            fixedTickStart[entity.id] = FixedTransformHistory(
                parentID: entity.parent?.id, activationRevision: entity.activationRevision,
                markerRevision: marker.revision,
                sample: FixedTransformSample(previous: entity.transform, current: entity.transform))
        }
        // Drop detached, disabled, or unmarked entities even on an otherwise quiet tick.
        fixedTransformHistory = fixedTransformHistory.filter { fixedTickStart[$0.key] != nil }
    }

    func captureFixedTickEnd() {
        for (id, start) in fixedTickStart {
            guard let entity = entity(withID: id), entity.isActive,
                  let marker = entity.components[TransformInterpolationComponent.self], marker.isEnabled,
                  start.parentID == entity.parent?.id,
                  start.activationRevision == entity.activationRevision,
                  start.markerRevision == marker.revision else {
                fixedTransformHistory[id] = nil
                continue
            }
            fixedTransformHistory[id] = FixedTransformHistory(
                parentID: start.parentID, activationRevision: start.activationRevision,
                markerRevision: start.markerRevision,
                sample: FixedTransformSample(previous: start.sample.current, current: entity.transform))
        }
        fixedTickStart.removeAll(keepingCapacity: true)
    }
}

/// Saturating arithmetic keeps diagnostics finite for extreme but valid clock inputs.
func fixedFiniteProduct(_ a: Double, _ b: Double) -> Double {
    let result = a * b
    return result.isFinite ? result : Double.greatestFiniteMagnitude
}
func fixedFiniteSum(_ a: Double, _ b: Double) -> Double {
    let result = a + b
    return result.isFinite ? result : Double.greatestFiniteMagnitude
}
