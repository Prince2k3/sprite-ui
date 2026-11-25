import Dispatch
import Foundation
import Observation
import os

/// Bounded, opt-in recording. Samples retain values, never entities or packet contents.
public struct EngineProfileConfiguration: Codable, Equatable, Sendable {
    public let frameCapacity: Int
    public let targetFramesPerSecond: Double
    /// UI publication and workload-count cadence; frame timings are still recorded every frame.
    public let sampleInterval: TimeInterval
    public let emitsSignposts: Bool

    public init(frameCapacity: Int = 600, targetFramesPerSecond: Double = 60,
                sampleInterval: TimeInterval = 0.25, emitsSignposts: Bool = false) {
        self.frameCapacity = min(3_600, max(1, frameCapacity))
        self.targetFramesPerSecond = targetFramesPerSecond.isFinite ? min(1_000, max(1, targetFramesPerSecond)) : 60
        self.sampleInterval = sampleInterval.isFinite ? min(10, max(0.1, sampleInterval)) : 0.25
        self.emitsSignposts = emitsSignposts
    }
    private enum CodingKeys: String, CodingKey { case frameCapacity, targetFramesPerSecond, sampleInterval, emitsSignposts }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(frameCapacity: try values.decode(Int.self, forKey: .frameCapacity),
                  targetFramesPerSecond: try values.decode(Double.self, forKey: .targetFramesPerSecond),
                  sampleInterval: try values.decode(Double.self, forKey: .sampleInterval),
                  emitsSignposts: try values.decode(Bool.self, forKey: .emitsSignposts))
    }
}

/// Inclusive query work. Candidates count indexed entities, including inactive ones;
/// matches count returned entities. A predicate is evaluated only by the original query.
public struct EngineProfileQueries: Codable, Equatable, Sendable {
    public internal(set) var count = 0
    public internal(set) var candidateCount = 0
    public internal(set) var resultCount = 0
    public internal(set) var duration: TimeInterval = 0
    mutating func add(_ other: Self) {
        count = profileSum(count, other.count)
        candidateCount = profileSum(candidateCount, other.candidateCount)
        resultCount = profileSum(resultCount, other.resultCount)
        duration = fixedFiniteSum(duration, other.duration)
    }
}

/// Systems aggregate repeated fixed ticks by fully qualified type and phase.
/// Duration includes queries and nested networking; these costs are not additive.
public struct EngineProfileSystem: Codable, Equatable, Sendable {
    public let name: String
    public let phase: SystemPhase
    public internal(set) var invocationCount = 0
    public internal(set) var duration: TimeInterval = 0
    public internal(set) var queries = EngineProfileQueries()
    public internal(set) var collisionQueries = EngineProfileQueries()
}

/// Encoded envelope bytes accepted by the transport or processed from known peers.
/// Excludes transport overhead/retries and rejected enqueue/unknown-source arrivals.
/// No peer identity, gameplay values, or packet payloads are captured.
public struct EngineProfileNetwork: Codable, Equatable, Sendable {
    public internal(set) var updateCount = 0
    public internal(set) var duration: TimeInterval = 0
    public internal(set) var sentBytes: UInt64 = 0
    public internal(set) var receivedBytes: UInt64 = 0
    public internal(set) var sentPackets = 0
    public internal(set) var receivedPackets = 0
}

/// Periodic workload census, not a visibility or GPU-throughput measurement.
public struct EngineProfileWorkload: Codable, Equatable, Sendable {
    public let sampledAt: TimeInterval
    public let entityCount: Int
    public let activeEntityCount: Int
    public let nodeCount: Int?
    public let spriteNodeCount: Int?
    public let physicsBodyCount: Int?
    public let emitterCount: Int?
    /// Nil when the backend has no public exact counter. SpriteKit leaves both nil.
    public let drawCallCount: Int?
    public let particleCount: Int?

