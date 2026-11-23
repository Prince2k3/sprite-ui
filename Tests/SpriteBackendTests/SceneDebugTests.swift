@_spi(Backend) import ECSCore
import Foundation
import SpriteKit
import Testing
@testable import SpriteBackend

private struct SceneDebugTrace: Component {
    var deltas: [TimeInterval] = []
    var phases: [SystemPhase] = []
}

private struct SceneDebugSimulation: System {
    init(world: World) {}
    func update(context: UpdateContext) {
        context.world.resources[SceneDebugTrace.self]?.deltas.append(context.deltaTime)
        context.world.resources[SceneDebugTrace.self]?.phases.append(context.phase)
    }
}

private struct SceneDebugPresentation: System {
    static var phase: SystemPhase { .presentation }
    init(world: World) {}
    func update(context: UpdateContext) {
        context.world.resources[SceneDebugTrace.self]?.deltas.append(context.deltaTime)
        context.world.resources[SceneDebugTrace.self]?.phases.append(context.phase)
    }
}

private final class SceneDebugReference: CustomStringConvertible {
    var next: SceneDebugReference?
    var description: String { Issue.record("Inspector expanded a reference graph"); return "expanded" }
}

private struct SceneDebugPayload: Component {
    var label: String
    var score = 42
    var image: SpriteImage
    var reference: SceneDebugReference
}

@MainActor private final class SceneDebugVoice: AudioVoice {
    var requests: [Bool] = []
    func synchronize(time: Double, playing: Bool, rate: Double, volume: Float, pan: Float, looping: Bool) throws {
        requests.append(playing)
    }
    func stop() { requests.append(false) }
}

@MainActor @Suite struct SceneDebugTests {
    private func countNodes(_ node: SKNode) -> Int {
        1 + node.children.reduce(0) { $0 + countNodes($1) }
    }

    private func row(_ controller: SceneDebugController, _ entity: Entity) throws -> SceneDebugEntity {
        try #require(controller.snapshot.entities.first { $0.id == entity.id })
    }

    private func finish(_ renderer: SpriteRenderer) {
        renderer.didSimulatePhysics(); renderer.didFinishUpdate()
    }

    @Test func diagnosticsAreOptInAndNilNeverCreatesHelpers() {
        let world = World(), renderer = SpriteRenderer(world: world)
        let entity = Entity(components: SpriteComponent(color: .red, size: [20, 20]), CollisionComponent(shape: .circle(radius: 10)))
        world.addEntity(entity)
        let nodes = countNodes(renderer)
        renderer.update(0); finish(renderer)
        renderer.update(0.02); finish(renderer)
        #expect(renderer.debugController == nil && renderer.debugLayer == nil)
        #expect(renderer.debugDrawNodes.isEmpty && !world.isProfilingEnabled)
        #expect(renderer.children.allSatisfy { $0.name != "__sceneDebug" })
        #expect(renderer.setDebugController(nil))
        #expect(countNodes(renderer) == nodes && world.entities.map(\.id) == [entity.id])
    }

    @Test(arguments: [false, true])
    func attachmentFirstWinsAndDetachRestoresProfiling(priorProfiling: Bool) {
        let world = World(), otherWorld = World()
        world.isProfilingEnabled = priorProfiling
        let renderer = SpriteRenderer(world: world), other = SpriteRenderer(world: otherWorld)
        let controller = SceneDebugController(options: [.statistics, .inspector])
        #expect(renderer.setDebugController(controller))
        #expect(renderer.setDebugController(controller))
        #expect(controller.isAttached && controller.scene === world && world.isProfilingEnabled)
        #expect(!other.setDebugController(controller))
        #expect(other.debugController == nil && !otherWorld.isProfilingEnabled)
        #expect(controller.scene === world)
        controller.options = [.inspector]
        #expect(world.isProfilingEnabled == priorProfiling)
        controller.options.insert(.statistics)
        #expect(world.isProfilingEnabled)
        #expect(renderer.setDebugController(nil))
        #expect(!controller.isAttached && controller.scene == nil && controller.snapshot.entities.isEmpty)
        #expect(world.isProfilingEnabled == priorProfiling && renderer.debugLayer == nil)
        #expect(other.setDebugController(controller))
        #expect(controller.scene === otherWorld)
        other.setDebugController(nil)
        #expect(!otherWorld.isProfilingEnabled)
    }

