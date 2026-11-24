import Foundation
import Observation

/// Explicit activity lifecycle, result staging, and a bounded cold/warm intent queue.
/// Configure routes before authentication; listen after authentication. Incoming intents never replace a running game.
@MainActor @Observable
public final class GameCenterActivities {
    /// Loaded definition snapshots.
    public var definitions: [GameCenterActivityDefinition] { synchronizeIdentity(); return catalog }
    /// The current or most recently ended activity.
    public var activity: GameCenterActivity? { synchronizeIdentity(); return current }
    /// Requests accepted into this application's route queue; accepting one starts its activity explicitly.
    public var pendingRequests: [GameCenterActivityRequest] { synchronizeIdentity(); return requests }
    /// At most 64 local completion receipts, including lower scores on later attempts.
    public var completedAttempts: [GameCenterActivityCompletion] { synchronizeIdentity(); return completions }
    /// Whether asynchronous definition loading or score staging is in flight.
    public var isLoading: Bool { active != nil }
    /// Whether this instance has registered its activity listener.
    public private(set) var isListening = false
    /// Whether native activities are supported on this OS. Previews work on the package baseline.
    public static var isSupported: Bool { if #available(iOS 26, macOS 26, *) { true } else { false } }
    @ObservationIgnored private let context: GameCenterServiceContext
    @ObservationIgnored private let driver: GameCenterActivitiesDriver
    @ObservationIgnored private let usesPreview: Bool
    @ObservationIgnored private var owner: GameCenterServiceContext.Operation?
    @ObservationIgnored private var unsubscribe: (() -> Void)?
    @ObservationIgnored private var listenerToken: UUID?
    @ObservationIgnored private var routes: Set<String> = []
    @ObservationIgnored private var handles: [UUID: any GameCenterActivityHandle] = [:]
    @ObservationIgnored private var currentHandle: (any GameCenterActivityHandle)?
    @ObservationIgnored private var handled: [String: Bool] = [:]
    @ObservationIgnored private var fixtures: [GameCenterActivityDefinition] = []
    @ObservationIgnored private var cancellation: (() -> Void)?
    private var catalog: [GameCenterActivityDefinition] = []
    private var current: GameCenterActivity?
    private var requests: [GameCenterActivityRequest] = []
    private var completions: [GameCenterActivityCompletion] = []
    private var active: UUID?
    @ObservationIgnored private var partyLease: UUID?
    private static weak var listenerOwner: GameCenterActivities?

    /// Creates a stopped service without authenticating or registering a listener.
    public convenience init(mode: GameCenterServicesMode = .live) { self.init(context: .init(mode: mode)) }
    convenience init(context: GameCenterServiceContext) { self.init(context: context, driver: .native, usesPreview: context.isPreview) }
    init(context: GameCenterServiceContext, driver: GameCenterActivitiesDriver, usesPreview: Bool = false) {
        self.context = context; self.driver = driver; self.usesPreview = usesPreview
    }
    isolated deinit { reset() }

    /// Installs at most 256 local fixture definitions; available only in explicit preview mode.
    public func configurePreview(_ definitions: [GameCenterActivityDefinition]) throws {
        guard usesPreview else { throw GameCenterServiceError.unavailable }
        guard active == nil, currentHandle == nil, requests.isEmpty else { throw GameCenterServiceError.operationInProgress }
        try validateCatalog(definitions); fixtures = definitions; catalog = []
    }

    /// Configures at most 256 known definition IDs without starting native work. Call before sign-in to handle cold launches.
    public func configureRoutes(_ identifiers: Set<String>) throws {
        guard identifiers.count <= 256 else { throw GameCenterServiceError.capacityExceeded }
        for id in identifiers { try validateGameCenterIdentifier(id) }
        routes = identifiers
        for request in requests where !routes.contains(request.activity.definitionID) {
            handles[request.id]?.clearResults(); handles[request.id] = nil; handled[request.activity.id] = false
        }
        requests.removeAll { !routes.contains($0.activity.definitionID) }
    }

    /// Registers after explicit authentication. Empty route configuration is a no-op.
    /// Live listeners are exclusive within SpriteUI; use one retained facade per application.
    public func startListening() throws {
        guard !routes.isEmpty else { return }
        let operation = try begin()
        if isListening { return }
        if !usesPreview {
            guard Self.listenerOwner == nil || Self.listenerOwner === self else { throw GameCenterServiceError.operationInProgress }
            Self.listenerOwner = self
            owner = operation; isListening = true
            let token = UUID(); listenerToken = token
            let previousHandled = handled
            do {
                unsubscribe = try driver.listen { [weak self] player, handle in
                    guard let self, self.listenerToken == token else { return false }
                    return self.receive(player: player, handle: handle)
                }
                try context.validate(operation)
            }
            catch { stopListening(); handled = previousHandled; throw error }
        }
        owner = operation; isListening = true
    }

    /// Stops incoming routing and releases queued intents without finishing a current attempt.
    public func stopListening() {
        listenerToken = nil
        unsubscribe?(); unsubscribe = nil
        if Self.listenerOwner === self { Self.listenerOwner = nil }
        for handle in handles.values { handled[handle.snapshot.id] = nil; handle.clearResults() }
        handles = [:]; requests = []; isListening = false
    }

    /// Checks native pending activity existence without authenticating or showing the welcome experience.
    public func hasPendingActivities() async throws -> Bool {
        if usesPreview { return !pendingRequests.isEmpty }
        guard driver.isSupported else { throw GameCenterServiceError.unavailable }
        try Task.checkCancellation()
        let value = await driver.hasPending()
        try Task.checkCancellation()
        return value
    }

    /// Loads a bounded definition catalog on explicit request.
    @discardableResult public func load() async throws -> [GameCenterActivityDefinition] {
        let values = try await perform { [usesPreview, fixtures, driver] in usesPreview ? fixtures : try await driver.load() }
        try validateCatalog(values); catalog = values; return values
    }

    /// Creates an activity from a loaded definition. A current active/paused attempt must be finished or discarded first.
    @discardableResult public func start(definitionID: String, partyCode: String? = nil,
                                        properties: [String: String] = [:]) async throws -> GameCenterActivity {
        _ = try begin(); try requireNoParty(); try requireNoRunningActivity(); try validateActivityProperties(properties)
        guard let definition = catalog.first(where: { $0.id == definitionID }) else { throw GameCenterServiceError.notFound }
        let code = partyCode?.uppercased()
        if let code {
            guard definition.supportsPartyCode,
                  usesPreview ? validPreviewPartyCode(code) : driver.validatesPartyCode(code) else { throw GameCenterServiceError.invalidValue }
        }
        let merged = definition.defaultProperties.merging(properties) { _, supplied in supplied }
        try validateActivityProperties(merged)
        let handle = try await perform { [usesPreview, driver] in
            if usesPreview { return PreviewActivityHandle(definition: definition, properties: merged, partyCode: code) as any GameCenterActivityHandle }
            return try await driver.make(definitionID, code, merged)
        }
        handle.activate(); currentHandle = handle; current = handle.snapshot
        return handle.snapshot
    }

    /// Accepts a queued intent when the game is ready. No world, level, or profile is loaded automatically.
    @discardableResult public func accept(request id: UUID) throws -> GameCenterActivity {
        _ = try begin(); try requireIdle(); try requireNoParty(); try requireNoRunningActivity()
        guard let handle = handles[id] else { throw GameCenterServiceError.notFound }
        guard handle.snapshot.state != .ended else { throw GameCenterServiceError.activityEnded }
        handles[id] = nil
        requests.removeAll { $0.id == id }
        handle.activate(); currentHandle = handle; current = handle.snapshot; return handle.snapshot
    }

    /// Declines a queued intent. Repeated delivery of that instance is not requeued in this listener session.
    public func decline(request id: UUID) throws {
        _ = try begin()
        guard let handle = handles.removeValue(forKey: id) else { throw GameCenterServiceError.notFound }
        handled[handle.snapshot.id] = false; handle.clearResults(); requests.removeAll { $0.id == id }
    }

    /// Stages the current attempt score, including a value lower than a prior score. This does not submit an attempt.
    public func setScore(_ score: Int, for leaderboardID: String, context: UInt64 = 0) async throws {
        try validateGameCenterIdentifier(leaderboardID)
        let handle = try runningHandle()
        guard handle.snapshot.scores[leaderboardID] != nil || handle.snapshot.scores.count < 64 else { throw GameCenterServiceError.capacityExceeded }
        try await perform { try await handle.setScore(.init(score, context: context), for: leaderboardID) }
        current = handle.snapshot
    }

    /// Stages a finite percentage in 0...100 without reporting it yet.
    public func setAchievementProgress(_ percent: Double, for achievementID: String) throws {
        try requireIdle(); try validateGameCenterIdentifier(achievementID)
        guard percent.isFinite, (0...100).contains(percent) else { throw GameCenterServiceError.invalidValue }
        let handle = try runningHandle()
        guard handle.snapshot.achievementProgress[achievementID] != nil || handle.snapshot.achievementProgress.count < 64 else { throw GameCenterServiceError.capacityExceeded }
        handle.setProgress(percent, for: achievementID); current = handle.snapshot
    }
    /// Pauses activity tracking; the application controls its own world and input separately.
    public func pause() throws { try requireIdle(); let handle = try runningHandle(); handle.pause(); current = handle.snapshot }
    /// Resumes a paused activity.
    public func resume() throws { try requireIdle(); let handle = try runningHandle(); handle.resume(); current = handle.snapshot }

    /// Ends once and hands all staged results to GameKit. This is not remote delivery confirmation.
    @discardableResult public func finish() throws -> GameCenterActivityCompletion {
        try requireIdle(); try requireNoParty(); let handle = try runningHandle()
        handle.end(); let value = GameCenterActivityCompletion(activity: handle.snapshot)
        current = value.activity; currentHandle = nil
        completions.append(value); if completions.count > 64 { completions.removeFirst() }
        return value
    }
    /// Clears staged results before ending. It does not promise to restore challenge attempt quotas.
    /// For a challenge exit, submit the appropriate final attempt instead when required by your game's policy.
    public func discard() throws {
        try requireIdle(); try requireNoParty(); let handle = try runningHandle(); handle.clearResults(); handle.end()
        current = handle.snapshot; currentHandle = nil
    }

    /// Injects an initialized intent into the preview listener. Numeric codes such as 1234-5678 are supported.
    @discardableResult public func simulateIncomingActivity(definitionID: String, instanceID: String = UUID().uuidString,
                                                            properties: [String: String] = [:], partyCode: String? = nil) throws -> GameCenterActivityRequest? {
        guard usesPreview else { throw GameCenterServiceError.unavailable }
        let operation = try begin(); try validateGameCenterIdentifier(instanceID); try validateActivityProperties(properties)
        guard let definition = fixtures.first(where: { $0.id == definitionID }) else { throw GameCenterServiceError.notFound }
        if let partyCode { guard definition.supportsPartyCode, validPreviewPartyCode(partyCode) else { throw GameCenterServiceError.invalidValue } }
        let merged = definition.defaultProperties.merging(properties) { _, supplied in supplied }
        try validateActivityProperties(merged)
        let handle = PreviewActivityHandle(definition: definition, properties: merged, partyCode: partyCode, id: instanceID)
        guard receive(player: operation.player.id.rawValue, handle: handle) else { throw GameCenterServiceError.notFound }
        return requests.first { $0.activity.id == instanceID }
    }

    func reset() {
        partyLease = nil
        active = nil; cancellation?(); cancellation = nil
        stopListening(); currentHandle?.clearResults(); currentHandle = nil
        current = nil; catalog = []; completions = []; handled = [:]; owner = nil
    }
    func reserveParty(_ token: UUID) throws -> any GameCenterActivityHandle {
        try requireIdle(); try requireNoParty()
        let handle = try runningHandle()
        guard handle.snapshot.partyCode != nil else { throw GameCenterServiceError.invalidValue }
        partyLease = token; return handle
    }
    func releaseParty(_ token: UUID) { if partyLease == token { partyLease = nil } }
    private func requireNoParty() throws { guard partyLease == nil else { throw GameCenterServiceError.operationInProgress } }

    private func begin() throws -> GameCenterServiceContext.Operation {
        synchronizeIdentity()
        guard usesPreview || driver.isSupported else { throw GameCenterServiceError.unavailable }
        let operation = try context.begin(); owner = operation; return operation
    }
    private func synchronizeIdentity() {
        do {
            let value = try context.begin()
            if let owner, owner.player.id != value.player.id || owner.generation != value.generation { reset() }
            if let handle = currentHandle {
                let snapshot = handle.snapshot
                if current != snapshot { current = snapshot }
                if current?.state == .ended { currentHandle = nil }
            }
        }
        catch is CancellationError { } catch { reset() }
    }
    private func requireIdle() throws { guard active == nil else { throw GameCenterServiceError.operationInProgress } }
    private func requireNoRunningActivity() throws { guard currentHandle == nil else { throw GameCenterServiceError.operationInProgress } }
    private func runningHandle() throws -> any GameCenterActivityHandle {
        _ = try begin()
        guard let currentHandle, currentHandle.snapshot.state != .ended else { throw GameCenterServiceError.activityEnded }
        return currentHandle
    }
    private func validateCatalog(_ values: [GameCenterActivityDefinition]) throws {
        guard values.count <= 256, Set(values.map(\.id)).count == values.count else { throw GameCenterServiceError.invalidData }
        for value in values { try validateActivityDefinition(value) }
    }
    private func receive(player: String, handle: any GameCenterActivityHandle) -> Bool {
        guard isListening, let operation = try? begin(), operation.player.id.rawValue == player else { return false }
        let value = handle.snapshot
        guard routes.contains(value.definitionID), value.state != .ended,
              (try? validateGameCenterIdentifier(value.id)) != nil,
              (try? validateActivityProperties(value.properties)) != nil else { return false }
        if current?.id == value.id { return true }
        if let previous = handled[value.id] { return previous }
        guard requests.count < 16, handled.count < 256 else { return false }
        let id = UUID(); handles[id] = handle; requests.append(.init(id: id, activity: value)); handled[value.id] = true
        return true
    }
    private func perform<Value: Sendable>(_ work: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let operation = try begin(); try requireIdle()
        let token = UUID(); active = token
        let request = GameCenterProgressRequest<Value>(); cancellation = { request.cancel() }
        defer { if active == token { active = nil; cancellation = nil } }
        do {
            let value = try await request.run(work)
            try context.validate(operation)
            guard active == token else { throw GameCenterServiceError.cancelled }
            return value
        } catch { synchronizeIdentity(); throw gameCenterServiceFailure(error) }
    }
}

private func validPreviewPartyCode(_ value: String) -> Bool {
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    return parts.count == 2 && (2...6).contains(parts[0].count) && parts[0].count == parts[1].count &&
        parts.allSatisfy { $0.utf8.allSatisfy { (48...57).contains($0) } }
}

@MainActor private final class PreviewActivityHandle: GameCenterActivityHandle {
    private var value: GameCenterActivity
    var snapshot: GameCenterActivity { value }
    init(definition: GameCenterActivityDefinition, properties: [String: String], partyCode: String?, id: String = UUID().uuidString) {
        value = .init(id: id, definitionID: definition.id, properties: properties, partyCode: partyCode, partyURL: nil,
            state: .initialized, createdAt: Date(), scores: [:], achievementProgress: [:])
    }
    func activate() { phase(.active) }; func pause() { phase(.paused) }; func resume() { phase(.active) }; func end() { phase(.ended) }
    func setScore(_ score: GameCenterActivityScore, for identifier: String) async throws { replace(scores: value.scores.merging([identifier: score]) { _, new in new }) }
    func setProgress(_ progress: Double, for identifier: String) { replace(progress: value.achievementProgress.merging([identifier: progress]) { _, new in new }) }
    func clearResults() { replace(scores: [:], progress: [:]) }
    private func phase(_ phase: GameCenterActivityState) { replace(phase: phase) }
    private func replace(scores: [String: GameCenterActivityScore]? = nil, progress: [String: Double]? = nil, phase: GameCenterActivityState? = nil) {
        value = .init(id: value.id, definitionID: value.definitionID, properties: value.properties, partyCode: value.partyCode,
            partyURL: nil, state: phase ?? value.state, createdAt: value.createdAt, scores: scores ?? value.scores,
            achievementProgress: progress ?? value.achievementProgress)
    }
}