    @_spi(Backend) public init(sampledAt: TimeInterval, entityCount: Int, activeEntityCount: Int,
                              nodeCount: Int? = nil, spriteNodeCount: Int? = nil,
                              physicsBodyCount: Int? = nil, emitterCount: Int? = nil,
                              drawCallCount: Int? = nil, particleCount: Int? = nil) {
        self.sampledAt = sampledAt; self.entityCount = entityCount; self.activeEntityCount = activeEntityCount
        self.nodeCount = nodeCount; self.spriteNodeCount = spriteNodeCount
        self.physicsBodyCount = physicsBodyCount; self.emitterCount = emitterCount
        self.drawCallCount = drawCallCount; self.particleCount = particleCount
    }
}

/// One completed callback frame. Headless interval is caller-supplied, not display FPS.
/// Renderer durations measure main-actor callback elapsed time, not CPU self time.
public struct EngineProfileFrame: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let elapsedTime: TimeInterval
    public let interval: TimeInterval
    public let isSimulated: Bool
    public let isDebugStep: Bool
    public let worldUpdateDuration: TimeInterval
    public let rendererUpdateDuration: TimeInterval?
    public let rendererFinishDuration: TimeInterval?
    /// Time between update returning and didSimulatePhysics entering. Includes
    /// SpriteKit actions/physics and scheduling; it is not pure physics or GPU time.
    public let spriteKitInterval: TimeInterval?
    public let fixedSteps: Int
    public let droppedSimulationTime: TimeInterval
    public let queries: EngineProfileQueries
    public let collisionQueries: EngineProfileQueries
    public let systems: [EngineProfileSystem]
    /// At most 128 distinct system/phase entries per frame; totals still include all queries.
    public let systemTimingsTruncated: Bool
    public let network: EngineProfileNetwork
    public let workload: EngineProfileWorkload?
}

/// Statistics over retained frames, not over overwritten history. Interval zero
/// (such as the initial renderer callback) is excluded from cadence percentiles.
public struct EngineProfileSummary: Codable, Equatable, Sendable {
    public let frameCount: Int
    public let averageFrameInterval: TimeInterval
    public let p95FrameInterval: TimeInterval
    public let maximumFrameInterval: TimeInterval
    public let overBudgetFrameCount: Int
    public let droppedSimulationTime: TimeInterval

    static let empty = Self(frameCount: 0, averageFrameInterval: 0, p95FrameInterval: 0,
                            maximumFrameInterval: 0, overBudgetFrameCount: 0, droppedSimulationTime: 0)
    init(frames: [EngineProfileFrame], budget: TimeInterval) {
        let intervals = frames.map(\.interval).filter { $0 > 0 }.sorted()
        frameCount = frames.count
        averageFrameInterval = intervals.isEmpty ? 0 : intervals.reduce(0) { fixedFiniteSum($0, $1 / Double(intervals.count)) }
        p95FrameInterval = intervals.isEmpty ? 0 : intervals[max(0, Int(ceil(Double(intervals.count) * 0.95)) - 1)]
        maximumFrameInterval = intervals.last ?? 0
        overBudgetFrameCount = intervals.filter { $0 > budget + budget * 1e-6 }.count
        droppedSimulationTime = frames.reduce(0) { fixedFiniteSum($0, $1.droppedSimulationTime) }
    }
    private init(frameCount: Int, averageFrameInterval: Double, p95FrameInterval: Double,
                 maximumFrameInterval: Double, overBudgetFrameCount: Int, droppedSimulationTime: Double) {
        self.frameCount = frameCount; self.averageFrameInterval = averageFrameInterval
        self.p95FrameInterval = p95FrameInterval; self.maximumFrameInterval = maximumFrameInterval
        self.overBudgetFrameCount = overBudgetFrameCount; self.droppedSimulationTime = droppedSimulationTime
    }
}

/// Exportable rolling capture. Unknown backend counters are absent, never fabricated zeros.
public struct EngineProfileCapture: Codable, Sendable {
    public let formatVersion: Int
    public let startedAt: Date
    public let capturedAt: Date
    public let configuration: EngineProfileConfiguration
    public let totalFrameCount: UInt64
    public let overwrittenFrameCount: UInt64
    public let abandonedFrameCount: UInt64
    public let frames: [EngineProfileFrame]
    public let summary: EngineProfileSummary

