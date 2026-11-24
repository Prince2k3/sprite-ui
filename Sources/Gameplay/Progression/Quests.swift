import Foundation

/// A counted objective. All objectives of a quest must reach their targets.
public struct QuestObjective: Hashable, Codable, Sendable, Identifiable {
    /// A stable identifier within its quest.
    public let id: String
    /// The gameplay event metric to count, such as `coins` or `wins`.
    public let metric: String
    /// The positive number of units required.
    public let target: Int

    /// Creates a validated objective.
    public init(id: String, metric: String, target: Int) throws {
        try validateProgressionID(id); try validateProgressionID(metric)
        guard target > 0 else { throw ProgressionError.invalidDefinition }
        self.id = id; self.metric = metric; self.target = target
    }
    private enum CodingKeys: String, CodingKey { case id, metric, target }
    /// Decodes and validates an objective.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(String.self, forKey: .id), metric: c.decode(String.self, forKey: .metric), target: c.decode(Int.self, forKey: .target))
    }
}

/// An application-defined reward, returned as data rather than granted to a wallet.
public struct QuestReward: Hashable, Codable, Sendable {
    /// The application's reward or currency identifier.
    public let identifier: String
    /// The positive quantity to grant.
    public let amount: Int
    /// Creates a validated reward.
    public init(_ identifier: String, amount: Int = 1) throws {
        try validateProgressionID(identifier)
        guard amount > 0 else { throw ProgressionError.invalidDefinition }
        self.identifier = identifier; self.amount = amount
    }
    private enum CodingKeys: String, CodingKey { case identifier, amount }
    /// Decodes and validates a reward.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(c.decode(String.self, forKey: .identifier), amount: c.decode(Int.self, forKey: .amount))
    }
}

/// One quest occurrence. Use a new ID for each daily or seasonal repeat.
public struct QuestDefinition: Hashable, Codable, Sendable, Identifiable {
    /// A stable, occurrence-specific identifier.
    public let id: String
    /// The display title.
    public let title: String
    /// The objectives, all of which are required.
    public let objectives: [QuestObjective]
    /// Quest IDs that must have completed before an event can count.
    public let prerequisites: [String]
    /// An optional eligibility interval. Completion remains claimable afterward.
    public let window: ProgressionWindow?
    /// Rewards returned by a successful claim.
    public let rewards: [QuestReward]

    /// Creates a quest. A journal validates references and rejects prerequisite cycles.
    public init(id: String, title: String, objectives: [QuestObjective], prerequisites: [String] = [],
                window: ProgressionWindow? = nil, rewards: [QuestReward] = []) throws {
        try validateProgressionID(id)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !objectives.isEmpty,
              Set(objectives.map(\.id)).count == objectives.count,
              Set(prerequisites).count == prerequisites.count, !prerequisites.contains(id) else {
            throw ProgressionError.invalidDefinition
        }
        for prerequisite in prerequisites { try validateProgressionID(prerequisite) }
        self.id = id; self.title = title; self.objectives = objectives
        self.prerequisites = prerequisites; self.window = window; self.rewards = rewards
    }
    private enum CodingKeys: String, CodingKey { case id, title, objectives, prerequisites, window, rewards }
    /// Decodes and validates a definition.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(String.self, forKey: .id), title: c.decode(String.self, forKey: .title),
            objectives: c.decode([QuestObjective].self, forKey: .objectives),
            prerequisites: c.decode([String].self, forKey: .prerequisites),
            window: c.decodeIfPresent(ProgressionWindow.self, forKey: .window), rewards: c.decode([QuestReward].self, forKey: .rewards))
    }
}

/// A stable gameplay occurrence. Retrying the same ID never counts twice in a journal.
public struct QuestEvent: Hashable, Codable, Sendable, Identifiable {
    /// A unique occurrence ID, supplied by the game or authoritative server.
    public let id: String
    /// The objective metric to advance.
    public let metric: String
    /// The positive number of units observed.
    public let amount: Int
    /// The explicit event time. Events must be recorded in nondecreasing time order.
    public let date: Date
    /// Creates a validated event, without reading a clock.
    public init(id: String, metric: String, amount: Int = 1, at date: Date) throws {
        try validateProgressionID(id); try validateProgressionID(metric)
        guard amount > 0, date.timeIntervalSinceReferenceDate.isFinite else { throw ProgressionError.invalidValue }
        self.id = id; self.metric = metric; self.amount = amount; self.date = date
    }
    private enum CodingKeys: String, CodingKey { case id, metric, amount, date }
    /// Decodes and validates an event.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(String.self, forKey: .id), metric: c.decode(String.self, forKey: .metric),
            amount: c.decode(Int.self, forKey: .amount), at: c.decode(Date.self, forKey: .date))
    }
}

