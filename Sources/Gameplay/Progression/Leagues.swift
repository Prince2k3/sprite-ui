import Foundation

/// A division in a league. Supply tiers in ascending order, from entry to elite.
public struct LeagueTier: Hashable, Codable, Sendable, Identifiable {
    /// The stable division identifier.
    public let id: String
    /// The display title.
    public let title: String
    /// Creates a validated division.
    public init(id: String, title: String) throws {
        try validateProgressionID(id)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProgressionError.invalidDefinition }
        self.id = id; self.title = title
    }
    private enum CodingKeys: String, CodingKey { case id, title }
    /// Decodes and validates a division.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(String.self, forKey: .id), title: c.decode(String.self, forKey: .title))
    }
}

/// One member of a season's fixed roster.
public struct LeagueParticipant: Hashable, Codable, Sendable, Identifiable {
    /// A stable player identifier, optionally the Game Center game-player ID.
    public let id: String
    /// The display name.
    public let displayName: String
    /// The member's division for this season.
    public let tierID: String
    /// Creates a validated roster member.
    public init(id: String, displayName: String, tierID: String) throws {
        try validateProgressionID(id); try validateProgressionID(tierID)
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProgressionError.invalidDefinition }
        self.id = id; self.displayName = displayName; self.tierID = tierID
    }
    private enum CodingKeys: String, CodingKey { case id, displayName, tierID }
    /// Decodes and validates a roster member.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(String.self, forKey: .id), displayName: c.decode(String.self, forKey: .displayName), tierID: c.decode(String.self, forKey: .tierID))
    }
}

/// Scoring and whole-tie-group promotion rules for a season.
public struct LeagueRules: Hashable, Codable, Sendable {
    /// Accumulate result points, or retain a member's highest result.
    public enum Scoring: String, Codable, Sendable { case total, best }
    /// How result scores contribute to standings. Higher is always better.
    public let scoring: Scoring
    /// Leading positions eligible to move up one tier. A cutoff tie stays in place.
    public let promotionPlaces: Int
    /// Trailing positions eligible to move down one tier. A cutoff tie stays in place.
    public let demotionPlaces: Int
    /// Creates a policy. In small cohorts, promotion positions take priority over demotion positions.
    public init(scoring: Scoring = .total, promotionPlaces: Int = 1, demotionPlaces: Int = 1) throws {
        guard promotionPlaces >= 0, demotionPlaces >= 0 else { throw ProgressionError.invalidDefinition }
        self.scoring = scoring; self.promotionPlaces = promotionPlaces; self.demotionPlaces = demotionPlaces
    }
    private enum CodingKeys: String, CodingKey { case scoring, promotionPlaces, demotionPlaces }
    /// Decodes and validates a policy.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(scoring: c.decode(Scoring.self, forKey: .scoring), promotionPlaces: c.decode(Int.self, forKey: .promotionPlaces),
                      demotionPlaces: c.decode(Int.self, forKey: .demotionPlaces))
    }
}

/// One authoritative result containing nonnegative points for one or more roster members.
public struct LeagueResult: Equatable, Codable, Sendable, Identifiable {
    /// A unique match/result occurrence ID. Replays are ignored for the lifetime of the season.
    public let id: String
    /// Player IDs mapped to nonnegative result scores.
    public let scores: [String: Int]
    /// The time the result became eligible, within the season window.
    public let date: Date
    /// Creates a result without consulting a clock.
    public init(id: String, scores: [String: Int], at date: Date) throws {
        try validateProgressionID(id)
        guard !scores.isEmpty, scores.values.allSatisfy({ $0 >= 0 }), date.timeIntervalSinceReferenceDate.isFinite else {
            throw ProgressionError.invalidValue
        }
        for id in scores.keys { try validateProgressionID(id) }
        self.id = id; self.scores = scores; self.date = date
    }
    private enum CodingKeys: String, CodingKey { case id, scores, date }
    /// Decodes and validates a result.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(String.self, forKey: .id), scores: c.decode([String: Int].self, forKey: .scores), at: c.decode(Date.self, forKey: .date))
    }
}

