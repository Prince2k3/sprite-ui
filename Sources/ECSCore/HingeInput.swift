import Foundation

/// An immutable hinge sample with an angle in radians and an OS-supplied status.
/// Native samples require a device with a physical hinge and an OS-supported
/// hinge sensor. Constructing this value does not provide hardware support.
public struct GameHingeState: Hashable, Codable, Sendable {
    /// The operating system's hinge classification, independent of the angle.
    public enum Status: String, Codable, Sendable {
        /// The operating system cannot classify the hinge state.
        case unknown
        /// The operating system reports a closed hinge.
        case closed
        /// The operating system reports a partially open hinge.
        case partiallyOpen
        /// The operating system reports a fully open hinge.
        case fullyOpen
    }

    /// The finite hinge angle in radians, clamped to zero through pi.
    public let angle: Double
    /// The supplied OS status; it is never inferred from the angle.
    public let status: Status
    /// The hinge angle normalized to zero through one.
    public var openness: Double { angle / .pi }

    /// Creates a sample by clamping a finite angle; nonfinite angles return nil.
    public init?(angle: Double, status: Status) {
        guard angle.isFinite else { return nil }
        self.angle = min(max(angle, 0), .pi)
        self.status = status
    }

    private enum CodingKeys: String, CodingKey { case angle, status }

    /// Decodes a sample, rejecting nonfinite angles and clamping finite angles.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let angle = try values.decode(Double.self, forKey: .angle)
        let status = try values.decode(Status.self, forKey: .status)
        guard let state = Self(angle: angle, status: status) else {
            throw DecodingError.dataCorruptedError(
                forKey: .angle, in: values, debugDescription: "Hinge angle must be finite."
            )
        }
        self = state
    }
}

/// Maps a hinge angle into a signed scalar action value.
/// Native action input requires supported physical hinge hardware. This value
/// only configures the mapping; use separate virtual controls on other devices.
public struct HingeInputConfiguration: Hashable, Codable, Sendable {
    /// The angle in radians that maps to zero, clamped to zero through pi.
    public let neutralAngle: Double
    /// The angle in radians that maps to positive one, clamped to zero through pi.
    public let activationAngle: Double
    /// The neutral scalar region, clamped to zero through 0.99.
    public let deadZone: Float
    /// The nonnegative smoothing time in seconds for a host adapter to apply.
    public let smoothing: TimeInterval

    /// Creates a mapping. Nonfinite values use their defaults; negative smoothing
    /// also uses 0.08 seconds. Finite angles and dead zones are clamped.
    public init(neutralAngle: Double = .pi, activationAngle: Double = .pi / 2,
                deadZone: Float = 0.05, smoothing: TimeInterval = 0.08) {
        self.neutralAngle = neutralAngle.isFinite ? min(max(neutralAngle, 0), .pi) : .pi
        self.activationAngle = activationAngle.isFinite ? min(max(activationAngle, 0), .pi) : .pi / 2
        self.deadZone = deadZone.isFinite ? min(max(deadZone, 0), 0.99) : 0.05
        self.smoothing = smoothing.isFinite && smoothing >= 0 ? smoothing : 0.08
    }

    /// Resolves a sample to -1 through 1, rescaling outside the dead zone.
    /// Missing or unknown samples and equal mapping endpoints resolve to zero.
    /// Smoothing is left to the host, keeping this mapping stateless.
    public func value(for state: GameHingeState?) -> Float {
        guard let state, state.status != .unknown, activationAngle != neutralAngle else { return 0 }
        let value = Float(min(max((state.angle - neutralAngle) / (activationAngle - neutralAngle), -1), 1))
        let magnitude = abs(value)
        guard magnitude > deadZone else { return 0 }
        let rescaled = (magnitude - deadZone) / (1 - deadZone)
        return value < 0 ? -rescaled : rescaled
    }

    private enum CodingKeys: String, CodingKey { case neutralAngle, activationAngle, deadZone, smoothing }

    /// Decodes a mapping using the same sanitization as direct construction.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(neutralAngle: try values.decode(Double.self, forKey: .neutralAngle),
                  activationAngle: try values.decode(Double.self, forKey: .activationAngle),
                  deadZone: try values.decode(Float.self, forKey: .deadZone),
                  smoothing: try values.decode(TimeInterval.self, forKey: .smoothing))
    }
}

/// Events describing changes in the host's hinge availability or sample.
public enum GameHingeEvents {
    /// A hinge sample changed, appeared, or became unavailable.
    public struct DidChange: Event {
        /// The world presented by the host reporting the hinge change.
        public let scene: World
        /// The preceding sample, or nil when no hinge sample was available.
        public let previous: GameHingeState?
        /// The current sample, or nil when the hinge is unavailable.
        public let state: GameHingeState?

        /// Creates a hinge sample or availability change notification.
        public init(scene: World, previous: GameHingeState?, state: GameHingeState?) {
            self.scene = scene; self.previous = previous; self.state = state
        }
    }
}