    public func jsonData(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        return try encoder.encode(self)
    }
    public func write(to url: URL) throws { try jsonData().write(to: url, options: .atomic) }
}

/// A capture-session/frame identity. Backends must never apply stale measurements
/// after recording restarts or a native callback frame is abandoned.
@_spi(Backend) public struct EngineProfileToken: Equatable, Sendable {
    let recordingID: UUID
    let revision: UInt64
    let sequence: UInt64
}

@_spi(Backend) public struct EngineProfileQueryMeasurement: Sendable {
    let recordingID: UUID
    let revision: UInt64
    let start: UInt64
    let frame: EngineProfileToken?
}

@MainActor final class EngineProfileBuilder {
    let token: EngineProfileToken
    let isBackend: Bool
    let interval: Double
    var simulated = false
    var debugStep = false
    var worldDuration: Double = 0
    var rendererUpdate: Double?
    var rendererFinish: Double?
    var spriteKit: Double?
    var fixedSteps = 0
    var droppedTime: Double = 0
    var queries = EngineProfileQueries()
    var collisionQueries = EngineProfileQueries()
    var systems: [EngineProfileSystem] = []
    var currentSystem: Int?
    var truncated = false
    var signpost: OSSignpostIntervalState?
    init(token: EngineProfileToken, isBackend: Bool, interval: Double) {
        self.token = token; self.isBackend = isBackend; self.interval = interval
    }
}

@MainActor struct EngineSystemMeasurement {
    let token: EngineProfileToken
    let index: Int?
    let priorIndex: Int?
    let start: UInt64
    let signpost: OSSignpostIntervalState?
}

/// World-owned, opt-in profiling. Recording changes neither clocks nor scheduling.
/// Start explicitly, stop to freeze, and capture/export immutable values. The ring
/// retains the newest configured number of completed frames; UI publication is throttled.
@MainActor @Observable public final class EngineProfiler {
    public var isRecording: Bool { _ = publicationRevision; return recording }
    /// Changes on every start; hosts can clean up only the recording they own.
    public var recordingID: UUID? { _ = publicationRevision; return identity }
    public var latestFrame: EngineProfileFrame? { _ = publicationRevision; return publishedFrame }
    public var summary: EngineProfileSummary { _ = publicationRevision; return publishedSummary }
    public var configuration: EngineProfileConfiguration { _ = publicationRevision; return storedConfiguration }
    public var capturedFrameCount: Int { _ = latestFrame; return count }
    public var totalFrameCount: UInt64 { _ = latestFrame; return completedCount }

    @ObservationIgnored var clock: @MainActor () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    @ObservationIgnored var revision: UInt64 = 0
    @ObservationIgnored var active: EngineProfileBuilder?
    // Commit a consistent state before notifying. A synchronous observer may
    // reset/start recording; no old frame assignment may resume after it does so.
    private var publicationRevision: UInt64 = 0
    @ObservationIgnored private var isNotifying = false
    @ObservationIgnored private var recording = false
    @ObservationIgnored private var identity: UUID?
    @ObservationIgnored private var publishedFrame: EngineProfileFrame?
    @ObservationIgnored private var publishedSummary = EngineProfileSummary.empty
    @ObservationIgnored private var storedConfiguration = EngineProfileConfiguration()
    @ObservationIgnored private var ring: [EngineProfileFrame?] = []
    @ObservationIgnored private var next = 0
    @ObservationIgnored private var count = 0
    @ObservationIgnored private var completedCount: UInt64 = 0
    @ObservationIgnored private var issuedCount: UInt64 = 0
    @ObservationIgnored private var abandoned: UInt64 = 0
    @ObservationIgnored private var began = Date()
    @ObservationIgnored private var beganClock: UInt64 = 0
    @ObservationIgnored private var lastPublication: Double = -.infinity
    @ObservationIgnored private var workload: EngineProfileWorkload?
    @ObservationIgnored private var pendingQueries = EngineProfileQueries()
    @ObservationIgnored private var pendingCollisionQueries = EngineProfileQueries()
    @ObservationIgnored private var network = EngineProfileNetwork()
    private static let signposter = OSSignposter(subsystem: "dev.spriteui.engine", category: "Profiling")

