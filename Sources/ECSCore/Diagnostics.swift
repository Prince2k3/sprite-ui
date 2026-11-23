import Foundation

/// The monotonic wall-clock duration of one system update, in execution order.
public struct SystemTiming: Equatable, Sendable {
    /// The system type's fully qualified name, produced by `String(reflecting:)`.
    public let name: String
    public let phase: SystemPhase
    public let duration: TimeInterval

    public init(name: String, phase: SystemPhase, duration: TimeInterval) {
        self.name = name
        self.phase = phase
        self.duration = duration
    }
}
