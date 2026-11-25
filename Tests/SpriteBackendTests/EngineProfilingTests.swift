@_spi(Backend) import ECSCore
import Foundation
import SpriteKit
import Testing
@_spi(Backend) @testable import SpriteBackend

private struct ProfileRendererTrace: Component { var updates = 0 }
private struct ProfileRendererSystem: System {
    init(world: World) {}
    func update(context: UpdateContext) { context.world.resources[ProfileRendererTrace.self]?.updates += 1 }
}

@MainActor @Suite struct RendererEngineProfilingTests {
    private func fixture() -> (World, SpriteRenderer) {
        let world = World()
        world.resources.set(ProfileRendererTrace())
        let renderer = SpriteRenderer(world: world)
        world.addSystem(ProfileRendererSystem.self)
        return (world, renderer)
    }
    private func finish(_ renderer: SpriteRenderer) { renderer.didSimulatePhysics(); renderer.didFinishUpdate() }

    @Test func recordingIsOptInAndCompletesOnceAtTheEndOfTheNativeCallbackFrame() throws {
        let (world, renderer) = fixture()
        renderer.setDebugController(SceneDebugController(options: [.profiling]))
        renderer.update(0); finish(renderer)
        #expect(!world.profiler.isRecording && world.profiler.capture().frames.isEmpty)
        let count = world.resources[ProfileRendererTrace.self]?.updates
        world.profiler.start(configuration: .init(emitsSignposts: true))
        renderer.update(0.02)
        #expect(world.profiler.capture().frames.isEmpty)
        finish(renderer); renderer.didFinishUpdate()
        let frames = world.profiler.capture().frames
        let frame = try #require(frames.first)
        #expect(frames.count == 1 && frame.isSimulated)
        #expect(world.resources[ProfileRendererTrace.self]?.updates == (count ?? 0) + 1)
        #expect(frame.rendererUpdateDuration != nil && frame.rendererFinishDuration != nil && frame.spriteKitInterval != nil)
        #expect(frame.systems.filter { $0.name == String(reflecting: ProfileRendererSystem.self) }.count == 1)
        #expect(frame.interval == 0.02)
    }

    @Test func pausedRedrawRecordsAnEmptySimulationInsteadOfReusingPriorSystemTimings() throws {
        let (world, renderer) = fixture()
        world.profiler.start()
        renderer.update(0); finish(renderer)
        world.isPaused = true
        renderer.update(0.02); finish(renderer)
        let frame = try #require(world.profiler.capture().frames.last)
        #expect(world.profiler.capture().frames.count == 2)
        #expect(!frame.isSimulated && frame.systems.isEmpty && frame.worldUpdateDuration == 0)
        #expect(frame.fixedSteps == 0 && frame.spriteKitInterval == nil)
        #expect(world.resources[ProfileRendererTrace.self]?.updates == 1)
    }

    @Test func profilerUsesUncappedViewportIntervalsInsteadOfAnimationClockDeltas() throws {
        let (world, renderer) = fixture()
        renderer.update(0); finish(renderer)
        world.profiler.start()
        renderer.setNextFixedStepDeltaTime(0.5)
        renderer.update(1.0 / 15); finish(renderer)
        let frame = try #require(world.profiler.capture().frames.first)
        #expect(frame.interval == 0.5)
        #expect(world.profiler.capture().summary.maximumFrameInterval == 0.5)
    }

    @Test func workloadCensusIncludesNativeEffectsButExcludesDiagnosticDrawings() throws {
        let (world, renderer) = fixture()
        let body = Entity(components: SpriteComponent(color: .red, size: [20, 20]),
                          PhysicsBodyComponent(shape: .circle(radius: 10)))
        let inactive = Entity(components: SpriteComponent(color: .blue, size: [10, 10]))
        inactive.isEnabled = false
        let particles = Entity(components: ParticleEmitterComponent.smoke(color: .white))
        world.addEntity(body); world.addEntity(inactive); world.addEntity(particles)
        renderer.setDebugController(SceneDebugController(options: [.origins, .bounds]))
        world.profiler.start()
        renderer.update(0); finish(renderer)
        let sample = try #require(world.profiler.capture().frames.first?.workload)
        #expect(sample.entityCount == 3 && sample.activeEntityCount == 2)
        #expect(sample.spriteNodeCount == 2 && sample.physicsBodyCount == 1 && sample.emitterCount == 1)
        #expect(sample.drawCallCount == nil && sample.particleCount == nil)
        #expect(sample.nodeCount == 7)
        #expect(world.entities.count == 3 && world.root.children.count == 3)
    }

    @Test func unfinishedRendererFramesAreAbandonedAndStaleTokensCannotAppendAfterRestart() throws {
        let (world, renderer) = fixture()
        world.profiler.start()
        renderer.update(0)
        renderer.update(0.02); finish(renderer)
        #expect(world.profiler.capture().frames.map(\.sequence) == [2])
        #expect(world.profiler.capture().abandonedFrameCount == 1)
        renderer.update(0.04)
        world.profiler.stop(); world.profiler.start()
        finish(renderer)
        #expect(world.profiler.capture().frames.isEmpty)
        renderer.update(0.06); finish(renderer)
        #expect(world.profiler.capture().frames.count == 1)
    }

    @Test func debugPrimingIsNotReportedAsAnotherSimulatedFrame() throws {
        let (world, renderer) = fixture()
        let controller = SceneDebugController(options: [.profiling, .simulationControls])
        renderer.setDebugController(controller)
        world.isPaused = true
        renderer.update(0); finish(renderer)
        world.profiler.start()
        #expect(controller.stepFrame())
        renderer.update(0.02); finish(renderer)
        renderer.update(0.04); finish(renderer)
        let frames = world.profiler.capture().frames
        #expect(frames.map(\.isSimulated) == [false, true])
        #expect(frames.map(\.isDebugStep) == [false, true])
        #expect(world.isPaused && world.resources[ProfileRendererTrace.self]?.updates == 1)
    }

    @Test func raycastsOverlapsAndSweepsAreMeasuredWithoutChangingHits() throws {
        let world = World()
        let obstacle = Entity(components: CollisionComponent(shape: .circle(radius: 10)))
        world.addEntity(obstacle)
        let expected = world.raycast(from: [-30, 0], to: [30, 0]).map(\.entity.id)
        world.profiler.start()
        #expect(world.raycast(from: [-30, 0], to: [30, 0]).map(\.entity.id) == expected)
        #expect(world.overlaps(shape: .circle(radius: 5)).map(\.entity.id) == [obstacle.id])
        #expect(world.sweep(shape: .circle(radius: 2), from: .init(tx: -30, ty: 0), to: [30, 0]).map(\.entity.id) == expected)
        world.update(deltaTime: 0.02)
        let sample = try #require(world.profiler.capture().frames.first)
        #expect(sample.queries.count == 0)
        #expect(sample.collisionQueries.count == 3 && sample.collisionQueries.candidateCount == 3)
        #expect(sample.collisionQueries.resultCount == 3 && sample.collisionQueries.duration >= 0)
    }

    @Test func resettingTheRendererClockDropsOnlyItsIncompleteProfileFrame() {
        let (world, renderer) = fixture()
        world.profiler.start()
        renderer.update(0)
        renderer.resetFrameClock()
        finish(renderer)
        #expect(world.profiler.capture().frames.isEmpty && world.profiler.capture().abandonedFrameCount == 1)
        #expect(world.profiler.isRecording)
        renderer.update(1); finish(renderer)
        #expect(world.profiler.capture().frames.first?.interval == 0)
    }
}