    public init() {}
    /// Starts a new recording, discarding the previous ring. Default storage is 600 frames.
    public func start(configuration: EngineProfileConfiguration = .init()) {
        abandonActive()
        revision &+= 1
        storedConfiguration = configuration
        ring = Array(repeating: nil, count: configuration.frameCapacity)
        next = 0; count = 0; completedCount = 0; issuedCount = 0; abandoned = 0
        publishedFrame = nil; publishedSummary = .empty; workload = nil
        pendingQueries = .init(); pendingCollisionQueries = .init(); network = .init()
        began = Date(); beganClock = clock(); lastPublication = -.infinity
        identity = UUID(); recording = true
        notifyPublication()
    }
    /// Freezes completed frames. An incomplete frame is discarded and counted separately.
    public func stop() {
        guard isRecording else { return }
        abandonActive()
        recording = false; identity = nil; revision &+= 1
        pendingQueries = .init(); pendingCollisionQueries = .init(); network = .init()
        publish()
    }
    public func reset() {
        abandonActive(); recording = false; identity = nil; revision &+= 1
        ring = []; next = 0; count = 0; completedCount = 0; issuedCount = 0; abandoned = 0
        publishedFrame = nil; publishedSummary = .empty; workload = nil
        pendingQueries = .init(); pendingCollisionQueries = .init(); network = .init()
        notifyPublication()
    }
    public func capture() -> EngineProfileCapture {
        let frames = orderedFrames()
        return .init(formatVersion: 1, startedAt: began, capturedAt: Date(), configuration: configuration,
              totalFrameCount: completedCount, overwrittenFrameCount: completedCount - UInt64(count),
              abandonedFrameCount: abandoned, frames: frames,
              summary: .init(frames: frames, budget: 1 / configuration.targetFramesPerSecond))
    }

    var measurementRevision: UInt64? { isRecording ? revision : nil }
    func elapsed(since start: UInt64) -> Double {
        let end = clock()
        return end >= start ? Double(end - start) / 1_000_000_000 : 0
    }
    var elapsedTime: Double { elapsed(since: beganClock) }

    func beginWorldFrame(interval: Double, debugStep: Bool) -> EngineProfileToken? {
        guard isRecording else { return nil }
        let token = active?.isBackend == true ? active?.token : begin(interval: interval, backend: false)
        if let token, let frame = matching(token) { frame.simulated = true; frame.debugStep = debugStep }
        return token
    }
    func finishWorldFrame(_ token: EngineProfileToken?, duration: Double, ticks: Int, dropped: Double) {
        guard let token, let frame = matching(token) else { return }
        frame.worldDuration = fixedFiniteSum(frame.worldDuration, duration)
        frame.fixedSteps = ticks; frame.droppedTime = dropped
        if !frame.isBackend { complete(token) }
    }
    func recordWorldBegin(_ token: EngineProfileToken?, duration: Double, ticks: Int, dropped: Double) {
        guard let token, let frame = matching(token) else { return }
        frame.worldDuration = fixedFiniteSum(frame.worldDuration, duration)
        frame.fixedSteps = ticks; frame.droppedTime = dropped
    }
    func cancelWorldFrame(_ token: EngineProfileToken?) {
        guard let token, let frame = matching(token), !frame.isBackend else { return }
        abandonActive()
    }

