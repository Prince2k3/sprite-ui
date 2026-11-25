import Foundation
import Observation
import Testing
@_spi(Backend) @testable import ECSCore

@MainActor private final class ProfileClock {
    var now: UInt64 = 0
    func advance(_ nanoseconds: UInt64 = 1_000_000) { now += nanoseconds }
}
private struct ProfileMarker: Component {}
@MainActor private final class ProfileTrace: Component {
    let clock = ProfileClock()
    var phases: [SystemPhase] = []
    var predicateCalls = 0
    var action: (@MainActor (World) -> Void)?
}
@MainActor private func profileWork(_ context: UpdateContext) {
    guard let trace = context.world.resources[ProfileTrace.self] else { return }
    trace.phases.append(context.phase)
    trace.clock.advance()
    _ = context.entities(matching: EntityQuery(where: QueryPredicate { entity in
        trace.predicateCalls += 1
        trace.clock.advance()
        return entity.components.has(ProfileMarker.self)
    }))
    trace.action?(context.world)
}
private struct ProfileSimulation: System {
    init(world: World) {}
    func update(context: UpdateContext) { profileWork(context) }
}
private struct ProfileFixed: System {
    static var phase: SystemPhase { .fixedSimulation }
    init(world: World) {}
    func update(context: UpdateContext) { profileWork(context) }
}
private struct ProfilePresentation: System {
    static var phase: SystemPhase { .presentation }
    init(world: World) {}
    func update(context: UpdateContext) { profileWork(context) }
}

@MainActor @Suite struct EngineProfilerTests {
    private func fixture() -> (World, ProfileTrace) {
        let world = World(), trace = ProfileTrace()
        world.resources.set(trace)
        world.profiler.clock = { trace.clock.now }
        world.addEntity(Entity(name: "match", components: ProfileMarker()))
        world.addEntity(Entity(name: "other"))
        let inactive = Entity(name: "inactive", components: ProfileMarker())
        inactive.isEnabled = false; world.addEntity(inactive)
        world.addSystem(ProfileSimulation.self)
        world.addSystem(ProfilePresentation.self)
        return (world, trace)
    }

    @Test func disabledProfilingDoesNotReadTheClockOrReplayQueries() {
        let (world, trace) = fixture()
        world.profiler.clock = { Issue.record("Disabled profiling read its clock"); return 0 }
        world.update(deltaTime: 0.02)
        #expect(!world.profiler.isRecording && world.profiler.capture().frames.isEmpty)
        #expect(trace.phases == [.simulation, .presentation] && trace.predicateCalls == 4)
        #expect(world.lastSystemTimings.isEmpty)
    }

    @Test func recordsActualSystemsAndAttributesEachSingleQueryWithoutChangingResults() throws {
        let (world, trace) = fixture()
        world.profiler.start()
        world.update(deltaTime: 0.02)
        let frame = try #require(world.profiler.capture().frames.first)
        #expect(frame.systems.map(\.phase) == [.simulation, .presentation])
        #expect(frame.systems.map(\.invocationCount) == [1, 1])
        #expect(frame.systems.allSatisfy { abs($0.duration - 0.003) < 1e-9 && $0.queries.count == 1 })
        #expect(frame.queries.count == 2 && frame.queries.candidateCount == 6 && frame.queries.resultCount == 2)
        #expect(abs(frame.queries.duration - 0.004) < 1e-9)
        #expect(trace.predicateCalls == 4)
        #expect(frame.workload?.entityCount == 3 && frame.workload?.activeEntityCount == 2)
        #expect(frame.workload?.nodeCount == nil && frame.rendererUpdateDuration == nil)
        #expect(frame.worldUpdateDuration >= frame.systems.reduce(0) { $0 + $1.duration })
        #expect(world.lastSystemTimings.isEmpty) // Independent of the older timing switch.
    }

    @Test func fixedCatchUpAggregatesInvocationsAndPreservesDroppedTimeAfterClockReset() throws {
        let (world, trace) = fixture()
        world.addSystem(ProfileFixed.self)
        world.fixedStep = .init(stepsPerSecond: 10, maximumCatchUpSteps: 2, maximumFrameDeltaTime: 1)
        world.profiler.start()
        trace.action = { world in if !world.isFixedUpdating { world.resetFixedStepClock() } }
        world.update(deltaTime: 0.55)
        let frame = try #require(world.profiler.capture().frames.first)
        #expect(frame.fixedSteps == 2)
        #expect(abs(frame.droppedSimulationTime - 0.3) < 1e-9)
        #expect(frame.systems.first?.phase == .fixedSimulation && frame.systems.first?.invocationCount == 2)
        #expect(frame.queries.count == 4 && trace.phases.count == 4)
    }

