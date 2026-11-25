import Foundation
import Observation
import SpriteUI

/// IDs shared by the test screen, preview fixtures, and Xcode's local GameKit configuration.
enum DemoBotsGameCenterIDs {
    static let achievement = "dev.spriteui.demobots.first_repair"
    static let leaderboard = "dev.spriteui.demobots.repair_score"
    static let activity = "dev.spriteui.demobots.repair_test"
    static let coop = "dev.spriteui.demobots.coop"
    static let challenge = "dev.spriteui.demobots.repair_challenge"
}

/// Explicit sample service actions. This lab never reports campaign progress or authenticates on appearance.
@MainActor @Observable final class DemoBotsGameCenterLab {
    let services: GameCenterServices
    private(set) var message = "Choose a test action. Preview data stays in memory."
    private(set) var busy = false
    private(set) var reportedScore: Int?
    private(set) var acceptedEntryPoints = 0
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    var progress: Double { services.achievements.achievements.first { $0.identifier == DemoBotsGameCenterIDs.achievement }?.percentComplete ?? 0 }
    var isNative: Bool { !services.isPreview }
    var supportsActivities: Bool { services.isPreview || GameCenterActivities.isSupported }
    var canReport: Bool { !busy && (services.isPreview || services.isAuthenticated) }
    var bundledConfigurationSummary: String {
        let bundle = Bundle.main
        let url = bundle.url(forResource: "gameCenterResources", withExtension: "json", subdirectory: "DemoBotsLocal.gamekit")
        return Self.bundledConfigurationSummary(data: url.flatMap { try? Data(contentsOf: $0) },
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }
    static func bundledConfigurationSummary(data: Data?, version: String?, build: String?) -> String {
        guard let data, let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resources = document["resources"] as? [String: Any],
              let challenges = resources["challenges"] as? [[String: Any]] else {
            return "No readable local GameKit bundle in this app."
        }
        let durations = challenges.first { $0["vendorIdentifier"] as? String == DemoBotsGameCenterIDs.challenge }?["allowedDurations"] as? [String]
        return "Bundled challenges: \(challenges.count) · duration options: \(durations?.count.description ?? "missing") · app \(version ?? "missing") (\(build ?? "missing"))"
    }
    var challengeCatalogSummary: String {
        Self.challengeCatalogSummary(services.challenges.definitions)
    }
    static func challengeCatalogSummary(_ definitions: [GameCenterChallengeDefinition]) -> String {
        guard let definition = definitions.first(where: { $0.id == DemoBotsGameCenterIDs.challenge }) else {
            return "Repair Challenge is absent from the loaded catalog (\(definitions.count) challenges)."
        }
        guard let board = definition.leaderboardID else {
            return "Repair Challenge loaded without an associated leaderboard."
        }
        return "Repair Challenge leaderboard: \(board)"
    }

    init(native: Bool = false) {
        services = native ? .init(mode: .live) : .preview()
        do {
            try services.activities.configureRoutes([DemoBotsGameCenterIDs.activity])
            if !native {
                try services.activities.configurePreview([.init(id: DemoBotsGameCenterIDs.activity, title: "Repair Test", defaultProperties: ["mode": "repair-test"])])
                try services.challenges.configurePreview([.init(id: DemoBotsGameCenterIDs.challenge, title: "Repair Challenge", leaderboardID: DemoBotsGameCenterIDs.leaderboard, isRepeatable: true)])
            }
        } catch { message = error.localizedDescription }
        if native { message = "Native GameKit selected. Sign in explicitly. Local isolation requires the Local Game Center scheme and Xcode Debug Mode." }
    }
    isolated deinit { task?.cancel(); services.shutdown() }

    func load() { run { [self] in
        _ = try await services.achievements.load()
        _ = try await services.leaderboards.entries(for: DemoBotsGameCenterIDs.leaderboard)
        var activityCount = 0, challengeCount = 0
        if supportsActivities {
            activityCount = try await services.activities.load().count
            challengeCount = try await services.challenges.load().count
        }
        return "Loaded test progress: \(activityCount) activities · \(challengeCount) challenges returned."
    } }
    func reportProgress(_ value: Double) { run { [self] in
        try await services.achievements.report(progress: value, for: DemoBotsGameCenterIDs.achievement)
        return "Achievement progress reported: \(Int(value))%. Reopen the lab after resetting progress in Game Progress Manager to clear the wrapper’s monotonic cache."
    } }
    func submitScore(_ score: Int) { run { [self] in
        try await services.leaderboards.submit(score: score, to: DemoBotsGameCenterIDs.leaderboard)
        _ = try await services.leaderboards.entries(for: DemoBotsGameCenterIDs.leaderboard)
        reportedScore = score
        return "Test score \(score) submitted. The leaderboard retains its configured best score."
    } }
    func startActivity() { run { [self] in
        _ = try await services.activities.load()
        _ = try await services.activities.start(definitionID: DemoBotsGameCenterIDs.activity)
        return "Repair Test activity started. Finish or discard it explicitly."
    } }
    func finishActivity() { run { [self] in
        _ = try services.activities.finish()
        return "Test activity finished. No campaign score or reward was submitted."
    } }
    func discardActivity() { run { [self] in
        try services.activities.discard()
        return "Test activity discarded."
    } }
    func submitChallengeAttempt() { run { [self] in
        _ = try await services.challenges.load()
        guard services.challenges.definitions.contains(where: { $0.id == DemoBotsGameCenterIDs.challenge && $0.leaderboardID != nil }) else {
            return challengeCatalogSummary + " No score was submitted. Check the active GameKit configuration."
        }
        _ = try await services.challenges.submitAttempt(score: 100, for: DemoBotsGameCenterIDs.challenge, attemptID: UUID())
        return "A new 100-point test attempt was requested. Each press represents a separate attempt; errors are never retried automatically."
    } }
    func simulateEntryPoint() { run { [self] in
        try services.activities.startListening()
        _ = try services.activities.simulateIncomingActivity(definitionID: DemoBotsGameCenterIDs.activity, properties: ["mode": "repair-test"])
        return "Test entry point queued. Accept it explicitly to enter Repair Test."
    } }
    func acceptEntryPoint(_ id: UUID) { run { [self] in
        guard let request = services.activities.pendingRequests.first(where: { $0.id == id }),
              request.activity.definitionID == DemoBotsGameCenterIDs.activity,
              request.activity.properties["mode"] == "repair-test" else { throw GameCenterServiceError.invalidData }
        _ = try services.activities.accept(request: id); acceptedEntryPoints += 1
        return "Entered Repair Test from the queued activity."
    } }
    func close() { generation &+= 1; task?.cancel(); task = nil; busy = false; services.shutdown() }
    private func run(_ action: @escaping @MainActor () async throws -> String) {
        guard !busy else { return }
        busy = true; generation &+= 1; let expected = generation
        task = Task { @MainActor [weak self] in
            do {
                try Task.checkCancellation()
                let result = try await action(); try Task.checkCancellation()
                if self?.generation == expected { self?.message = result }
            } catch { if self?.generation == expected { self?.message = error.localizedDescription } }
            if self?.generation == expected { self?.busy = false; self?.task = nil }
        }
    }
}