    @_spi(Backend) public func beginRendererFrame(interval: Double) -> EngineProfileToken? { begin(interval: interval, backend: true) }
    @_spi(Backend) public func recordRendererUpdate(_ token: EngineProfileToken, duration: Double) { matching(token)?.rendererUpdate = duration }
    @_spi(Backend) public func recordSpriteKitInterval(_ token: EngineProfileToken, duration: Double) { matching(token)?.spriteKit = duration }
    @_spi(Backend) public func finishRendererFrame(_ token: EngineProfileToken, duration: Double) {
        guard let frame = matching(token) else { return }
        frame.rendererFinish = duration
        complete(token)
    }
    @_spi(Backend) public func cancelRendererFrame(_ token: EngineProfileToken) {
        guard matching(token)?.isBackend == true else { return }; abandonActive()
    }
    @_spi(Backend) public func elapsedRecordingTime() -> Double { elapsedTime }
    @_spi(Backend) public var needsWorkloadSample: Bool {
        isRecording && (workload == nil || elapsedTime - (workload?.sampledAt ?? 0) >= configuration.sampleInterval)
    }
    @_spi(Backend) public func recordWorkload(_ value: EngineProfileWorkload, token: EngineProfileToken) {
        guard matching(token) != nil else { return }; workload = value
    }
    @_spi(Backend) public func beginCollisionQuery() -> EngineProfileQueryMeasurement? {
        beginQueryMeasurement()
    }
    @_spi(Backend) public func endCollisionQuery(_ mark: EngineProfileQueryMeasurement?, candidates: Int, results: Int) {
        guard let mark, accepts(mark) else { return }
        let value = EngineProfileQueries(count: 1, candidateCount: candidates, resultCount: results, duration: elapsed(since: mark.start))
        if let frame = active, mark.frame != nil {
            frame.collisionQueries.add(value)
            if let index = frame.currentSystem { frame.systems[index].collisionQueries.add(value) }
        } else { pendingCollisionQueries.add(value) }
    }

    func beginSystem(name: String, phase: SystemPhase) -> EngineSystemMeasurement? {
        guard let frame = active, matching(frame.token) != nil else { return nil }
        let prior = frame.currentSystem
        let index: Int?
        if let existing = frame.systems.firstIndex(where: { $0.name == name && $0.phase == phase }) { index = existing }
        else if frame.systems.count < 128 {
            frame.systems.append(.init(name: String(name.prefix(512)), phase: phase)); index = frame.systems.count - 1
        } else { frame.truncated = true; index = nil }
        frame.currentSystem = index
        let state = configuration.emitsSignposts ? Self.signposter.beginInterval("System", id: Self.signposter.makeSignpostID(), "\(name, privacy: .public)") : nil
        return .init(token: frame.token, index: index, priorIndex: prior, start: clock(), signpost: state)
    }
    func endSystem(_ mark: EngineSystemMeasurement?) {
        guard let mark else { return }
        if let state = mark.signpost { Self.signposter.endInterval("System", state) }
        guard let frame = matching(mark.token) else { return }
        if let index = mark.index {
            frame.systems[index].invocationCount = profileSum(frame.systems[index].invocationCount, 1)
            frame.systems[index].duration = fixedFiniteSum(frame.systems[index].duration, elapsed(since: mark.start))
        }
        frame.currentSystem = mark.priorIndex
    }
    func beginQueryMeasurement() -> EngineProfileQueryMeasurement? {
        guard isRecording, let recordingID else { return nil }
        return .init(recordingID: recordingID, revision: revision, start: clock(), frame: active?.token)
    }
    private func accepts(_ mark: EngineProfileQueryMeasurement) -> Bool {
        isRecording && mark.recordingID == recordingID && mark.revision == revision
            && (mark.frame == nil || mark.frame == active?.token)
    }
    func recordQuery(_ mark: EngineProfileQueryMeasurement?, candidates: Int, results: Int) {
        guard let mark, accepts(mark) else { return }
        let value = EngineProfileQueries(count: 1, candidateCount: candidates, resultCount: results, duration: elapsed(since: mark.start))
        if let frame = active, mark.frame != nil {
            frame.queries.add(value)
            if let index = frame.currentSystem { frame.systems[index].queries.add(value) }
        } else { pendingQueries.add(value) }
    }
    func recordNetworkUpdate(revision: UInt64, start: UInt64) {
        guard isRecording, revision == self.revision else { return }
        network.updateCount = profileSum(network.updateCount, 1)
        network.duration = fixedFiniteSum(network.duration, elapsed(since: start))
    }
    func recordNetworkTraffic(sent: Int = 0, received: Int = 0, isSend: Bool) {
        guard isRecording else { return }
        if isSend {
            network.sentBytes = profileSum(network.sentBytes, UInt64(max(0, sent)))
            network.sentPackets = profileSum(network.sentPackets, 1)
        } else {
            network.receivedBytes = profileSum(network.receivedBytes, UInt64(max(0, received)))
            network.receivedPackets = profileSum(network.receivedPackets, 1)
        }
    }

