@_spi(Backend) import ECSCore
import Foundation
@_spi(Backend) @testable import SpriteBackend
import SpriteKit
import Testing

private struct InterpolationMotion: Component {
    var translation: SIMD2<Float> = [20, 0]
    var rotation: Float = 0
    var scale: SIMD2<Float> = .zero
    var z: Float = 0
}

@MainActor private struct InterpolationMover: System {
    static var phase: SystemPhase { .fixedSimulation }
    init(world: World) {}
    func update(context: UpdateContext) {
        for entity in context.world.allEntities where entity.isActive {
            guard let motion = entity.components[InterpolationMotion.self] else { continue }
            var pose = entity.transform
            pose.translation += motion.translation
            pose.rotation += motion.rotation
            pose.scale += motion.scale
            pose.zPosition += motion.z
            entity.transform = pose
        }
    }
}

private struct InterpolationEvent: Event {}

@MainActor @Suite struct TransformInterpolationTests {
    @MainActor private struct Fixture {
        let world: World
        let renderer: SpriteRenderer
        let entity: Entity
        var node: SKNode { renderer.node(for: entity)! }

        init(marked: Bool = true) {
            world = World()
            // Binary-exact intervals make alpha/boundary assertions deterministic.
            world.fixedStep = .init(stepsPerSecond: 8)
            world.addSystem(InterpolationMover.self)
            entity = Entity(components: InterpolationMotion(), SpriteComponent(color: .red, size: [4, 4]))
            if marked { entity.components.set(TransformInterpolationComponent()) }
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

    @Test func interpolatesHalfAndZeroAlphaWithoutMutatingTheModel() throws {
        let f = Fixture()
        f.renderer.update(0.1875)
        f.renderer.didSimulatePhysics()
        let canonical = f.entity.transform
        let snapshot = try f.world.snapshot().jsonData()
        f.renderer.didFinishUpdate()
        #expect(f.world.fixedStepState.tick == 1)
        #expect(f.world.fixedStepState.interpolationAlpha == 0.5)
        #expect(f.node.position.x == 10)
        #expect(f.entity.presentation.position == [10, 0])
        #expect(f.entity.transform == canonical && canonical.translation == [20, 0])
        #expect(try f.world.snapshot().jsonData() == snapshot)
        f.frame(0.25)
        #expect(f.world.fixedStepState.tick == 2)
        #expect(f.world.fixedStepState.interpolationAlpha == 0)
        #expect(f.entity.position == [40, 0] && f.node.position.x == 20)
    }

    @Test func restoresBeforePhysicsAndFlushThenReappliesAfterTheFinalFlush() {
        let f = Fixture()
        f.frame(0.1875)
        #expect(f.node.position.x == 10)
        f.renderer.update(0.1875)
        // No fixed tick: this must be restored even without any dirty transform.
        #expect(f.node.position.x == 20)
        f.renderer.didSimulatePhysics()
        #expect(f.entity.position == [20, 0])
        f.renderer.didFinishUpdate()
        #expect(f.node.position.x == 10)
        f.renderer.flush()
        #expect(f.node.position.x == 20 && f.renderer.fixedPresentedPoses.isEmpty)
        f.frame(0.1875)
        #expect(f.node.position.x == 10)
    }

    @Test func typedEventsAndPresentationReadsKeepTheDisplayedPose() {
        let f = Fixture()
        var observed: SIMD2<Float>?
        let subscription = f.world.subscribe(to: InterpolationEvent.self) { _ in observed = f.entity.presentation.position }
        defer { subscription.cancel() }
        f.frame(0.1875)
        f.world.publish(InterpolationEvent())
        #expect(observed == [10, 0] && f.node.position.x == 10)
        #expect(f.entity.position == [20, 0])
    }

    @Test func unmarkedAndDisabledFixedScenesRetainCanonicalPresentation() {
        let unmarked = Fixture(marked: false)
        unmarked.frame(0.1875)
        #expect(unmarked.node.position.x == 20)
        let variable = Fixture()
        variable.world.fixedStep = nil
        variable.frame(0.1875)
        #expect(variable.world.fixedStepState.tick == 0)
        #expect(variable.node.position == .zero && variable.entity.position == .zero)
    }

    @Test func interpolatesEveryChannelAndTakesTheShortestRotationArc() {
        let f = Fixture()
        f.entity.transform.rotation = 170 * .pi / 180
        f.entity.components.set(InterpolationMotion(translation: [20, -8], rotation: -340 * .pi / 180,
                                                    scale: [2, 4], z: 6))
        f.frame(0.1875)
        #expect(f.entity.presentation.position == [10, -4])
        #expect(abs(Float(f.node.zRotation) - .pi) < 0.0001)
        #expect(f.node.xScale == 2 && f.node.yScale == 3 && f.node.zPosition == 3)
        #expect(f.entity.presentation.transform.zPosition == 3)
        #expect(f.entity.transform.scale == [3, 5] && f.entity.transform.zPosition == 6)
        f.renderer.flush()
        #expect(f.node.xScale == 3 && f.node.yScale == 5 && f.node.zPosition == 6)
    }

    @Test func interpolationMathValidatesBothPosesAndUsesWideIntermediates() throws {
        let maximum = Float.greatestFiniteMagnitude
        let a = Transform(translation: [-maximum, maximum], rotation: -maximum,
                          scale: [-maximum, maximum], zPosition: -maximum)
        let b = Transform(translation: [maximum, -maximum], rotation: maximum,
                          scale: [maximum, -maximum], zPosition: maximum)
        let result = try #require(SpriteRenderer.interpolateFixedTransform(previous: a, current: b, alpha: 0.5))
        #expect(result.translation == .zero && result.scale == .zero && result.zPosition == 0)
        #expect(result.rotation.isFinite)
        for invalid: Float in [.nan, .infinity, -.infinity] {
            let poses = [Transform(translation: [invalid, 0]), Transform(rotation: invalid),
                         Transform(scale: [1, invalid]), Transform(zPosition: invalid)]
            for pose in poses {
                #expect(SpriteRenderer.interpolateFixedTransform(previous: pose, current: .identity, alpha: 0.5) == nil)
                #expect(SpriteRenderer.interpolateFixedTransform(previous: .identity, current: pose, alpha: 0.5) == nil)
            }
        }
        for invalid: Double in [.nan, .infinity, -0.1, 1.1] {
            #expect(SpriteRenderer.interpolateFixedTransform(previous: a, current: b, alpha: invalid) == nil)
        }
    }

    @Test func externalTeleportSnapsAndCannotReuseHistoryOnAQuietFrame() {
        let f = Fixture()
        f.frame(0.1875)
        f.entity.position = [100, 0]
        #expect(f.node.position.x == 20) // restored animation baseline before the binding runs
        #expect(f.world.fixedTransformSample(for: f.entity) == nil)
        f.renderer.flush()
        #expect(f.node.position.x == 100)
        f.frame(0.1875)
        #expect(f.node.position.x == 100 && f.entity.position == [100, 0])
        f.frame(0.25)
        #expect(f.node.position.x == 100 && f.entity.position == [120, 0])
    }

    @Test func markerResetAndDisableImmediatelyRestoreTheCanonicalPose() {
        let reset = Fixture()
        reset.frame(0.1875)
        reset.entity.components[TransformInterpolationComponent.self]?.reset()
        #expect(reset.node.position.x == 20)
        reset.frame(0.1875)
        #expect(reset.node.position.x == 20)
        let disabled = Fixture()
        disabled.frame(0.1875)
        disabled.entity.components[TransformInterpolationComponent.self]?.isEnabled = false
        #expect(disabled.node.position.x == 20)
        disabled.frame(0.1875)
        #expect(disabled.node.position.x == 20)
    }

    @Test func pauseTimeScaleAndConfigurationChangesRestoreAndInvalidateHistory() {
        for reason in 0..<4 {
            let f = Fixture()
            f.frame(0.1875)
            switch reason {
            case 0: f.world.isPaused = true
            case 1: f.world.timeScale = 0
            case 2: f.world.fixedStep = nil
            default: f.world.fixedStep = .init(stepsPerSecond: 16)
            }
            #expect(f.node.position.x == 20 && f.renderer.fixedPresentedPoses.isEmpty)
            #expect(f.world.fixedTransformSample(for: f.entity) == nil)
            f.frame(0.1875)
            #expect(f.node.position.x == 20 && f.entity.position == [20, 0])
        }
    }

    @Test func activationReparentAndRemovalDoNotLeaveGhostOffsets() throws {
        let f = Fixture()
        let parent = Entity()
        parent.position = [30, 0]
        f.world.addEntity(parent)
        f.frame(0.1875)
        let originalNode = f.node
        f.entity.isEnabled = false
        #expect(originalNode.position.x == 20)
        f.entity.isEnabled = true
        f.frame(0.1875)
        #expect(originalNode.position.x == 20)
        f.frame(0.3125)
        #expect(originalNode.position.x == 30)
        try f.entity.setParent(parent)
        #expect(originalNode.position.x == 40)
        f.frame(0.3125)
        #expect(f.node.position.x == 40)
        #expect(f.world.fixedTransformSample(for: f.entity) == nil)
        f.frame(0.4375)
        let removedNode = f.node
        f.world.removeEntity(f.entity)
        #expect(removedNode.position.x == 60 && removedNode.parent == nil)
        #expect(f.renderer.fixedPresentedPoses.isEmpty)
    }

    @Test func frameClockResetClearsTheOneShotRawDeltaAndPresentation() {
        let f = Fixture()
        f.frame(0.1875)
        f.renderer.setNextFixedStepDeltaTime(0.25)
        f.renderer.resetFrameClock()
        #expect(f.node.position.x == 20)
        f.frame(100)
        #expect(f.world.fixedStepState.tick == 1 && f.world.fixedStepState.ticksThisFrame == 0)
        #expect(f.node.position.x == 20)
    }

    @Test func rawDeltaOverrideIsConsumedOnceWithoutChangingVariableCadence() {
        let f = Fixture()
        var updates: [TimeInterval] = []
        let token = f.world.subscribe(to: WorldEvents.Update.self) { updates.append($0.deltaTime) }
        defer { token.cancel() }
        f.renderer.setNextFixedStepDeltaTime(0.1875)
        f.frame(0.01)
        #expect(f.world.fixedStepState.tick == 1 && f.node.position.x == 10)
        #expect(updates.count == 1 && abs(updates[0] - 0.01) < 0.000001)
        f.frame(0.01)
        #expect(f.world.fixedStepState.tick == 1 && f.node.position.x == 10)
        #expect(updates.count == 2)
    }

    @Test func parentAndChildSamplesComposeAndCameraFollowsTheProposedPose() throws {
        let f = Fixture()
        let child = Entity(components: InterpolationMotion(translation: [4, 0]), TransformInterpolationComponent())
        child.position = [3, 0]
        f.entity.addChild(child)
        let camera = Entity(components: CameraComponent(target: .entity(child.id), smoothing: 0))
        f.world.addEntity(camera)
        f.frame(0.1875)
        #expect(f.node.position.x == 10)
        #expect(f.renderer.node(for: child)?.position.x == 5)
        #expect(child.scenePosition == [27, 0])
        #expect(camera.position == [15, 0])
        let displayed = try #require(f.renderer.viewPoint(from: .zero, relativeTo: child))
        #expect(abs(displayed.x - 100) < 0.001 && abs(displayed.y - 50) < 0.001)
        #expect(f.renderer.proposedFixedTargetPosition(of: camera) == nil)
    }

    @Test func staticVisualChildDoesNotInventLocalInterpolation() {
        let f = Fixture(marked: false)
        let child = Entity(components: TransformInterpolationComponent())
        child.position = [5, 0]
        f.entity.addChild(child)
        f.frame(0.1875)
        #expect(f.node.position.x == 20)
        #expect(f.renderer.fixedInterpolatedPose(for: child) == nil)
        #expect(f.renderer.node(for: child)?.convert(.zero, to: f.renderer).x == 25)
    }

    @Test func displayedHitsAndAttachmentsUseInterpolationWhileCollisionQueriesUseTheModel() throws {
        let f = Fixture()
        f.entity.components.set(CollisionComponent(shape: .circle(radius: 2)))
        f.entity.components.set(InputTargetComponent())
        f.frame(0.1875)
        #expect(f.renderer.entities(at: CGPoint(x: 10, y: 0)).first === f.entity)
        #expect(f.renderer.inputTarget(at: CGPoint(x: 10, y: 0)) === f.entity)
        #expect(f.renderer.entities(at: CGPoint(x: 20, y: 0)).isEmpty)
        #expect(f.world.raycast(from: [8, 0], to: [12, 0]).isEmpty)
        #expect(f.world.raycast(from: [18, 0], to: [22, 0]).first?.entity === f.entity)
        let anchor = try #require(f.renderer.viewPoint(from: .zero, relativeTo: f.entity))
        #expect(anchor == CGPoint(x: 110, y: 50))
        #expect(f.entity.scenePosition == [20, 0])
    }

    @Test func ownershipRejectsNativeBodiesCharactersCamerasAndConstraintsInRelatedHierarchy() {
        for kind in 0..<5 {
            for relation in 0..<3 {
                let f = Fixture()
                let owner: Entity
                if relation == 0 { owner = f.entity }
                else if relation == 1 {
                    owner = Entity()
                    f.entity.addChild(owner)
                } else {
                    owner = Entity()
                    f.world.addEntity(owner)
                    owner.addChild(f.entity)
                }
                switch kind {
                case 0: owner.components.set(PhysicsBodyComponent(shape: .circle(radius: 1), isDynamic: false))
                case 1: owner.components.set(CharacterControllerComponent(shape: .circle(radius: 1)))
                case 2: owner.components.set(CameraComponent())
                case 3: owner.components.set(TransformConstraintComponent([]))
                default: f.renderer.node(for: owner)?.physicsBody = SKPhysicsBody(circleOfRadius: 1)
                }
                f.frame(0.1875)
                #expect(f.node.position.x == 20)
                #expect(f.renderer.fixedPresentedPoses.isEmpty)
            }
        }
    }

    @Test func descendantNativeArtworkBodyAlsoBlocksParentInterpolation() {
        let f = Fixture()
        let native = SKNode()
        native.physicsBody = SKPhysicsBody(circleOfRadius: 1)
        f.node.addChild(native)
        f.frame(0.1875)
        #expect(f.node.position.x == 20)
        #expect(native.convert(.zero, to: f.renderer).x == 20)
    }

    @Test func unrelatedSiblingOwnershipDoesNotBlockAVisualEntity() {
        let f = Fixture()
        f.world.addEntity(Entity(components: PhysicsBodyComponent(shape: .circle(radius: 1))))
        f.frame(0.1875)
        #expect(f.node.position.x == 10)
    }

    @Test func nativeTransformActionsAndDirectNativeEditsWinOverSamples() {
        for channel in 0..<5 {
            let f = Fixture()
            f.renderer.update(0.1875)
            f.renderer.didSimulatePhysics()
            switch channel {
            case 0: f.node.position.x = 77
            case 1: f.node.zRotation = 0.7
            case 2: f.node.xScale = 2
            case 3: f.node.zPosition = 9
            default: f.node.run(.moveBy(x: 100, y: 0, duration: 1), withKey: "external-transform")
            }
            f.renderer.didFinishUpdate()
            #expect(f.renderer.fixedPresentedPoses.isEmpty)
            #expect(f.entity.position == [20, 0])
            if channel == 0 { #expect(f.node.position.x == 77) }
            if channel == 3 { #expect(f.node.zPosition == 9) }
        }
    }

    @Test func modelAnimationUsesRestoredBaselineAndRejectsInterpolation() throws {
        let f = Fixture()
        f.frame(0.1875)
        withAnimation(.linear(duration: 1)) { f.entity.position = [100, 0] }
        #expect(f.node.position.x == 20)
        f.renderer.flush()
        #expect(f.node.position.x == 20 && f.node.action(forKey: "transform.position") != nil)
        f.frame(0.1875)
        #expect(f.renderer.fixedPresentedPoses.isEmpty)
        #expect(f.entity.position == [100, 0])

        let explicit = Fixture()
        explicit.renderer.update(0.1875)
        explicit.renderer.didSimulatePhysics()
        let controller = try explicit.entity.playAnimation(.move(to: [100, 0], duration: 1))
        explicit.renderer.didFinishUpdate()
        #expect(!controller.isTerminal && explicit.renderer.fixedPresentedPoses.isEmpty)
    }

    @Test func releasingNativeActionOwnershipCannotReviveAnOldFixedPair() {
        let f = Fixture()
        f.world.fixedStep = .init(stepsPerSecond: 1, maximumFrameDeltaTime: 2)
        f.entity.components.set(InterpolationMotion(translation: [12, 0]))
        f.renderer.setNextFixedStepDeltaTime(1.5)
        f.frame(0.01)
        #expect(f.world.fixedStepState.tick == 1 && f.world.fixedStepState.interpolationAlpha == 0.5)
        #expect(f.entity.position == [12, 0] && f.node.position.x == 6)

        f.node.run(.wait(forDuration: 1), withKey: "opaque-owner")
        f.renderer.didFinishUpdate()
        #expect(f.node.position.x == 12)
        #expect(f.world.fixedTransformSample(for: f.entity) == nil)
        let clock = f.world.fixedStepState
        f.node.removeAction(forKey: "opaque-owner")
        f.renderer.didFinishUpdate()
        #expect(f.node.position.x == 12 && f.entity.presentation.position == [12, 0])
        #expect(f.world.fixedStepState == clock)

        // Interpolation resumes only when the next tick supplies a fresh pair.
        f.renderer.setNextFixedStepDeltaTime(0.75)
        f.frame(0.02)
        #expect(f.world.fixedStepState.tick == 2 && f.entity.position == [24, 0])
        #expect(f.node.position.x == 15)
    }

    @Test func nativePoseMismatchDiscardsHistoryUntilAFreshFixedTick() {
        let f = Fixture()
        f.renderer.update(0.1875)
        f.renderer.didSimulatePhysics()
        f.node.zPosition = 9
        f.renderer.didFinishUpdate()
        #expect(f.node.zPosition == 9 && f.node.position.x == 20)
        #expect(f.world.fixedTransformSample(for: f.entity) == nil)
        f.node.zPosition = 0
        f.renderer.didFinishUpdate()
        #expect(f.node.position.x == 20 && f.renderer.fixedPresentedPoses.isEmpty)
        #expect(f.world.fixedStepState.tick == 1)
    }

    @Test(arguments: [0, 1, 2, 3, 4])
    func betweenFrameNativeEditsSurviveRestorationUntilFreshFixedOwnership(channel: Int) {
        let f = Fixture()
        f.entity.components.set(InterpolationMotion(rotation: 1, scale: [2, 4], z: 6))
        f.frame(0.1875)
        #expect(f.node.position.x == 10 && f.entity.position == [20, 0])
        let canonical = f.entity.transform
        switch channel {
        case 0: f.node.position.x = 77
        case 1: f.node.zRotation = 2
        case 2: f.node.xScale = 8
        case 3: f.node.yScale = 9
        default: f.node.zPosition = 10
        }

        // The next update restores only unchanged native channels, even though
        // there are no new ticks or component writes to mask a lost native edit.
        f.renderer.update(0.1875)
        #expect(f.node.position.x == (channel == 0 ? 77 : 20))
        #expect(f.node.zRotation == (channel == 1 ? 2 : 1))
        #expect(f.node.xScale == (channel == 2 ? 8 : 3))
        #expect(f.node.yScale == (channel == 3 ? 9 : 5))
        #expect(f.node.zPosition == (channel == 4 ? 10 : 6))
        #expect(f.entity.transform == canonical)
        #expect(f.world.fixedTransformSample(for: f.entity) == nil)
        f.renderer.didSimulatePhysics()
        f.renderer.didFinishUpdate()
        #expect(f.world.fixedStepState.tick == 1 && f.renderer.fixedPresentedPoses.isEmpty)
        let edited = f.entity.presentation.transform
        f.frame(0.1875)
        #expect(f.entity.presentation.transform == edited && f.entity.transform == canonical)

        f.frame(0.25)
        #expect(f.world.fixedStepState.tick == 2 && f.entity.position == [40, 0])
        #expect(f.entity.presentation.transform == canonical)
        #expect(f.world.fixedTransformSample(for: f.entity) != nil)
    }

    @Test func registrationAndSnapshotRoundTripKeepTheMarkerButNoPresentationHistory() throws {
        SpriteRenderer.registerComponents()
        #expect(ComponentRegistry.isRegistered(TransformInterpolationComponent.self))
        let f = Fixture()
        f.frame(0.1875)
        let saved = try WorldSnapshot(data: f.world.snapshot().jsonData())
        let clone = f.entity.clone()
        #expect(clone.components[TransformInterpolationComponent.self] == f.entity.components[TransformInterpolationComponent.self])
        f.world.restore(saved)
        f.renderer.flush()
        let restored = try #require(f.world.entity(withID: f.entity.id))
        #expect(restored.components[TransformInterpolationComponent.self]?.isEnabled == true)
        #expect(restored.position == [20, 0] && f.renderer.node(for: restored)?.position.x == 20)
        #expect(f.world.fixedTransformSample(for: restored) == nil)
        #expect(f.renderer.fixedPresentedPoses.isEmpty)
    }

    @Test func poolingAndRendererTeardownRestoreCanonicalNativeValues() throws {
        let world = World()
        world.fixedStep = .init(stepsPerSecond: 8)
        world.addSystem(InterpolationMover.self)
        var renderer: SpriteRenderer? = SpriteRenderer(world: world)
        let template = Entity(components: InterpolationMotion(), TransformInterpolationComponent())
        let pool = try EntityPool(prefab: PrefabResource(root: template), scene: world, capacity: 1)
        let entity = try #require(try pool.acquire())
        renderer?.update(0)
        renderer?.didSimulatePhysics()
        renderer?.didFinishUpdate()
        renderer?.update(0.1875)
        renderer?.didSimulatePhysics()
        renderer?.didFinishUpdate()
        let node = try #require(renderer?.node(for: entity))
        #expect(node.position.x == 10)
        #expect(try pool.release(entity))
        #expect(node.position.x == 20 && renderer?.fixedPresentedPoses.isEmpty == true)
        let reused = try #require(try pool.acquire { $0.position = [100, 0] })
        #expect(reused === entity && node.position.x == 100)
        renderer?.update(0.3125)
        renderer?.didSimulatePhysics()
        renderer?.didFinishUpdate()
        #expect(node.position.x == 110 && entity.position == [120, 0])
        renderer = nil
        #expect(node.position.x == 120)
    }
}