/// A quest's evaluated availability at a caller-supplied time.
public enum QuestStatus: String, Codable, Sendable { case locked, upcoming, active, expired, completed, claimed }

/// Progress in objective order, with the mean completion fraction of the objectives.
public struct QuestProgress: Equatable, Sendable {
    /// The quest occurrence ID.
    public let questID: String
    /// The current eligibility or completion state.
    public let status: QuestStatus
    /// Counts aligned with the definition's objectives.
    public let counts: [Int]
    /// The mean objective completion fraction, in zero through one.
    public let fractionCompleted: Double
}

/// A durable claim receipt. Store it and your granted reward in one application transaction.
public struct QuestRewardClaim: Hashable, Codable, Sendable, Identifiable {
    /// A stable player/quest claim key, also usable as an application idempotency key.
    public var id: String { "\(playerID.utf8.count):\(playerID)\(questID)" }
    /// The journal owner.
    public let playerID: String
    /// The completed quest occurrence.
    public let questID: String
    /// Rewards described by the quest definition.
    public let rewards: [QuestReward]
    /// The explicit claim time.
    public let date: Date
}

/// Player-owned, deterministic quest progress. Codable saves retain the full bounded event ledger.
/// This is a local rules engine, not an anti-cheat or cloud-authority service.
public struct QuestJournal: Equatable, Sendable, Codable {
    /// The stable local or Game Center player identifier.
    public let playerID: String
    /// Definitions in display order, including occurrence IDs and schedules.
    public let quests: [QuestDefinition]
    /// Maximum unique events retained. At capacity, new events throw rather than losing deduplication.
    public let eventCapacity: Int
    /// Successfully recorded events, including ones that matched no active quest.
    public private(set) var events: [QuestEvent] = []
    /// Successfully claimed rewards, in claim order.
    public private(set) var claims: [QuestRewardClaim] = []
    private var counts: [String: [Int]] = [:]
    private var completed: [String: Date] = [:]
    private var eventIDs: Set<String> = []

    /// Creates a bounded journal, rejecting missing prerequisites, duplicate IDs, and cycles.
    public init(playerID: String, quests: [QuestDefinition], eventCapacity: Int = 10_000) throws {
        try validateProgressionID(playerID)
        guard eventCapacity > 0, eventCapacity <= 1_000_000,
              Set(quests.map(\.id)).count == quests.count else { throw ProgressionError.invalidDefinition }
        let byID = Dictionary(uniqueKeysWithValues: quests.map { ($0.id, $0) })
        var remaining: [String: Int] = [:], dependents: [String: [String]] = [:]
        for quest in quests {
            remaining[quest.id] = quest.prerequisites.count
            for prerequisite in quest.prerequisites {
                guard byID[prerequisite] != nil else { throw ProgressionError.invalidDefinition }
                dependents[prerequisite, default: []].append(quest.id)
            }
        }
        var queue = quests.filter { $0.prerequisites.isEmpty }.map(\.id), index = 0
        while index < queue.count {
            for dependent in dependents[queue[index]] ?? [] {
                remaining[dependent, default: 0] -= 1
                if remaining[dependent] == 0 { queue.append(dependent) }
            }
            index += 1
        }
        guard queue.count == quests.count else { throw ProgressionError.invalidDefinition }
        self.playerID = playerID; self.quests = quests; self.eventCapacity = eventCapacity
    }

