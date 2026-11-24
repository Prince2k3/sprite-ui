import Foundation
@preconcurrency import GameKit

extension GameCenterActivitiesDriver {
    static var native: Self {
        if #available(iOS 26, macOS 26, *) { return NativeActivitiesAdapter().driver }
        return Self(isSupported: false, load: { throw GameCenterServiceError.unavailable }, make: { _, _, _ in throw GameCenterServiceError.unavailable },
            listen: { _ in throw GameCenterServiceError.unavailable }, hasPending: { false }, validatesPartyCode: { _ in false })
    }
}

@available(iOS 26, macOS 26, *)
@MainActor private final class NativeActivitiesAdapter {
    private var definitions: [String: GKGameActivityDefinition] = [:]
    var driver: GameCenterActivitiesDriver {
        .init(load: { [self] in
            let values = try await GKGameActivityDefinition.all
            try Task.checkCancellation()
            guard values.count <= 256, Set(values.map(\.identifier)).count == values.count else { throw GameCenterServiceError.invalidData }
            definitions = Dictionary(uniqueKeysWithValues: values.map { ($0.identifier, $0) })
            return values.map { .init(id: $0.identifier, title: $0.title, details: $0.details,
                defaultProperties: $0.defaultProperties, supportsPartyCode: $0.supportsPartyCode) }
        }, make: { [self] id, code, properties in
            try Task.checkCancellation()
            guard GKLocalPlayer.local.isAuthenticated else { throw GameCenterServiceError.notAuthenticated }
            guard let definition = definitions[id] else { throw GameCenterServiceError.notFound }
            let native: GKGameActivity
            if let code { native = try GKGameActivity.start(definition: definition, partyCode: code) }
            else { native = GKGameActivity(definition: definition) }
            native.properties = properties
            return NativeActivityHandle(native, playerID: GKLocalPlayer.local.gamePlayerID, owned: code != nil)
        }, listen: { receiver in
            let listener = NativeActivityListener(receiver: receiver)
            GKLocalPlayer.local.register(listener)
            return { GKLocalPlayer.local.unregisterListener(listener) }
        }, hasPending: { await GKGameActivity.hasPendingGameActivities }, validatesPartyCode: { GKGameActivity.isValidPartyCode($0) })
    }
}

@available(iOS 26, macOS 26, *)
@MainActor private final class NativeActivityHandle: GameCenterActivityHandle {
    private let native: GKGameActivity
    private let playerID: String
    private var retired = false
    private var owned: Bool
    private var scores: [String: GameCenterActivityScore] = [:]
    private var progress: [String: Double] = [:]
    init(_ native: GKGameActivity, playerID: String, owned: Bool = false) { self.native = native; self.playerID = playerID; self.owned = owned }
    isolated deinit {
        // Never implicitly flush gameplay results just because the wrapper was released.
        if owned, native.state != .ended {
            clearResults()
            if GKLocalPlayer.local.isAuthenticated, GKLocalPlayer.local.gamePlayerID == playerID { native.end() }
        }
    }
    private var boards: [String: GKLeaderboard] = [:]
    var snapshot: GameCenterActivity {
        let state: GameCenterActivityState
        switch native.state {
        case .initialized: state = .initialized
        case .active: state = .active
        case .paused: state = .paused
        case .ended: state = .ended
        @unknown default: state = .ended
        }
        return .init(id: native.identifier, definitionID: native.activityDefinition.identifier, properties: native.properties,
            partyCode: native.partyCode, partyURL: native.partyURL, state: state, createdAt: native.creationDate,
            scores: scores, achievementProgress: progress)
    }
    func activate() { guard !retired else { return }; owned = true; if native.state == .paused { native.resume() } else { native.start() } }
    func pause() { guard !retired else { return }; native.pause() }
    func resume() { guard !retired else { return }; native.resume() }
    func setScore(_ score: GameCenterActivityScore, for identifier: String) async throws {
        try checkPlayer()
        let leaderboard: GKLeaderboard
        if let known = boards[identifier] { leaderboard = known }
        else {
            let values = try await GKLeaderboard.loadLeaderboards(IDs: [identifier])
            try Task.checkCancellation(); try checkPlayer()
            guard let value = values.first(where: { $0.baseLeaderboardID == identifier }) else { throw GameCenterServiceError.notFound }
            leaderboard = value; boards[identifier] = value
        }
        native.setScore(on: leaderboard, to: score.value, context: Int(bitPattern: UInt(score.context))); scores[identifier] = score
    }
    func setProgress(_ percent: Double, for identifier: String) {
        guard !retired else { return }
        native.setProgress(on: GKAchievement(identifier: identifier), to: percent); progress[identifier] = percent
    }
    func clearResults() {
        retired = true
        native.removeScores(from: Array(boards.values))
        native.removeAchievements(native.achievements.filter { progress[$0.identifier] != nil })
        scores = [:]; progress = [:]
    }
    func end() {
        guard GKLocalPlayer.local.isAuthenticated, GKLocalPlayer.local.gamePlayerID == playerID else { clearResults(); return }
        native.end(); retired = true
    }
    private func checkPlayer() throws {
        guard !retired else { throw GameCenterServiceError.cancelled }
        guard native.state != .ended else { throw GameCenterServiceError.activityEnded }
        guard GKLocalPlayer.local.isAuthenticated, GKLocalPlayer.local.gamePlayerID == playerID else { throw GameCenterServiceError.accountChanged }
    }
}

@available(iOS 26, macOS 26, *)
@MainActor private final class NativeActivityListener: NSObject, @preconcurrency GKLocalPlayerListener {
    let receiver: @MainActor (String, any GameCenterActivityHandle) -> Bool
    init(receiver: @escaping @MainActor (String, any GameCenterActivityHandle) -> Bool) { self.receiver = receiver }
    func player(_ player: GKPlayer, wantsToPlay activity: GKGameActivity) async -> Bool {
        // Interoperation with externally staged raw GameKit attempts would risk unintended submissions.
        guard activity.leaderboardScores.isEmpty, activity.achievements.isEmpty else { return false }
        return receiver(player.gamePlayerID, NativeActivityHandle(activity, playerID: player.gamePlayerID))
    }
}
