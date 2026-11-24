import ECSCore
import Foundation
import Gameplay
import GameplayECS
import Testing

private let origin = Date(timeIntervalSince1970: 1_000)
private func time(_ seconds: Double) -> Date { origin.addingTimeInterval(seconds) }
private func objective(_ metric: String = "coin", _ target: Int = 3) throws -> QuestObjective {
    try .init(id: metric, metric: metric, target: target)
}
private func quest(_ id: String = "first", prerequisites: [String] = [], window: ProgressionWindow? = nil) throws -> QuestDefinition {
    try .init(id: id, title: id, objectives: [objective()], prerequisites: prerequisites, window: window,
              rewards: [QuestReward("gold", amount: 5)])
}
private func occurrence(_ id: String, _ amount: Int = 1, _ date: Date = origin, metric: String = "coin") throws -> QuestEvent {
    try .init(id: id, metric: metric, amount: amount, at: date)
}
private func altered<T: Encodable>(_ value: T, _ change: (inout [String: Any]) -> Void) throws -> Data {
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    change(&object)
    return try JSONSerialization.data(withJSONObject: object)
}

@Suite struct QuestJournalTests {
    @Test func objectivesAdvanceIndependentlyAndCapWithoutOverflow() throws {
        let definition = try QuestDefinition(id: "two", title: "Two tasks", objectives: [objective(), objective("win", 1)])
        var journal = try QuestJournal(playerID: "p", quests: [definition])
        #expect(try journal.record(occurrence("one", Int.max)).isEmpty)
        #expect(try journal.progress(for: "two", at: origin).counts == [3, 0])
        #expect(try journal.progress(for: "two", at: origin).fractionCompleted == 0.5)
        #expect(try journal.record(occurrence("two", metric: "win")) == ["two"])
        #expect(try journal.progress(for: "two", at: origin).status == .completed)
    }

    @Test func duplicateEventsCannotAdvanceUnlockedQuests() throws {
        var journal = try QuestJournal(playerID: "p", quests: [quest(), quest("next", prerequisites: ["first"])])
        #expect(try journal.progress(for: "next", at: origin).status == .locked)
        #expect(try journal.record(occurrence("early", 1)) == [])
        #expect(try journal.record(occurrence("finish", 2)) == ["first"])
        #expect(try journal.progress(for: "next", at: origin).counts == [0])
        #expect(try journal.record(occurrence("early", 999)) == [])
        #expect(try journal.progress(for: "next", at: origin).counts == [0])
        try journal.record(occurrence("new", 3))
        #expect(try journal.progress(for: "next", at: origin).status == .completed)
    }

    @Test func anIgnoredEventIsStillConsumed() throws {
        var journal = try QuestJournal(playerID: "p", quests: [quest()])
        try journal.record(occurrence("ignored", metric: "other"))
        try journal.record(occurrence("ignored", 3))
        #expect(journal.events.count == 1)
        #expect(try journal.progress(for: "first", at: origin).counts == [0])
    }

    @Test func halfOpenWindowAndCompletionAfterExpiry() throws {
        let window = try ProgressionWindow(start: origin, end: time(10))
        var journal = try QuestJournal(playerID: "p", quests: [quest(window: window)])
        #expect(try journal.progress(for: "first", at: time(-1)).status == .upcoming)
        try journal.record(occurrence("before", 1, time(-1)))
        try journal.record(occurrence("inside", 3, origin))
        #expect(try journal.progress(for: "first", at: time(10)).status == .completed)
        let claim = try journal.claim("first", at: time(11))
        let expectedRewards = try [QuestReward("gold", amount: 5)]
        #expect(claim.rewards == expectedRewards)
        #expect(try journal.progress(for: "first", at: time(12)).status == .claimed)
        var expired = try QuestJournal(playerID: "p", quests: [quest(window: window)])
        try expired.record(occurrence("end", 3, time(10)))
        #expect(try expired.progress(for: "first", at: time(10)).status == .expired)
        #expect(throws: ProgressionError.notComplete) { try expired.claim("first", at: time(11)) }
    }

    @Test func rewardIsClaimedOnceAndReceiptIDsAreUnambiguous() throws {
        var journal = try QuestJournal(playerID: "p", quests: [quest()])
        #expect(throws: ProgressionError.notComplete) { try journal.claim("first", at: origin) }
        try journal.record(occurrence("finish", 3))
        #expect(throws: ProgressionError.invalidValue) { try journal.claim("first", at: time(-1)) }
        let receipt = try journal.claim("first", at: origin)
        #expect(receipt.id == journal.claims.first?.id)
        #expect(throws: ProgressionError.alreadyClaimed) { try journal.claim("first", at: origin) }
        #expect(journal.claims.count == 1)
    }

    @Test func clockAndCapacityFailuresAreAtomic() throws {
        var journal = try QuestJournal(playerID: "p", quests: [quest()], eventCapacity: 2)
        try journal.record(occurrence("one", 1, time(1)))
        let saved = journal
        #expect(throws: ProgressionError.invalidValue) { try journal.record(occurrence("past", 1, origin)) }
        #expect(journal == saved)
        try journal.record(occurrence("two", 1, time(2)))
        let full = journal
        #expect(throws: ProgressionError.capacityExceeded) { try journal.record(occurrence("three", 1, time(3))) }
        #expect(journal == full)
        #expect(try journal.record(occurrence("one", 5)).isEmpty)
    }

