import ECSCore
import Foundation
import Gameplay

/// An entity-owned quest journal. Register this Codable component before taking world snapshots.
public struct QuestJournalComponent: Component, Equatable, Codable, Sendable {
    /// The player's local quest progress and claim receipts.
    public var journal: QuestJournal
    /// Creates an entity adapter for a journal.
    public init(_ journal: QuestJournal) { self.journal = journal }
}

/// Typed quest notifications published after the entity's component has changed.
public enum QuestEvents {
    /// A new gameplay occurrence was recorded, even if it completed no quests.
    public struct Recorded: Event {
        /// The journal owner entity.
        public let entity: Entity
        /// The gameplay occurrence.
        public let occurrence: QuestEvent
        /// Quest IDs completed by this occurrence.
        public let completedQuestIDs: [String]
    }
    /// A reward receipt was committed to the journal. Grant application rewards using its stable ID.
    public struct RewardClaimed: Event {
        /// The journal owner entity.
        public let entity: Entity
        /// The durable claim receipt.
        public let claim: QuestRewardClaim
    }
}

extension Entity {
    /// Records a gameplay occurrence, then publishes one event. A duplicate publishes nothing.
    @discardableResult
    public func recordQuestEvent(_ event: QuestEvent) throws -> [String] {
        guard var component = components[QuestJournalComponent.self] else { throw ProgressionError.notAvailable }
        let before = component.journal.events.count
        let completed = try component.journal.record(event)
        guard component.journal.events.count != before else { return [] }
        components.set(component)
        world?.publish(QuestEvents.Recorded(entity: self, occurrence: event, completedQuestIDs: completed), from: self)
        return completed
    }

    /// Claims a quest reward locally, then publishes its receipt. No currency is granted automatically.
    @discardableResult
    public func claimQuestReward(_ id: String, at date: Date) throws -> QuestRewardClaim {
        guard var component = components[QuestJournalComponent.self] else { throw ProgressionError.notAvailable }
        let claim = try component.journal.claim(id, at: date)
        components.set(component)
        world?.publish(QuestEvents.RewardClaimed(entity: self, claim: claim), from: self)
        return claim
    }
}
