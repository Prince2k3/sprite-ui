import Foundation

/// Why an application or connection interrupted its fixed party.
public enum GameCenterInterruptionReason: String, Sendable {
    case backgrounded, connectionLost, timedOut, applicationRequested
}

/// The last interruption, retained until another match or explicit return to menu.
public struct GameCenterPartyInterruption: Hashable, Sendable {
    /// The broad interruption category; it is not a remote rollback acknowledgment.
    public let reason: GameCenterInterruptionReason
    /// Optional local diagnostic text.
    public let message: String?
}

/// Bounded recovery timing and background policy. No setting enables automatic retries or host migration.
public struct GameCenterRecoveryConfiguration: Hashable, Sendable {
    /// Maximum wait for a fresh complete match, clamped to 1...300 seconds.
    public let matchmakingTimeout: TimeInterval
    /// Maximum wait for initial recovery baseline acknowledgments, clamped to 1...120 seconds.
    public let resynchronizationTimeout: TimeInterval
    /// Whether the stable gameCenter view host interrupts an active party on entering background.
    public let interruptsOnBackground: Bool
    /// Creates a policy with explicit fresh-match retry and a background interruption by default.
    public init(matchmakingTimeout: TimeInterval = 60, resynchronizationTimeout: TimeInterval = 15,
                interruptsOnBackground: Bool = true) {
        self.matchmakingTimeout = matchmakingTimeout.isFinite ? min(300, max(1, matchmakingTimeout)) : 60
        self.resynchronizationTimeout = resynchronizationTimeout.isFinite ? min(120, max(1, resynchronizationTimeout)) : 15
        self.interruptsOnBackground = interruptsOnBackground
    }
}
