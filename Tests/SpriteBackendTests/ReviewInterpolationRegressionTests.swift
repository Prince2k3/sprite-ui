@_spi(Backend) import ECSCore
import Foundation
import Metal
@_spi(Backend) @testable import SpriteBackend
import SpriteKit
import Testing

private struct ReviewInterpolationMotion: Component {
    var translation: SIMD2<Float> = [20, 0]
    var rotation: Float = 0
    var scale: SIMD2<Float> = .zero
}

@MainActor private struct ReviewInterpolationMover: System {
    static var phase: SystemPhase { .fixedSimulation }
    init(world: World) {}
    func update(context: UpdateContext) {
        for entity in context.world.allEntities where entity.isActive {
            guard let motion = entity.components[ReviewInterpolationMotion.self] else { continue }
            var pose = entity.transform
            pose.translation += motion.translation
            pose.rotation += motion.rotation
            pose.scale += motion.scale
            entity.transform = pose
        }
    }
}

@MainActor @Suite struct ReviewInterpolationRegressionTests {
    @MainActor private struct Fixture {
        let world: World
        let renderer: SpriteRenderer
        let entity: Entity
        var node: SKNode { renderer.node(for: entity)! }

        init(motion: ReviewInterpolationMotion = .init()) {
            world = World()
            world.fixedStep = .init(stepsPerSecond: 8)
            world.addSystem(ReviewInterpolationMover.self)
            entity = Entity(components: motion, TransformInterpolationComponent(),
                            SpriteComponent(color: .red, size: [4, 4]))
            world.addEntity(entity)
            renderer = SpriteRenderer(world: world, size: CGSize(width: 200, height: 100))
            frame(0)
        }

        func frame(_ time: TimeInterval) {
            renderer.update(time)
            renderer.didSimulatePhysics()
            renderer.didFinishUpdate()
        }
    }