    @Test func ringRetainsNewestFramesInOrderAndSummaryUsesRetainedIntervals() {
        let (world, _) = fixture()
        world.profiler.start(configuration: .init(frameCapacity: 3, targetFramesPerSecond: 60))
        for delta in [0.0, 0.01, 0.02, 0.03, 0.04] { world.update(deltaTime: delta) }
        world.profiler.stop()
        let capture = world.profiler.capture()
        #expect(capture.frames.map(\.sequence) == [3, 4, 5])
        #expect(capture.totalFrameCount == 5 && capture.overwrittenFrameCount == 2)
        #expect(capture.summary.frameCount == 3 && capture.summary.overBudgetFrameCount == 3)
        #expect(abs(capture.summary.averageFrameInterval - 0.03) < 1e-9)
        #expect(capture.summary.p95FrameInterval == 0.04 && capture.summary.maximumFrameInterval == 0.04)
        #expect(world.profiler.latestFrame?.sequence == 5)
        world.update(deltaTime: 1)
        #expect(world.profiler.capture().frames == capture.frames)
        world.profiler.reset()
        #expect(world.profiler.capture().frames.isEmpty && world.profiler.totalFrameCount == 0)
    }

    @Test func stopAndRestartDuringAFrameRejectsItsOldMeasurements() {
        let (world, trace) = fixture()
        world.profiler.start()
        trace.action = { world in world.profiler.stop(); world.profiler.start() }
        world.update(deltaTime: 0.02)
        #expect(world.profiler.capture().frames.isEmpty)
        trace.action = nil
        world.update(deltaTime: 0.02)
        #expect(world.profiler.capture().frames.count == 1)
        #expect(world.profiler.capture().frames.first?.systems.count == 2)
    }

    @Test func enablingBetweenPhasesDoesNotPublishAPartialFrame() throws {
        let (world, _) = fixture()
        let frame = try #require(world.beginFrame(deltaTime: 0.02))
        world.profiler.start()
        world.finishFrame(frame)
        #expect(world.profiler.capture().frames.isEmpty)
        world.update(deltaTime: 0.02)
        #expect(world.profiler.capture().frames.count == 1)
    }

    @Test func cancelledFramesAreNotReportedAsCompleted() throws {
        let (world, _) = fixture()
        world.profiler.start()
        let frame = try #require(world.beginFrame(deltaTime: 0.02))
        world.cancelFrame(frame)
        world.finishFrame(frame)
        #expect(world.profiler.capture().frames.isEmpty && world.profiler.capture().abandonedFrameCount == 1)
        world.update(deltaTime: 0.02)
        #expect(world.profiler.capture().frames.map(\.sequence) == [2])
    }

    @Test func aQueryCancelledByItsPredicateCannotLeakIntoTheNextFrame() throws {
        let world = World()
        world.addEntity(Entity())
        world.profiler.start()
        let frame = try #require(world.beginFrame(deltaTime: 0.02))
        _ = world.performQuery(.init(where: .init { _ in world.cancelFrame(frame); return true }))
        world.update(deltaTime: 0.02)
        #expect(world.profiler.capture().frames.count == 1)
        #expect(world.profiler.capture().frames.first?.queries.count == 0)
    }

    @Test func synchronousObservationResetCannotRestoreAnOldPublication() {
        let (world, _) = fixture()
        world.profiler.start()
        withObservationTracking {
            _ = world.profiler.latestFrame
        } onChange: {
            MainActor.assumeIsolated { world.profiler.reset() }
        }
        world.update(deltaTime: 0.02)
        #expect(!world.profiler.isRecording && world.profiler.capture().frames.isEmpty)
        #expect(world.profiler.latestFrame == nil && world.profiler.summary.frameCount == 0)
    }

    @Test func disabledAndRemovedSystemsDoNotProduceSamples() throws {
        let (world, _) = fixture()
        world.systems.setEnabled(false, for: ProfilePresentation.self)
        world.profiler.start()
        world.update(deltaTime: 0.02)
        #expect(world.profiler.capture().frames.first?.systems.map(\.phase) == [.simulation])
        world.systems.remove(ProfileSimulation.self)
        world.update(deltaTime: 0.02)
        #expect(world.profiler.capture().frames.last?.systems.isEmpty == true)
        #expect(world.profiler.capture().frames.last?.queries.count == 0)
    }

    @Test func pausedFixedStepIsOneTickAndDoesNotUnpause() throws {
        let (world, _) = fixture()
        world.addSystem(ProfileFixed.self)
        world.fixedStep = .init()
        world.isPaused = true
        world.profiler.start()
        #expect(world.stepFixedSimulation())
        let frame = try #require(world.profiler.capture().frames.first)
        #expect(frame.fixedSteps == 1 && frame.systems.map(\.phase) == [.fixedSimulation])
        #expect(world.isPaused && frame.isDebugStep)
    }

