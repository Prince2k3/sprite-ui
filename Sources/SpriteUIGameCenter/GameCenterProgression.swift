import Foundation
import Gameplay

/// An explicit mapping from one quest occurrence to one permanent Game Center achievement.
public struct GameCenterQuestMapping: Hashable, Codable, Sendable {
    /// The local quest occurrence ID.
    public let questID: String
    /// An achievement identifier configured by the consuming game.
    public let achievementID: String
    /// Creates a mapping. Report validates all mappings before sending any progress.
    public init(questID: String, achievementID: String) {
        self.questID = questID; self.achievementID = achievementID
    }
}

/// An explicit mapping between a local season and a configured leaderboard.
/// For recurring boards, the application must align the configured occurrence schedule with the season.
public struct GameCenterLeagueMapping: Hashable, Codable, Sendable {
    /// The local season occurrence ID.
    public let seasonID: String
    /// A configured leaderboard identifier. Configure higher scores as better and retain best scores.
    public let leaderboardID: String
    /// Application-defined score metadata; it does not select a recurring occurrence.
    public let context: UInt64
    /// Creates a mapping without contacting Game Center.
    public init(seasonID: String, leaderboardID: String, context: UInt64 = 0) {
        self.seasonID = seasonID; self.leaderboardID = leaderboardID; self.context = context
    }
}

/// Optional, explicit reporting from local rules to basic Game Center services.
/// This bridge never authenticates, grants rewards, imports ranks as league authority, or retries writes.
@MainActor
public final class GameCenterProgression {
    private let context: GameCenterServiceContext
    private let achievements: GameCenterAchievements
    private let leaderboards: GameCenterLeaderboards

    init(context: GameCenterServiceContext, achievements: GameCenterAchievements, leaderboards: GameCenterLeaderboards) {
        self.context = context; self.achievements = achievements; self.leaderboards = leaderboards
    }

    /// Reports the mean objective percentage for each mapped quest, including completed/claimed quests.
    /// The journal owner must match the current Game Center or explicit preview identity.
    /// A failed batch may have committed earlier reports. Repeating it is safe for monotonic achievements.
    public func report(_ journal: QuestJournal, using mappings: [GameCenterQuestMapping], at date: Date) async throws {
        let operation = try context.begin()
        guard journal.playerID == operation.player.id.rawValue else { throw GameCenterServiceError.accountChanged }
        var questIDs = Set<String>(), achievementIDs = Set<String>()
        let values = try mappings.map { mapping in
            try validateGameCenterIdentifier(mapping.achievementID)
            guard questIDs.insert(mapping.questID).inserted, achievementIDs.insert(mapping.achievementID).inserted else {
                throw GameCenterServiceError.invalidValue
            }
            let progress = try journal.progress(for: mapping.questID, at: date)
            return (mapping.achievementID, progress.fractionCompleted * 100)
        }
        for (identifier, percent) in values where percent > 0 {
            try context.validate(operation)
            try await achievements.report(progress: percent, for: identifier)
            try context.validate(operation)
        }
    }

    /// Submits only the current player's accumulated/best points while the local season is active.
    /// This does not publish other members' scores or synchronize custom league rosters and promotions.
    public func submit(_ season: LeagueSeason, using mapping: GameCenterLeagueMapping, at date: Date) async throws {
        let operation = try context.begin()
        try validateGameCenterIdentifier(mapping.leaderboardID)
        guard season.id == mapping.seasonID, date.timeIntervalSinceReferenceDate.isFinite,
              season.window.contains(date), season.closedAt == nil else { throw GameCenterServiceError.invalidValue }
        guard let score = season.score(for: operation.player.id.rawValue) else { throw GameCenterServiceError.accountChanged }
        try context.validate(operation)
        try await leaderboards.submit(score: score, to: mapping.leaderboardID, context: mapping.context)
        try context.validate(operation)
    }
}