    @Test(arguments: [false, true])
    func droppingRendererClearsRetainedControllerAndRestoresWorld(priorProfiling: Bool) throws {
        let world = World(), controller = SceneDebugController(options: [.statistics, .inspector, .simulationControls])
        world.isProfilingEnabled = priorProfiling; world.isPaused = true
        let entity = Entity(name: "retained entity"); world.addEntity(entity)
        var renderer: SpriteRenderer? = SpriteRenderer(world: world)
        weak var weakRenderer = renderer
        #expect(renderer?.setDebugController(controller) == true && controller.select(entity))
        renderer?.update(0); renderer?.didSimulatePhysics(); renderer?.didFinishUpdate()
        #expect(controller.stepFrame()); renderer?.update(0.02); renderer?.didFinishUpdate()
        renderer?.update(0.04); controller.refresh()
        #expect(world.isDebugStepping && controller.isStepPending && world.isProfilingEnabled)
        #expect(controller.selectedEntityID == entity.id && controller.snapshot.entityCount == 1)
        renderer = nil
        #expect(weakRenderer == nil)
        #expect(!controller.isAttached && controller.scene == nil && !controller.isStepPending)
        #expect(controller.selectedEntityID == nil && controller.snapshot == .empty)
        #expect(world.isProfilingEnabled == priorProfiling && world.isPaused && !world.isDebugStepping)
        #expect(!controller.stepFrame() && world.entity(withID: entity.id) === entity)
        // The retained world can still start and finish a frame after cancellation.
        let frame = try #require(world.beginFrame(deltaTime: 0.02, debugStep: true))
        world.finishFrame(frame)
        #expect(!world.isDebugStepping)
    }

    @Test func countsIncludeInactiveAndPausedPlaybackButExcludeOverlay() throws {
        let world = World(), renderer = SpriteRenderer(world: world), parent = Entity(name: "parent")
        let child = Entity(components: SpriteComponent(color: .red, size: [10, 10]))
        let active = Entity(components: TextComponent("Active"))
        parent.addChild(child); world.addEntity(parent); world.addEntity(active)
        let playing = try child.playAnimation(.wait(10))
        let paused = try active.playAnimation(.wait(10), options: .init(startsPaused: true))
        parent.isEnabled = false
        let controller = SceneDebugController()
        renderer.setDebugController(controller); controller.refresh()
        #expect(controller.snapshot.entityCount == 3 && controller.snapshot.activeEntityCount == 1)
        #expect(controller.snapshot.activePlaybackCount == 2)
        #expect(controller.snapshot.nodeCount == countNodes(try #require(renderer.node(for: world.root))))
        #expect(countNodes(renderer) == controller.snapshot.nodeCount + controller.snapshot.overlayNodeCount + 1)
        #expect(!playing.isPlaying && paused.state == .paused)
        paused.stop(); controller.refresh()
        #expect(controller.snapshot.activePlaybackCount == 1)
        parent.isEnabled = true; controller.refresh()
        #expect(controller.snapshot.activeEntityCount == 3)
        #expect(try row(controller, world.root).childIDs == [parent.id, active.id])
    }