    @Test(arguments: [false, true])
    func manipulationCapturesDisplayedPoseAndDiscardsOldHistory(programmatic: Bool) throws {
        let f = Fixture()
        f.entity.components.set(InputTargetComponent())
        f.entity.components.set(ManipulationComponent())
        f.frame(0.1875)
        #expect(f.entity.position == [20, 0])
        #expect(f.entity.presentation.position == [10, 0])
        #expect(f.renderer.inputTarget(at: CGPoint(x: 10, y: 0)) === f.entity)

        let session = try #require(programmatic
            ? f.renderer.beginManipulation(of: f.entity, at: [10, 0])
            : f.renderer.beginManipulation(at: [10, 0]))
        defer { session.cancel() }
        #expect(session.initialTransform.translation == [10, 0])
        #expect(f.entity.position == [10, 0])
        #expect(f.world.fixedTransformSample(for: f.entity) == nil)
        #expect(session.update(translation: [3, 0]))
        #expect(f.entity.position == [13, 0])
        // A quiet display frame must not resurrect the pre-capture pair.
        f.frame(0.1875)
        #expect(session.isActive)
        #expect(f.entity.presentation.position == [13, 0])
    }

    @Test func childCaptureKeepsIndependentParentInterpolation() throws {
        let f = Fixture()
        let child = Entity(components: InputTargetComponent(), ManipulationComponent(),
                           SpriteComponent(color: .blue, size: [4, 4]))
        f.entity.addChild(child)
        let childNode = try #require(f.renderer.node(for: child))
        f.frame(0.1875)
        #expect(childNode.convert(.zero, to: f.renderer).x == 10)
        var beganWorldX: CGFloat?
        let token = f.world.subscribe(to: ManipulationEvents.Began.self) { _ in
            beganWorldX = childNode.convert(.zero, to: f.renderer).x
        }
        defer { token.cancel() }

        let session = try #require(f.renderer.beginManipulation(of: child, at: [10, 0]))
        defer { session.cancel() }
        #expect(beganWorldX == 10)
        #expect(f.node.position.x == 10)
        #expect(session.initialTransform.translation == .zero)
        #expect(session.update())
        #expect(child.position == .zero)
        #expect(childNode.convert(.zero, to: f.renderer).x == 10)
        f.frame(0.1875)
        #expect(session.isActive)
        #expect(f.node.position.x == 10)

        // A fresh fixed tick still owns the parent's independent local motion.
        // Reproject the same scene-space pointer against its new displayed pose.
        f.frame(0.3125)
        #expect(f.entity.position == [40, 0])
        #expect(f.node.position.x == 30)
        #expect(session.update())
        #expect(child.position == [-20, 0])
        #expect(childNode.convert(.zero, to: f.renderer).x == 10)
    }

    @Test func followConstraintUsesFullDisplayedTargetTransform() throws {
        let f = Fixture(motion: .init(rotation: .pi / 2, scale: [2, 2]))
        let offset: SIMD2<Float> = [2, 3]
        let follower = Entity(components: TransformConstraintComponent([
            TransformConstraint(.follow(.entity(f.entity.id), offset: offset))
        ]))
        f.world.addEntity(follower)
        f.frame(0.1875)
        #expect(f.entity.position == [20, 0])
        #expect(f.entity.presentation.position == [10, 0])
        #expect(follower.transformConstraintStatuses == [.active])
        // Target offsets must include displayed rotation and scale, not just position.
        let expected = f.node.convert(CGPoint(x: CGFloat(offset.x), y: CGFloat(offset.y)), to: f.renderer)
        let followerNode = try #require(f.renderer.node(for: follower))
        let actual = followerNode.convert(.zero, to: f.renderer)
        #expect(abs(actual.x - expected.x) < 0.0001)
        #expect(abs(actual.y - expected.y) < 0.0001)
    }

    @Test(arguments: [false, true])
    func nativeConstraintOnArtworkKeepsAncestorOutOfInterpolation(isEnabled: Bool) throws {
        let f = Fixture()
        let artwork = SKNode(), anchor = SKNode()
        f.renderer.addChild(anchor)
        f.node.addChild(artwork)
        let constraint = SKConstraint.distance(SKRange(constantValue: 0), to: anchor)
        constraint.enabled = isEnabled
        artwork.constraints = [constraint]

        // Use SpriteKit's actual constraint evaluation, rather than assigning the
        // pose the constraint is expected to produce by hand.
        let device = try #require(MTLCreateSystemDefaultDevice())
        let native = SKRenderer(device: device)
        native.scene = f.renderer
        f.renderer.resetFrameClock()
        f.renderer.setNextFixedStepDeltaTime(0)
        native.update(atTime: 1)
        f.renderer.setNextFixedStepDeltaTime(0.1875)
        native.update(atTime: 1.1875)
        #expect(f.world.fixedStepState.tick == 1)
        #expect(f.entity.position == [20, 0])
        // Prove enabled native constraints ran before checking the final display;
        // disabled constraints leave the child local pose untouched.
        try #require(abs(artwork.position.x - (isEnabled ? -20 : 0)) < 0.0001)
        #expect(abs(artwork.convert(.zero, to: f.renderer).x - (isEnabled ? 0 : 10)) < 0.0001)
        #expect(f.node.position.x == (isEnabled ? 20 : 10))
        #expect(f.renderer.fixedPresentedPoses.isEmpty == isEnabled)
    }

    @Test(arguments: [false, true], [false, true])
    func renderCallbackMutationPreservesDisplayedPosesAndCameraAlignment(flushInCallback: Bool, writerIsChild: Bool) throws {
        let f = Fixture()
        let unrelated = Entity()
        let camera = Entity(components: CameraComponent(target: .entity(f.entity.id), smoothing: 0))
        if writerIsChild { f.entity.addChild(unrelated) }
        else { f.world.addEntity(unrelated) }
        f.world.addEntity(camera)
        var observed: SIMD2<Float>?
        var observedAfterWriter: SIMD2<Float>?
        var unrelatedObservedAfterWriter: SIMD2<Float>?
        var observedAfterSetter: SIMD2<Float>?
        var observedAfterFlush: SIMD2<Float>?
        let token = f.world.subscribe(to: RenderingEvents.DidUpdate.self) { _ in
            // Attachment subscribers need interpolation to be visible during
            // DidUpdate, as well as after all its callbacks return.
            observed = f.entity.presentation.position
            unrelated.position += [1, 0]
            observedAfterSetter = f.entity.presentation.position
            if flushInCallback { f.renderer.flush() }
            observedAfterFlush = f.entity.presentation.position
        }
        let laterToken = f.world.subscribe(to: RenderingEvents.DidUpdate.self) { _ in
            // A final reconciliation after publish would fix pixels but leave
            // later attachment/input subscribers reading the canonical pose.
            observedAfterWriter = f.entity.presentation.position
            unrelatedObservedAfterWriter = unrelated.position
        }
        defer { token.cancel(); laterToken.cancel() }
        f.frame(0.1875)
        #expect(observed == [10, 0])
        #expect(observedAfterSetter == [10, 0])
        #expect(observedAfterFlush == [10, 0])
        #expect(unrelatedObservedAfterWriter == [1, 0])
        #expect(observedAfterWriter == [10, 0])
        #expect(unrelated.position == [1, 0])
        #expect(f.entity.position == [20, 0])
        #expect(f.entity.presentation.position == [10, 0])
        #expect(camera.position == [10, 0])
        let projected = try #require(f.renderer.viewPoint(from: .zero, relativeTo: f.entity))
        #expect(abs(projected.x - 100) < 0.0001)
        #expect(abs(projected.y - 50) < 0.0001)
    }
}
