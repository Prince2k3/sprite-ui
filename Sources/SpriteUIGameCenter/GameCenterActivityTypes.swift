import ECSCore
import Foundation

/// Configured activity metadata, copied without exposing GameKit objects.
public struct GameCenterActivityDefinition: Hashable, Sendable, Identifiable {
    /// The configured activity identifier.
    public let id: String
    /// The localized title.
    public let title: String
    /// Optional localized details.
    public let details: String?
    /// Default game-owned routing properties. Validate their meaning before loading content.
    public let defaultProperties: [String: String]
    /// Whether the definition permits a shared party code.
    public let supportsPartyCode: Bool
    /// Creates inert metadata, also used for explicit preview fixtures.
    public init(id: String, title: String, details: String? = nil, defaultProperties: [String: String] = [:], supportsPartyCode: Bool = false) {
        self.id = id; self.title = title; self.details = details
        self.defaultProperties = defaultProperties; self.supportsPartyCode = supportsPartyCode
    }
}

/// An activity's local lifecycle, independent of a world's simulation state.
public enum GameCenterActivityState: String, Sendable { case initialized, active, paused, ended }

/// A current attempt score; replacing it with a lower score is permitted.
public struct GameCenterActivityScore: Hashable, Sendable {
    /// The latest score, not the player's personal best.
    public let value: Int
    /// Application-defined metadata, not an attempt or recurring-occurrence selector.
    public let context: UInt64
    /// Creates a score value.
    public init(_ value: Int, context: UInt64 = 0) { self.value = value; self.context = context }
}

/// An inert activity instance snapshot. Holding one does not resume gameplay.
public struct GameCenterActivity: Hashable, Sendable, Identifiable {
    /// The activity instance identifier, distinct from its definition ID.
    public let id: String
    /// The configured definition ID.
    public let definitionID: String
    /// Current routing properties. The application must validate content/progression access.
    public let properties: [String: String]
    /// A validated native party code, or a numeric preview fixture.
    public let partyCode: String?
    /// A shareable native party URL, when available. It is never opened automatically.
    public let partyURL: URL?
    /// The current activity phase.
    public let state: GameCenterActivityState
    /// The creation time supplied by the backend.
    public let createdAt: Date
    /// Scores staged by this wrapper, submitted only on explicit finish.
    public let scores: [String: GameCenterActivityScore]
    /// Achievement percentages staged by this wrapper.
    public let achievementProgress: [String: Double]
}

/// An accepted system intent queued for explicit application routing.
public struct GameCenterActivityRequest: Hashable, Sendable, Identifiable {
    /// An ephemeral queue choice ID.
    public let id: UUID
    /// The activity that the player wants to play.
    public let activity: GameCenterActivity
}

/// A local receipt that an activity was ended and its staged results handed to GameKit.
/// This is not a remote durability acknowledgment or a persisted deduplication record.
public struct GameCenterActivityCompletion: Hashable, Sendable, Identifiable {
    /// The completed activity's instance ID.
    public var id: String { activity.id }
    /// The ended activity and its last staged results.
    public let activity: GameCenterActivity
}

func validateActivityProperties(_ properties: [String: String]) throws {
    guard properties.count <= 64 else { throw GameCenterServiceError.capacityExceeded }
    var bytes = 0
    for (key, value) in properties {
        try validateGameCenterIdentifier(key)
        guard value.utf8.count <= 1_024 else { throw GameCenterServiceError.capacityExceeded }
        bytes += key.utf8.count + value.utf8.count
    }
    guard bytes <= 32_768 else { throw GameCenterServiceError.capacityExceeded }
}

func validateActivityDefinition(_ value: GameCenterActivityDefinition) throws {
    try validateGameCenterIdentifier(value.id)
    guard !value.title.isEmpty else { throw GameCenterServiceError.invalidData }
    try validateActivityProperties(value.defaultProperties)
}

@MainActor protocol GameCenterActivityHandle: AnyObject, Sendable {
    var snapshot: GameCenterActivity { get }
    func activate()
    func pause()
    func resume()
    func setScore(_ score: GameCenterActivityScore, for identifier: String) async throws
    func setProgress(_ progress: Double, for identifier: String)
    func clearResults()
    func end()
    func findPartyMatch(using multiplayer: GameCenterMultiplayer) async throws -> any NetworkTransport
}

extension GameCenterActivityHandle {
    func findPartyMatch(using multiplayer: GameCenterMultiplayer) async throws -> any NetworkTransport { throw GameCenterServiceError.unavailable }
}

@MainActor struct GameCenterActivitiesDriver {
    var isSupported = true
    var load: @MainActor () async throws -> [GameCenterActivityDefinition]
    var make: @MainActor (String, String?, [String: String]) async throws -> any GameCenterActivityHandle
    var listen: @MainActor (@escaping @MainActor (String, any GameCenterActivityHandle) -> Bool) throws -> (() -> Void)
    var hasPending: @MainActor () async -> Bool
    var validatesPartyCode: @MainActor (String) -> Bool
}