/// A member's competition rank within a tier. Equal scores have equal ranks.
public struct LeagueStanding: Equatable, Sendable, Identifiable {
    /// The player identifier.
    public var id: String { participant.id }
    /// The roster member.
    public let participant: LeagueParticipant
    /// The retained season points.
    public let score: Int
    /// One-based competition rank, such as 1, 1, 3.
    public let rank: Int
}

/// The immutable outcome of a finalized season for one member.
public struct LeaguePlacement: Equatable, Sendable, Identifiable {
    /// The player identifier.
    public let id: String
    /// The member's score and rank in the season just closed.
    public let standing: LeagueStanding
    /// The division for a future season. Boundary tiers cannot move beyond the tier list.
    public let nextTierID: String
}

/// A bounded, local league season with a fixed roster and explicit caller-controlled time.
/// For shared competitive leagues, run these rules on your authoritative server.
public struct LeagueSeason: Equatable, Sendable, Codable, Identifiable {
    /// A stable occurrence-specific season identifier.
    public let id: String
    /// The display title.
    public let title: String
    /// The half-open result eligibility window.
    public let window: ProgressionWindow
    /// Divisions in ascending order.
    public let tiers: [LeagueTier]
    /// The fixed season roster.
    public let participants: [LeagueParticipant]
    /// The scoring and movement policy.
    public let rules: LeagueRules
    /// The maximum unique results retained; new results fail at capacity.
    public let resultCapacity: Int
    /// All accepted results, including their duplicate-protection IDs.
    public private(set) var results: [LeagueResult] = []
    /// The finalization instant, or nil while unfinalized.
    public private(set) var closedAt: Date?
    /// Placements in tier order and then rank order, filled only by finalization.
    public private(set) var placements: [LeaguePlacement] = []
    private var scores: [String: Int] = [:]
    private var resultIDs: Set<String> = []

    /// Creates a validated league. Members cannot join or change divisions during this season.
    public init(id: String, title: String, window: ProgressionWindow, tiers: [LeagueTier],
                participants: [LeagueParticipant], rules: LeagueRules, resultCapacity: Int = 10_000) throws {
        try validateProgressionID(id)
        let tierIDs = Set(tiers.map(\.id))
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !tiers.isEmpty,
              tierIDs.count == tiers.count, Set(participants.map(\.id)).count == participants.count,
              participants.allSatisfy({ tierIDs.contains($0.tierID) }), resultCapacity > 0, resultCapacity <= 1_000_000 else {
            throw ProgressionError.invalidDefinition
        }
        self.id = id; self.title = title; self.window = window; self.tiers = tiers
        self.participants = participants; self.rules = rules; self.resultCapacity = resultCapacity
    }

    /// Returns a roster member's points, or nil for an unknown member.
    public func score(for playerID: String) -> Int? {
        guard participants.contains(where: { $0.id == playerID }) else { return nil }
        return scores[playerID] ?? 0
    }

    /// Returns a tier's standings. Equal scores sort by player ID for stable presentation without breaking rank ties.
    public func standings(in tierID: String) throws -> [LeagueStanding] {
        guard tiers.contains(where: { $0.id == tierID }) else { throw ProgressionError.invalidDefinition }
        let sorted = participants.filter { $0.tierID == tierID }.sorted {
            let a = scores[$0.id] ?? 0, b = scores[$1.id] ?? 0
            return a == b ? $0.id < $1.id : a > b
        }
        var rank = 0, previous: Int?
        return sorted.enumerated().map { index, member in
            let score = scores[member.id] ?? 0
            if previous != score { rank = index + 1 }
            previous = score
            return LeagueStanding(participant: member, score: score, rank: rank)
        }
    }