    @Test func invalidCatalogsAndValuesAreRejected() throws {
        #expect(throws: ProgressionError.invalidDefinition) { try objective("coin", 0) }
        #expect(throws: ProgressionError.invalidValue) { try occurrence("bad", -1) }
        #expect(throws: ProgressionError.invalidDefinition) { try ProgressionWindow(start: origin, end: origin) }
        #expect(throws: ProgressionError.invalidDefinition) { try QuestJournal(playerID: "", quests: []) }
        #expect(throws: ProgressionError.invalidDefinition) { try QuestJournal(playerID: "p", quests: [quest(), quest()]) }
        #expect(throws: ProgressionError.invalidDefinition) { try QuestJournal(playerID: "p", quests: [quest(prerequisites: ["missing"])]) }
        #expect(throws: ProgressionError.invalidDefinition) {
            try QuestJournal(playerID: "p", quests: [quest("a", prerequisites: ["b"]), quest("b", prerequisites: ["a"])])
        }
    }

    @Test func saveReplaysProgressClaimsAndDuplicateProtection() throws {
        var journal = try QuestJournal(playerID: "p", quests: [quest()])
        try journal.record(occurrence("finish", 3))
        try journal.claim("first", at: time(1))
        var restored = try JSONDecoder().decode(QuestJournal.self, from: JSONEncoder().encode(journal))
        #expect(restored == journal)
        try restored.record(occurrence("finish", 3))
        #expect(restored == journal)
        #expect(throws: ProgressionError.alreadyClaimed) { try restored.claim("first", at: time(2)) }
    }

    @Test func malformedSavesDoNotTrustCountersOrReceipts() throws {
        var journal = try QuestJournal(playerID: "p", quests: [quest()])
        try journal.record(occurrence("finish", 3))
        try journal.claim("first", at: time(1))
        let duplicate = try altered(journal) { data in data["events"] = (data["events"] as! [Any]) + (data["events"] as! [Any]) }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(QuestJournal.self, from: duplicate) }
        let version = try altered(journal) { $0["version"] = 2 }
        #expect(throws: ProgressionError.invalidSave) { try JSONDecoder().decode(QuestJournal.self, from: version) }
        let impossible = try altered(journal) { $0["events"] = [] }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(QuestJournal.self, from: impossible) }
    }

    @Test func repeatsUseSeparateOccurrenceIDsAndWindows() throws {
        var journal = try QuestJournal(playerID: "p", quests: [
            quest("day1", window: ProgressionWindow(start: origin, end: time(10))),
            quest("day2", window: ProgressionWindow(start: time(10), end: time(20)))])
        try journal.record(occurrence("a", 3, origin))
        try journal.record(occurrence("b", 1, time(10)))
        #expect(try journal.progress(for: "day1", at: time(11)).status == .completed)
        #expect(try journal.progress(for: "day2", at: time(11)).counts == [1])
    }
}

private func season(scoring: LeagueRules.Scoring = .total, capacity: Int = 10_000) throws -> LeagueSeason {
    try LeagueSeason(id: "season1", title: "Practice", window: ProgressionWindow(start: origin, end: time(100)),
        tiers: [LeagueTier(id: "bronze", title: "Bronze"), LeagueTier(id: "silver", title: "Silver"), LeagueTier(id: "gold", title: "Gold")],
        participants: [LeagueParticipant(id: "a", displayName: "Alice", tierID: "silver"),
            LeagueParticipant(id: "b", displayName: "Bob", tierID: "silver"), LeagueParticipant(id: "c", displayName: "Casey", tierID: "silver")],
        rules: LeagueRules(scoring: scoring), resultCapacity: capacity)
}
private func result(_ id: String = "match1", _ scores: [String: Int] = ["a": 10, "b": 5, "c": 1], _ date: Date = origin) throws -> LeagueResult {
    try .init(id: id, scores: scores, at: date)
}

@Suite struct LeagueSeasonTests {
    @Test func accumulatedAndBestScoring() throws {
        var total = try season(), best = try season(scoring: .best)
        for outcome in try [result(), result("match2", ["a": 3, "b": 7])] {
            try total.record(outcome); try best.record(outcome)
        }
        #expect(total.score(for: "a") == 13)
        #expect(total.score(for: "b") == 12)
        #expect(best.score(for: "a") == 10)
        #expect(best.score(for: "b") == 7)
        #expect(total.score(for: "missing") == nil)
    }

    @Test func tiedCompetitionRanksAndStableOrdering() throws {
        var league = try season()
        try league.record(result("tie", ["b": 10, "a": 10, "c": 1]))
        let rows = try league.standings(in: "silver")
        #expect(rows.map(\.id) == ["a", "b", "c"])
        #expect(rows.map(\.rank) == [1, 1, 3])
        let placements = try league.finalize(at: time(100))
        #expect(placements.map(\.nextTierID) == ["silver", "silver", "bronze"])
    }