    @Test func collisionOutlineUsesDisplayedPoseOffsetAndRotatedNonuniformAncestors() throws {
        let world = World(), renderer = SpriteRenderer(world: world), parent = Entity()
        parent.position = [20, -10]; parent.rotation = 0.7; parent.scale = [2, 0.5]
        let child = Entity(components: CollisionComponent(shape: .rectangle(size: [8, 4]), offset: [3, -2]))
        child.position = [1, 2]; child.rotation = -0.3; child.scale = [0.6, 3]
        parent.addChild(child); world.addEntity(parent); renderer.flush()
        let node = try #require(renderer.node(for: child))
        node.position = CGPoint(x: 40, y: 30); node.zRotation = 0.4
        let controller = SceneDebugController(options: [.collisionShapes, .origins, .inspector])
        renderer.setDebugController(controller)
        let outline = try #require(renderer.debugDrawNodes["collision"]?.path)
        // Convert each local corner through SpriteKit independently of the drawing implementation.
        let corners = [CGPoint(x: -1, y: -4), CGPoint(x: 7, y: -4), CGPoint(x: 7, y: 0), CGPoint(x: -1, y: 0)]
        let points = corners.map { node.convert($0, to: renderer) }
        let expected = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        let actual = outline.boundingBoxOfPath
        #expect(abs(actual.minX - expected.minX) < 0.001 && abs(actual.maxX - expected.maxX) < 0.001)
        #expect(abs(actual.minY - expected.minY) < 0.001 && abs(actual.maxY - expected.maxY) < 0.001)
        let inspected = try row(controller, child), origin = node.convert(.zero, to: renderer)
        #expect(inspected.transform.translation == [1, 2])
        #expect(inspected.presentedTransform.translation == [40, 30])
        #expect(abs(inspected.scenePosition.x - Float(origin.x)) < 0.001)
        #expect(abs(inspected.scenePosition.y - Float(origin.y)) < 0.001)
    }