    /// Returns progress at `date`. Prerequisites depend on completion, not reward claiming.
    public func progress(for id: String, at date: Date) throws -> QuestProgress {
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw ProgressionError.invalidValue }
        guard let quest = quests.first(where: { $0.id == id }) else { throw ProgressionError.unknownQuest }
        let values = counts[id] ?? Array(repeating: 0, count: quest.objectives.count)
        let fraction = zip(values, quest.objectives).reduce(0.0) { $0 + Double($1.0) / Double($1.1.target) } / Double(values.count)
        let status: QuestStatus
        if claims.contains(where: { $0.questID == id }) { status = .claimed }
        else if completed[id] != nil { status = .completed }
        else if let window = quest.window, date >= window.end { status = .expired }
        else if !quest.prerequisites.allSatisfy({ completed[$0] != nil }) { status = .locked }
        else if let window = quest.window, date < window.start { status = .upcoming }
        else { status = .active }
        return QuestProgress(questID: id, status: status, counts: values, fractionCompleted: fraction)
    }

    /// Records an occurrence and returns quest IDs newly completed by it, in definition order.
    /// A duplicate ID is a no-op, even if its payload differs. One event cannot unlock and advance a dependent quest.
    @discardableResult
    public mutating func record(_ event: QuestEvent) throws -> [String] {
        if eventIDs.contains(event.id) { return [] }
        guard events.count < eventCapacity else { throw ProgressionError.capacityExceeded }
        guard events.last.map({ event.date >= $0.date }) ?? true else { throw ProgressionError.invalidValue }
        let eligible = quests.filter { quest in
            completed[quest.id] == nil && quest.prerequisites.allSatisfy { completed[$0] != nil }
                && (quest.window?.contains(event.date) ?? true)
        }
        var newlyCompleted: [String] = []
        for quest in eligible {
            var values = counts[quest.id] ?? Array(repeating: 0, count: quest.objectives.count)
            for (index, objective) in quest.objectives.enumerated() where objective.metric == event.metric {
                // Subtract before adding to avoid overflow for very large event amounts.
                values[index] += min(event.amount, objective.target - values[index])
            }
            counts[quest.id] = values
            if zip(values, quest.objectives).allSatisfy({ $0.0 == $0.1.target }) {
                completed[quest.id] = event.date; newlyCompleted.append(quest.id)
            }
        }
        events.append(event); eventIDs.insert(event.id)
        return newlyCompleted
    }

    /// Claims a completed quest once, returning a receipt without granting external currency.
    /// Persist this journal and application rewards atomically; restoring an older save can repeat a grant otherwise.
    @discardableResult
    public mutating func claim(_ id: String, at date: Date) throws -> QuestRewardClaim {
        guard let quest = quests.first(where: { $0.id == id }) else { throw ProgressionError.unknownQuest }
        guard !claims.contains(where: { $0.questID == id }) else { throw ProgressionError.alreadyClaimed }
        guard let completion = completed[id] else { throw ProgressionError.notComplete }
        guard date.timeIntervalSinceReferenceDate.isFinite, date >= completion else { throw ProgressionError.invalidValue }
        let claim = QuestRewardClaim(playerID: playerID, questID: id, rewards: quest.rewards, date: date)
        claims.append(claim); return claim
    }

    private enum CodingKeys: String, CodingKey { case version, playerID, quests, eventCapacity, events, claims }
    /// Saves canonical inputs and receipts rather than trusting derived counts on restore.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(1, forKey: .version); try c.encode(playerID, forKey: .playerID)
        try c.encode(quests, forKey: .quests); try c.encode(eventCapacity, forKey: .eventCapacity)
        try c.encode(events, forKey: .events); try c.encode(claims, forKey: .claims)
    }
    /// Restores by replaying and validating the complete ledger and claim receipts.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .version) == 1 else { throw ProgressionError.invalidSave }
        try self.init(playerID: c.decode(String.self, forKey: .playerID), quests: c.decode([QuestDefinition].self, forKey: .quests),
            eventCapacity: c.decode(Int.self, forKey: .eventCapacity))
        let savedEvents = try c.decode([QuestEvent].self, forKey: .events)
        guard savedEvents.count <= eventCapacity else { throw ProgressionError.invalidSave }
        for event in savedEvents {
            guard !eventIDs.contains(event.id) else { throw ProgressionError.invalidSave }
            try record(event)
        }
        for receipt in try c.decode([QuestRewardClaim].self, forKey: .claims) {
            let expected = try claim(receipt.questID, at: receipt.date)
            guard expected == receipt else { throw ProgressionError.invalidSave }
        }
    }
}