    @Test func publicConfigurationDecodingRetainsMemoryBounds() throws {
        let data = Data(#"{"frameCapacity":9999999,"targetFramesPerSecond":0,"sampleInterval":0,"emitsSignposts":false}"#.utf8)
        let value = try JSONDecoder().decode(EngineProfileConfiguration.self, from: data)
        #expect(value.frameCapacity == 3_600 && value.targetFramesPerSecond == 1 && value.sampleInterval == 0.1)
        #expect(EngineProfileConfiguration(frameCapacity: -1).frameCapacity == 1)
    }

    @Test func jsonExportHasVersionSummaryAndNoWorldValuesAndWritesAtomically() throws {
        let (world, _) = fixture()
        world.entities.first?.name = "private-player-name"
        world.profiler.start()
        world.update(deltaTime: 0.02)
        let capture = world.profiler.capture()
        let data = try capture.jsonData()
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("formatVersion") && text.contains("summary"))
        #expect(!text.contains("private-player-name") && !text.contains("predicateCalls"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(EngineProfileCapture.self, from: data).frames == capture.frames)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try capture.write(to: url)
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func publicationIsThrottledButStopPublishesTheLatestCompletedFrame() {
        let (world, trace) = fixture()
        world.profiler.start(configuration: .init(sampleInterval: 0.25))
        world.update(deltaTime: 0.02)
        #expect(world.profiler.latestFrame?.sequence == 1)
        world.update(deltaTime: 0.02)
        #expect(world.profiler.capture().frames.count == 2 && world.profiler.latestFrame?.sequence == 1)
        trace.clock.advance(300_000_000)
        world.update(deltaTime: 0.02)
        #expect(world.profiler.latestFrame?.sequence == 3)
        world.update(deltaTime: 0.02)
        world.profiler.stop()
        #expect(world.profiler.latestFrame?.sequence == 4)
    }

    @Test func queriesAndTrafficOutsideAFrameAreCountedInTheNextCompletedFrame() throws {
        let world = World()
        world.addEntity(Entity())
        world.profiler.start()
        _ = world.performQuery(.init())
        world.profiler.recordNetworkTraffic(sent: 10, isSend: true)
        world.profiler.recordNetworkTraffic(received: 20, isSend: false)
        world.update(deltaTime: 0.02)
        let frame = try #require(world.profiler.capture().frames.first)
        #expect(frame.queries.count == 1 && frame.queries.resultCount == 1)
        #expect(frame.network.sentBytes == 10 && frame.network.receivedBytes == 20)
        world.update(deltaTime: 0.02)
        #expect(world.profiler.capture().frames.last?.network.sentBytes == 0)
        #expect(world.profiler.capture().frames.last?.queries.count == 0)
    }

    @Test func backendTokensCannotCrossWorldsAndRecordingIdentityChangesOnRestart() throws {
        let a = World(), b = World()
        a.profiler.start(); b.profiler.start()
        let firstID = a.profiler.recordingID
        let tokenA = try #require(a.profiler.beginRendererFrame(interval: 0.01))
        let tokenB = try #require(b.profiler.beginRendererFrame(interval: 0.01))
        b.profiler.finishRendererFrame(tokenA, duration: 1)
        #expect(b.profiler.capture().frames.isEmpty)
        b.profiler.endCollisionQuery(a.profiler.beginCollisionQuery(), candidates: 99, results: 99)
        b.profiler.finishRendererFrame(tokenB, duration: 0.001)
        #expect(b.profiler.capture().frames.first?.collisionQueries.count == 0)
        a.profiler.stop(); a.profiler.start()
        #expect(a.profiler.recordingID != firstID)
        a.profiler.finishRendererFrame(tokenA, duration: 1)
        #expect(a.profiler.capture().frames.isEmpty)
    }

    @Test func inMemoryReplicationRunsOnceAndRecordsActualEnvelopeTraffic() throws {
        let hub = InMemoryNetwork()
        let a = NetworkPeer(id: .init(rawValue: "profile-host"), displayName: "private-host")
        let b = NetworkPeer(id: .init(rawValue: "profile-client"), displayName: "private-client")
        let hostTransport = try hub.connect(a), clientTransport = try hub.connect(b)
        let hostWorld = World(), clientWorld = World()
        let host = NetworkSession(world: hostWorld, transport: hostTransport, role: .host, schema: .init())
        let client = NetworkSession(world: clientWorld, transport: clientTransport, role: .client(host: a.id), schema: .init())
        defer { host.stop(); client.stop() }
        hostWorld.profiler.start(); clientWorld.profiler.start()
        try host.start(); try client.start()
        for _ in 0..<6 { hub.advance(by: 0.05); hostWorld.update(deltaTime: 0.05); clientWorld.update(deltaTime: 0.05) }
        let frames = hostWorld.profiler.capture().frames
        #expect(frames.allSatisfy { $0.network.updateCount == 1 })
        #expect(frames.reduce(0) { $0 + $1.network.sentBytes } > 0)
        #expect(frames.reduce(0) { $0 + $1.network.receivedBytes } > 0)
        #expect(frames.reduce(0) { $0 + $1.network.sentPackets } > 0)
        let text = String(decoding: try hostWorld.profiler.capture().jsonData(), as: UTF8.self)
        #expect(!text.contains("private-host") && !text.contains("profile-client"))
    }
}