    @Test func rootMaskClipsInputButNotDebugGeometryOrPhysicsQueries() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        world.root.components.set(MaskComponent(shape: .rectangle(size: [10, 10])))
        let entity = Entity(components: CollisionComponent(shape: .rectangle(size: [40, 20])), InputTargetComponent())
        world.addEntity(entity); renderer.flush()
        let before = world.raycast(from: [-30, 0], to: [30, 0]).map(\.entity.id)
        let controller = SceneDebugController(options: [.collisionShapes, .origins, .inspector])
        renderer.setDebugController(controller)
        let layer = try #require(renderer.debugLayer)
        #expect(layer.parent === renderer && layer.parent !== renderer.node(for: world.root))
        #expect(try #require(renderer.debugDrawNodes["collision"]?.path).boundingBoxOfPath.width == 40)
        #expect(renderer.inputTarget(at: .zero) === entity)
        #expect(renderer.inputTarget(at: CGPoint(x: 15, y: 0)) == nil)
        #expect(renderer.entities(at: CGPoint(x: 15, y: 0)).isEmpty)
        #expect(controller.select(atScene: [15, 0]) == nil)
        #expect(world.raycast(from: [-30, 0], to: [30, 0]).map(\.entity.id) == before)
        #expect(before == [entity.id] && world.entities.count == 1)
        entity.removeFromParent(); controller.refresh()
        #expect(renderer.inputTarget(at: .zero) == nil && renderer.entities(at: .zero).isEmpty)
        #expect(world.raycast(from: [-30, 0], to: [30, 0]).isEmpty)
    }

    @Test func selectionRejectsForeignAndInvalidatesRemovalAndReusedLifetimes() throws {
        let world = World(), renderer = SpriteRenderer(world: world), foreignWorld = World()
        let entity = Entity(components: SpriteComponent(color: .red, size: [10, 10])), foreign = Entity()
        world.addEntity(entity); foreignWorld.addEntity(foreign)
        let controller = SceneDebugController(options: [.selection, .inspector])
        renderer.setDebugController(controller)
        #expect(controller.select(atScene: .zero) == entity.id) // No InputTargetComponent required.
        #expect(!controller.select(foreign) && controller.selectedEntityID == entity.id)
        #expect(controller.select(atScene: [.nan, 0]) == nil && controller.selectedEntityID == entity.id)
        #expect(controller.select(atScene: [1000, 1000]) == nil && controller.selectedEntityID == nil)
        #expect(controller.select(entity))
        entity.removeFromParent(); controller.refresh()
        #expect(controller.selectedEntityID == nil)
        world.addEntity(entity); #expect(controller.select(entity))
        entity.isEnabled = false; entity.isEnabled = true; controller.refresh()
        #expect(controller.selectedEntityID == nil)
        let parent = Entity(name: "disabled parent"); world.addEntity(parent); parent.addChild(entity)
        parent.isEnabled = false
        #expect(controller.select(entity) && controller.selectedEntityID == entity.id)
        let inspected = try row(controller, entity)
        #expect(inspected.isEnabled && !inspected.isActive && inspected.parentID == parent.id)
        #expect(inspected.diagnostics.contains("Disabled by an ancestor"))
        #expect(try row(controller, parent).childIDs == [entity.id])
        #expect(controller.select(nil) && controller.selectedEntityID == nil)
    }

    @Test func componentSummariesAreNamedBoundedAndDoNotExpandImagesOrReferenceGraphs() throws {
        let world = World(), renderer = SpriteRenderer(world: world), reference = SceneDebugReference()
        reference.next = reference
        defer { reference.next = nil }
        let image = SpriteImage(width: 64, height: 64, pixels: [UInt8](repeating: 217, count: 64 * 64 * 4))
        let entity = Entity(components: SpriteComponent(image: image),
            SceneDebugPayload(label: String(repeating: "long-label", count: 1000), image: image, reference: reference))
        world.addEntity(entity)
        let controller = SceneDebugController(options: [.inspector]); renderer.setDebugController(controller)
        let inspected = try row(controller, entity)
        #expect(inspected.components.map(\.name) == inspected.components.map(\.name).sorted())
        let payload = try #require(inspected.components.first { $0.name == String(reflecting: SceneDebugPayload.self) })
        #expect(payload.summary.contains("score: 42") && payload.summary.contains("label:"))
        #expect(payload.summary.count <= 320 && !payload.summary.contains("217"))
        #expect(!payload.summary.contains("pixels") && !payload.summary.contains("reference:"))
        let sprite = try #require(inspected.components.first { $0.name == String(reflecting: SpriteComponent.self) })
        #expect(sprite.summary.count <= 320 && !sprite.summary.contains("pixels") && !sprite.summary.contains("217"))
        entity.components[SceneDebugPayload.self]?.score = 99; controller.refresh()
        #expect(payload.summary.contains("42")) // Published rows are immutable value snapshots.
        #expect(try row(controller, entity).components.contains { $0.summary.contains("score: 99") })
    }

    @Test func inspectorCapsHierarchyAndIncludesSelectionBeyondLimit() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        for index in 0..<505 { world.addEntity(Entity(name: "row-\(index)")) }
        let last = try #require(world.entities.last)
        let controller = SceneDebugController(options: [.inspector]); renderer.setDebugController(controller)
        #expect(controller.snapshot.entityCount == 505 && controller.snapshot.inspectionTruncated)
        #expect(controller.snapshot.entities.count == 500 && controller.snapshot.entities.first?.id == world.root.id)
        #expect(!controller.snapshot.entities.contains { $0.id == last.id })
        #expect(controller.select(last))
        #expect(controller.snapshot.entities.count == 501 && controller.snapshot.entities.last?.id == last.id)
        controller.clearSelection(); #expect(controller.snapshot.entities.count == 500)
    }

    @Test func diagnosticsExplainMissingTargetsInvalidJointsAndInvalidCollision() throws {
        let world = World(), renderer = SpriteRenderer(world: world), missing = Entity()
        let owner = Entity(components:
            CollisionComponent(shape: .circle(radius: -1)),
            TransformConstraintComponent([TransformConstraint(.follow(.entity(missing.id)), name: "follow missing")]),
            PhysicsJointComponent(bodyA: missing.id, bodyB: Entity().id, constraint: .limit(maxLength: 0)))
        world.addEntity(owner); renderer.flush(); renderer.update(0); finish(renderer)
        let controller = SceneDebugController(options: [.inspector]); renderer.setDebugController(controller)
        let diagnostics = try row(controller, owner).diagnostics
        #expect(diagnostics.contains("Invalid collision shape"))
        #expect(diagnostics.contains { $0.contains("follow missing") && $0.contains("missingTarget") })
        #expect(diagnostics.contains { $0.contains("Joint:") && $0.contains("invalidConfiguration") })
        #expect(world.raycast(from: [-10, 0], to: [10, 0]).isEmpty)
    }

    @Test func drawingBatchesReuseNodesAndClearOnReconfiguration() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        var entities: [Entity] = []
        for index in 0..<100 {
            let entity = Entity(components: SpriteComponent(color: .red, size: [10, 10]), CollisionComponent(shape: .circle(radius: 5)))
            entity.position = [Float(index * 20), 0]; world.addEntity(entity)
            entities.append(entity)
        }
        entities[0].components.set(PhysicsBodyComponent(shape: .circle(radius: 5), isDynamic: false))
        entities[1].components.set(PhysicsBodyComponent(shape: .circle(radius: 5)))
        entities[2].components.set(TransformConstraintComponent([TransformConstraint(.lookAt(.entity(entities[0].id)))]))
        world.addEntity(Entity(components: PhysicsJointComponent(bodyA: entities[0].id, bodyB: entities[1].id, constraint: .fixed())))
        renderer.flush()
        let controller = SceneDebugController(); renderer.setDebugController(controller)
        #expect(controller.select(entities[0]))
        let layer = try #require(renderer.debugLayer), original = renderer.debugDrawNodes
        for _ in 0..<25 { controller.refresh() }
        #expect(renderer.debugLayer === layer && countNodes(layer) <= 8)
        #expect(Set(original.keys) == ["x", "y", "collision", "bounds", "joints", "constraints", "selection"])
        #expect(controller.snapshot.overlayNodeCount == countNodes(layer))
        for (key, node) in original { #expect(renderer.debugDrawNodes[key] === node) }
        controller.options = [.collisionShapes]
        #expect(Set(renderer.debugDrawNodes.keys) == ["collision"] && countNodes(layer) == 2)
        controller.options = [.statistics]
        #expect(renderer.debugLayer == nil && renderer.debugDrawNodes.isEmpty)
        #expect(controller.snapshot.overlayNodeCount == 0)
        controller.options = [.origins]; #expect(renderer.debugLayer != nil)
        controller.options = []; #expect(renderer.debugLayer == nil && renderer.debugDrawNodes.isEmpty)
        renderer.setDebugController(nil)
        #expect(renderer.childNode(withName: "__sceneDebug") == nil && world.entities.count == 101)
    }

    @Test(arguments: [0.0, 0.25, 4.0])
    func queuedPausedStepRunsOneFrameAtOneTimescaleAndRestoresNodes(scale: Double) throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        world.resources.set(SceneDebugTrace()); world.addSystem(SceneDebugSimulation.self); world.addSystem(SceneDebugPresentation.self)
        let entity = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 2)))
        world.addEntity(entity); world.isPaused = true; world.timeScale = scale
        let controller = SceneDebugController(options: [.statistics, .simulationControls]); renderer.setDebugController(controller)
        let root = try #require(renderer.node(for: world.root)), node = try #require(renderer.node(for: entity))
        renderer.update(0); finish(renderer)
        #expect(root.isPaused && renderer.physicsWorld.speed == 0)
        #expect(controller.stepFrame() && !controller.stepFrame() && controller.isStepPending)
        #expect(world.resources[SceneDebugTrace.self]?.deltas.isEmpty == true)
        renderer.update(0.02)
        #expect(renderer.debugStepPrimed && !world.isDebugStepping && !root.isPaused && root.speed == 0 && renderer.physicsWorld.speed == 0)
        finish(renderer)
        #expect(controller.isStepPending && world.resources[SceneDebugTrace.self]?.deltas.isEmpty == true)
        renderer.update(0.04)
        #expect(world.isPaused && world.isDebugStepping && renderer.steppingThisFrame)
        #expect(!root.isPaused && !node.isPaused && root.speed == 1 && renderer.physicsWorld.speed == 1)
        #expect(!controller.stepFrame())
        finish(renderer); controller.refresh()
        #expect(world.isPaused && world.timeScale == scale && !world.isDebugStepping)
        #expect(!renderer.steppingThisFrame && !controller.isStepPending && root.isPaused && renderer.physicsWorld.speed == 0)
        let trace = try #require(world.resources[SceneDebugTrace.self])
        #expect(trace.phases == [.simulation, .presentation])
        #expect(trace.deltas.count == 2 && trace.deltas.allSatisfy { abs($0 - 0.02) < 0.000001 })
        #expect(controller.snapshot.simulationFrameNumber == 1 && controller.snapshot.frameNumber == 3)
        let systemNames = world.systems.types.map { String(reflecting: $0) }
        let systemPhases = world.systems.types.map { $0.phase }
        #expect(controller.snapshot.systems.map(\.name) == systemNames)
        #expect(controller.snapshot.systems.map(\.phase) == systemPhases)
        #expect(controller.snapshot.systems.allSatisfy { $0.duration.isFinite && $0.duration >= 0 })
        let timings = controller.snapshot.systems
        renderer.update(0.06); finish(renderer); controller.refresh()
        #expect(world.resources[SceneDebugTrace.self]?.deltas == trace.deltas)
        #expect(controller.snapshot.simulationFrameNumber == 1 && controller.snapshot.frameNumber == 4)
        #expect(controller.snapshot.systems == timings && controller.snapshot.isPaused && controller.snapshot.timeScale == scale)
        #expect(controller.snapshot.entityCount == 1 && controller.snapshot.activeEntityCount == 1)
        #expect(controller.snapshot.overlayNodeCount == 0 && abs(controller.snapshot.framesPerSecond - 50) < 0.0001)
    }

    @Test func stepAdvancesExplicitAnimationAndMarkersOnceWhileAudioRemainsSuspended() throws {
        let world = World(), renderer = SpriteRenderer(world: world), entity = Entity()
        world.addEntity(entity); world.isPaused = true; world.timeScale = 0
        let resource = try AnimationResource.move(to: [100, 0], duration: 1).addingMarker("crossed", at: 0.01)
        let animation = try entity.playAnimation(resource)
        let voice = SceneDebugVoice()
        let audio = AudioPlaybackController(entity: entity, resource: AudioResource(name: "stub", duration: 10, data: Data()),
            options: .init(), volume: 1, isPositional: false, voice: voice)
        entity.addPlayback(audio); audio.synchronize()
        var markers: [String] = []
        let token = world.subscribe(to: PlaybackEvents.MarkerReached.self) { markers.append($0.marker.name) }
        let controller = SceneDebugController(options: [.statistics, .simulationControls]); renderer.setDebugController(controller)
        renderer.update(0); finish(renderer)
        #expect(controller.stepFrame()); renderer.update(0.02); finish(renderer)
        renderer.update(0.04); finish(renderer)
        #expect(abs(animation.currentTime - 0.02) < 0.000001 && abs(entity.position.x - 2) < 0.0001)
        #expect(markers == ["crossed"] && !animation.isPlaying && animation.state == .playing)
        #expect(audio.currentTime == 0 && audio.state == .playing && !audio.isPlaying)
        #expect(!voice.requests.isEmpty && voice.requests.allSatisfy { !$0 })
        renderer.update(0.06); finish(renderer); controller.refresh()
        #expect(abs(animation.currentTime - 0.02) < 0.000001 && markers == ["crossed"])
        #expect(controller.snapshot.activePlaybackCount == 2 && world.isPaused && !world.isDebugStepping)
        withExtendedLifetime(token) {}
    }

    @Test func steppedAnimationKeepsFinalFollowPoseThroughPausedRedraw() throws {
        let world = World(), renderer = SpriteRenderer(world: world), target = Entity(name: "follow target")
        target.position = [75, 30]
        let entity = Entity(components: SpriteComponent(color: .red, size: [10, 10]),
            TransformConstraintComponent([TransformConstraint(.follow(.entity(target.id)))]))
        world.addEntity(target); world.addEntity(entity)
        world.isPaused = true
        let animation = try entity.playAnimation(.move(to: [100, 0], duration: 1))
        let controller = SceneDebugController(options: [.inspector, .simulationControls])
        renderer.setDebugController(controller)
        let node = try #require(renderer.node(for: entity))
        renderer.update(0); finish(renderer)
        #expect(controller.stepFrame()); renderer.update(0.02); finish(renderer)
        renderer.update(0.04); finish(renderer); controller.refresh()
        #expect(entity.transformConstraintStatuses == [.active])
        #expect(entity.position == target.position && node.position == CGPoint(x: 75, y: 30))
        #expect(abs(animation.currentTime - 0.02) < 0.000001 && !animation.isPlaying)
        renderer.update(0.06); finish(renderer); controller.refresh()
        let inspected = try row(controller, entity)
        #expect(entity.position == target.position && node.position == CGPoint(x: 75, y: 30))
        #expect(inspected.transform.translation == target.position && inspected.presentedTransform.translation == target.position)
        #expect(abs(animation.currentTime - 0.02) < 0.000001)
        #expect(world.isPaused && !world.isDebugStepping && controller.snapshot.simulationFrameNumber == 1)
    }

    @Test func invalidStepRequestsCoalesceAndDetachingCancelsQueuedWork() {
        let controller = SceneDebugController(options: [.simulationControls])
        #expect(!controller.stepFrame() && !controller.canStep)
        let world = World(), renderer = SpriteRenderer(world: world)
        renderer.setDebugController(controller)
        #expect(!controller.stepFrame())
        world.isPaused = true; world.root.isEnabled = false
        #expect(!controller.stepFrame() && !controller.isStepPending)
        world.root.isEnabled = true; renderer.update(0); finish(renderer)
        #expect(controller.stepFrame() && !controller.stepFrame())
        renderer.update(0); finish(renderer) // A zero interval cannot consume a step.
        #expect(controller.isStepPending && controller.snapshot.simulationFrameNumber == 0)
        renderer.setDebugController(nil)
        #expect(!controller.isStepPending && !controller.canStep && !renderer.pendingDebugStep)
        renderer.update(0.02); finish(renderer)
        #expect(world.isPaused && !world.isDebugStepping && !renderer.steppingThisFrame)
        renderer.setDebugController(controller)
        #expect(controller.stepFrame()); controller.isPaused = false
        #expect(!controller.isStepPending && !renderer.pendingDebugStep)
        world.isPaused = true; renderer.update(0.04); finish(renderer); controller.refresh()
        #expect(controller.snapshot.simulationFrameNumber == 0)
    }

    @Test func detachingDuringClockPrimingRestoresNativePause() throws {
        let world = World(), renderer = SpriteRenderer(world: world), debug = SceneDebugController()
        renderer.setDebugController(debug); world.isPaused = true
        renderer.update(0); finish(renderer)
        #expect(debug.stepFrame()); renderer.update(0.02); finish(renderer)
        let root = try #require(renderer.node(for: world.root))
        #expect(renderer.debugStepPrimed && !root.isPaused && root.speed == 0)
        renderer.setDebugController(nil)
        #expect(!renderer.debugStepPrimed && !renderer.pendingDebugStep && root.isPaused)
        #expect(world.isPaused && !world.isDebugStepping && renderer.physicsWorld.speed == 0)
    }

    @Test func inspectionCanPickVisualChildrenWithoutChangingGameplayOwnership() {
        let world = World(), renderer = SpriteRenderer(world: world)
        let room = Entity(components: PhysicsBodyComponent(shape: .edgeLoop(rectangle: [200, 200])))
        let child = Entity(components: SpriteComponent(color: .red, size: [20, 20]))
        room.addChild(child); world.addEntity(room)
        let debug = SceneDebugController(); renderer.setDebugController(debug)
        #expect(renderer.entities(at: .zero).isEmpty)
        #expect(debug.select(atScene: .zero) == child.id)
        child.components.set(CollisionComponent(shape: .circle(radius: 1), isEnabled: false))
        renderer.flush()
        #expect(renderer.entities(at: CGPoint(x: 8, y: 0)).isEmpty)
        #expect(debug.select(atScene: [8, 0]) == child.id)
        room.components.set(MaskComponent(shape: .circle(radius: 5))); renderer.flush()
        #expect(debug.select(atScene: [8, 0]) == nil)
        #expect(debug.select(atScene: .zero) == child.id)
    }
}