    /// Applies an entire result atomically. Duplicates are no-ops, including after closure.
    @discardableResult
    public mutating func record(_ result: LeagueResult) throws -> Bool {
        if resultIDs.contains(result.id) { return false }
        guard closedAt == nil else { throw ProgressionError.seasonClosed }
        guard window.contains(result.date) else { throw ProgressionError.notAvailable }
        guard results.count < resultCapacity else { throw ProgressionError.capacityExceeded }
        let known = Set(participants.map(\.id))
        guard result.scores.keys.allSatisfy({ known.contains($0) }) else { throw ProgressionError.unknownParticipant }
        var updated = scores
        for (id, value) in result.scores {
            switch rules.scoring {
            case .total:
                let (total, overflow) = (updated[id] ?? 0).addingReportingOverflow(value)
                guard !overflow else { throw ProgressionError.invalidValue }
                updated[id] = total
            case .best: updated[id] = max(updated[id] ?? 0, value)
            }
        }
        scores = updated; results.append(result); resultIDs.insert(result.id)
        return true
    }

    /// Closes an ended season once and returns stable placements on subsequent calls.
    /// Whole tie groups crossing a cutoff stay put. Creating the next season is an explicit application action.
    @discardableResult
    public mutating func finalize(at date: Date) throws -> [LeaguePlacement] {
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw ProgressionError.invalidValue }
        guard date >= window.end else { throw ProgressionError.seasonNotEnded }
        if closedAt != nil { return placements }
        var final: [LeaguePlacement] = []
        for (tierIndex, tier) in tiers.enumerated() {
            let ranked = try standings(in: tier.id)
            let tiedCounts = Dictionary(grouping: ranked, by: \.score).mapValues(\.count)
            let promotionEnd = min(rules.promotionPlaces, ranked.count)
            let demotionStart = max(promotionEnd, ranked.count - min(rules.demotionPlaces, ranked.count))
            for row in ranked {
                let lastPosition = row.rank + (tiedCounts[row.score] ?? 1) - 1
                let next: Int
                if tierIndex + 1 < tiers.count, lastPosition <= promotionEnd { next = tierIndex + 1 }
                else if tierIndex > 0, row.rank > demotionStart { next = tierIndex - 1 }
                else { next = tierIndex }
                final.append(LeaguePlacement(id: row.id, standing: row, nextTierID: tiers[next].id))
            }
        }
        placements = final; closedAt = date
        return final
    }

    private enum CodingKeys: String, CodingKey { case version, id, title, window, tiers, participants, rules, resultCapacity, results, closedAt }
    /// Saves canonical roster, policy, results, and finalization time.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(1, forKey: .version); try c.encode(id, forKey: .id); try c.encode(title, forKey: .title)
        try c.encode(window, forKey: .window); try c.encode(tiers, forKey: .tiers)
        try c.encode(participants, forKey: .participants); try c.encode(rules, forKey: .rules)
        try c.encode(resultCapacity, forKey: .resultCapacity); try c.encode(results, forKey: .results)
        try c.encodeIfPresent(closedAt, forKey: .closedAt)
    }
    /// Restores by validating and replaying results, then recomputing placements.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .version) == 1 else { throw ProgressionError.invalidSave }
        try self.init(id: c.decode(String.self, forKey: .id), title: c.decode(String.self, forKey: .title),
            window: c.decode(ProgressionWindow.self, forKey: .window), tiers: c.decode([LeagueTier].self, forKey: .tiers),
            participants: c.decode([LeagueParticipant].self, forKey: .participants), rules: c.decode(LeagueRules.self, forKey: .rules),
            resultCapacity: c.decode(Int.self, forKey: .resultCapacity))
        let saved = try c.decode([LeagueResult].self, forKey: .results)
        guard saved.count <= resultCapacity else { throw ProgressionError.invalidSave }
        for result in saved {
            guard !resultIDs.contains(result.id) else { throw ProgressionError.invalidSave }
            try record(result)
        }
        if let date = try c.decodeIfPresent(Date.self, forKey: .closedAt) { try finalize(at: date) }
    }
}