    @Test func promotionsDemotionsAndFinalizationAreStable() throws {
        var league = try season()
        try league.record(result())
        #expect(throws: ProgressionError.seasonNotEnded) { try league.finalize(at: time(99)) }
        let placements = try league.finalize(at: time(100))
        #expect(placements.map(\.nextTierID) == ["gold", "silver", "bronze"])
        #expect(try league.finalize(at: time(200)) == placements)
        #expect(league.closedAt == time(100))
        #expect(throws: ProgressionError.seasonClosed) { try league.record(result("late")) }
        #expect(try league.record(result()) == false)
    }

    @Test func tieAtDemotionCutoffStaysTogether() throws {
        var league = try season()
        try league.record(result("tie", ["a": 10, "b": 1, "c": 1]))
        #expect(try league.finalize(at: time(100)).map(\.nextTierID) == ["gold", "silver", "silver"])
    }

    @Test func invalidResultCannotPartiallyChangeScores() throws {
        var league = try season()
        try league.record(result("max", ["a": Int.max]))
        let before = league
        #expect(throws: ProgressionError.invalidValue) { try league.record(result("overflow", ["b": 5, "a": 1])) }
        #expect(league == before)
        #expect(throws: ProgressionError.unknownParticipant) { try league.record(result("foreign", ["a": 1, "x": 5])) }
        #expect(league == before)
    }

    @Test func resultEligibilityAndCapacityAreExplicit() throws {
        var league = try season(capacity: 1)
        #expect(throws: ProgressionError.notAvailable) { try league.record(result("before", ["a": 1], time(-1))) }
        #expect(throws: ProgressionError.notAvailable) { try league.record(result("end", ["a": 1], time(100))) }
        try league.record(result())
        #expect(throws: ProgressionError.capacityExceeded) { try league.record(result("another")) }
        #expect(try league.record(result("match1", ["a": Int.max])) == false)
    }

    @Test func saveRestoresRanksPlacementsAndReplayProtection() throws {
        var league = try season()
        try league.record(result())
        try league.finalize(at: time(100))
        var loaded = try JSONDecoder().decode(LeagueSeason.self, from: JSONEncoder().encode(league))
        #expect(loaded == league)
        #expect(try loaded.record(result()) == false)
        let duplicate = try altered(league) { $0["results"] = ($0["results"] as! [Any]) + ($0["results"] as! [Any]) }
        #expect(throws: ProgressionError.invalidSave) { try JSONDecoder().decode(LeagueSeason.self, from: duplicate) }
        let early = try altered(league) { $0["closedAt"] = origin.timeIntervalSinceReferenceDate }
        #expect(throws: ProgressionError.seasonNotEnded) { try JSONDecoder().decode(LeagueSeason.self, from: early) }
    }

    @Test func invalidLeagueDefinitionsAreRejected() throws {
        #expect(throws: ProgressionError.invalidDefinition) { try LeagueRules(promotionPlaces: -1) }
        #expect(throws: ProgressionError.invalidValue) { try result("negative", ["a": -1]) }
        let good = try season()
        #expect(throws: ProgressionError.invalidDefinition) {
            try LeagueSeason(id: good.id, title: good.title, window: good.window, tiers: good.tiers,
                             participants: good.participants + good.participants, rules: good.rules)
        }
    }
}

@MainActor @Suite(.serialized) struct QuestEntityTests {
    @Test func entityEventsSeeCommittedProgressAndDuplicatesPublishNothing() throws {
        let world = World()
        let entity = Entity()
        entity.components.set(QuestJournalComponent(try QuestJournal(playerID: "p", quests: [quest()])))
        world.addEntity(entity)
        var events = 0, claims = 0
        let a = world.subscribe(to: QuestEvents.Recorded.self, on: entity) { event in
            events += 1
            #expect(event.completedQuestIDs == ["first"])
            let status = try? entity.components[QuestJournalComponent.self]?.journal.progress(for: "first", at: origin).status
            #expect(status == .completed)
        }
        let b = world.subscribe(to: QuestEvents.RewardClaimed.self, on: entity) { _ in claims += 1 }
        try entity.recordQuestEvent(occurrence("done", 3))
        try entity.recordQuestEvent(occurrence("done", 3))
        try entity.claimQuestReward("first", at: origin)
        #expect(events == 1 && claims == 1)
        withExtendedLifetime([a, b]) {}
    }

    @Test func journalIsIncludedInWorldSnapshotsWhenRegistered() throws {
        QuestJournalComponent.registerComponent()
        let world = World(), entity = Entity()
        entity.name = "player"
        entity.components.set(QuestJournalComponent(try QuestJournal(playerID: "p", quests: [quest()])))
        world.addEntity(entity)
        try entity.recordQuestEvent(occurrence("one"))
        let save = try world.snapshot().jsonData()
        world.restore(try WorldSnapshot(data: save))
        let restored = try #require(world.entities.first)
        #expect(restored.components[QuestJournalComponent.self]?.journal == entity.components[QuestJournalComponent.self]?.journal)
    }
}