    private func begin(interval: Double, backend: Bool) -> EngineProfileToken? {
        guard isRecording, let recordingID, interval.isFinite, interval >= 0 else { return nil }
        abandonActive()
        issuedCount = profileSum(issuedCount, 1)
        let token = EngineProfileToken(recordingID: recordingID, revision: revision, sequence: issuedCount)
        let frame = EngineProfileBuilder(token: token, isBackend: backend, interval: interval)
        frame.queries = pendingQueries; pendingQueries = .init()
        frame.collisionQueries = pendingCollisionQueries; pendingCollisionQueries = .init()
        if configuration.emitsSignposts { frame.signpost = Self.signposter.beginInterval("Engine frame", id: Self.signposter.makeSignpostID()) }
        active = frame
        return token
    }
    private func matching(_ token: EngineProfileToken) -> EngineProfileBuilder? {
        guard isRecording, token.revision == revision, active?.token == token else { return nil }; return active
    }
    private func complete(_ token: EngineProfileToken) {
        guard let frame = matching(token) else { return }
        if let state = frame.signpost { Self.signposter.endInterval("Engine frame", state) }
        let value = EngineProfileFrame(sequence: token.sequence, elapsedTime: elapsedTime, interval: frame.interval,
            isSimulated: frame.simulated, isDebugStep: frame.debugStep, worldUpdateDuration: frame.worldDuration,
            rendererUpdateDuration: frame.rendererUpdate, rendererFinishDuration: frame.rendererFinish, spriteKitInterval: frame.spriteKit,
            fixedSteps: frame.fixedSteps, droppedSimulationTime: frame.droppedTime, queries: frame.queries, collisionQueries: frame.collisionQueries,
            systems: frame.systems, systemTimingsTruncated: frame.truncated, network: network, workload: workload)
        network = .init(); active = nil
        ring[next] = value; next = (next + 1) % ring.count; count = min(count + 1, ring.count)
        completedCount = profileSum(completedCount, 1)
        if value.elapsedTime - lastPublication >= configuration.sampleInterval { publish() }
    }
    private func abandonActive() {
        if let frame = active {
            if let state = frame.signpost { Self.signposter.endInterval("Engine frame", state) }
            abandoned = profileSum(abandoned, 1)
            // Carry real network work forward, but do not fabricate a completed CPU frame.
        }
        active = nil
    }
    private func orderedFrames() -> [EngineProfileFrame] {
        guard count > 0 else { return [] }
        if count < ring.count { return ring.prefix(count).compactMap { $0 } }
        return (ring[next...] + ring[..<next]).compactMap { $0 }
    }
    private func publish() {
        let frames = orderedFrames()
        publishedFrame = frames.last
        publishedSummary = .init(frames: frames, budget: 1 / configuration.targetFramesPerSecond)
        lastPublication = elapsedTime
        notifyPublication()
    }
    private func notifyPublication() {
        // One notification covers synchronous changes made by its callbacks.
        // Recursively mutating the observed stamp can recurse before Observation
        // has retired its one-shot tracking callback.
        guard !isNotifying else { return }
        isNotifying = true
        defer { isNotifying = false }
        publicationRevision &+= 1
    }
}

private func profileSum<T: FixedWidthInteger>(_ a: T, _ b: T) -> T {
    let result = a.addingReportingOverflow(b); return result.overflow ? .max : result.partialValue
}
