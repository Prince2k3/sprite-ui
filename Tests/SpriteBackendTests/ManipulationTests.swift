import ECSCore
import Foundation
import SpriteKit
@testable import SpriteBackend
import Testing

@MainActor @Suite struct ManipulationSessionTests {
    func fixture(physics: PhysicsBodyComponent? = nil, configuration: ManipulationComponent = .init()) -> (World, SpriteRenderer, Entity) {
        let world = World()
        let renderer = SpriteRenderer(world: world, size: CGSize(width: 320, height: 400))
        let entity = Entity(name: "item", components: SpriteComponent(color: .cyan, size: [40, 40]),
                            InputTargetComponent(), configuration)
        if let physics { entity.components.set(physics) }
        world.addEntity(entity)
        return (world, renderer, entity)
    }
    func close(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Bool { abs(a.x-b.x) < 0.001 && abs(a.y-b.y) < 0.001 }

    @Test func cumulativeTranslationKeepsGrabOffsetAndEndIsIdempotent() throws {
        let (_, renderer, entity) = fixture()
        let session = try #require(renderer.beginManipulation(at: [10, 5]))
        #expect(session.update(translation: [30, -10]))
        #expect(close(entity.position, [30, -10]))
        #expect(session.update(translation: [40, -20]))
        #expect(close(entity.position, [40, -20]))
        session.end(); session.end(); session.cancel()
        #expect(!session.isActive && !session.update(translation: [80, 0]))
        #expect(close(entity.position, [40, -20]))
    }

    @Test func captureStartsFromDisplayedPoseRatherThanAnimationTarget() throws {
        let (_, renderer, entity) = fixture()
        entity.position = [100, 0]; renderer.flush()
        let node = try #require(renderer.node(for: entity))
        node.position = CGPoint(x: 50, y: 0)
        let session = try #require(renderer.beginManipulation(at: [55, 0]))
        #expect(session.initialTransform.translation == [50, 0])
        #expect(entity.position == [50, 0])
        #expect(session.update(translation: [10, 0]))
        #expect(close(entity.position, [60, 0]))
        session.end()
    }

    @Test func rotatedScaledAndMovingParentUsesCurrentDisplayedCoordinates() throws {
        let (world, renderer, entity) = fixture()
        let parent = Entity()
        parent.position = [30, -20]; parent.rotation = .pi / 2; parent.scale = [2, 1]
        world.addEntity(parent); parent.addChild(entity)
        entity.position = [10, 5]; renderer.flush()
        let anchor = entity.scenePosition
        let session = try #require(renderer.beginManipulation(of: entity, at: anchor))
        #expect(session.update(translation: [0, 20]))
        #expect(close(entity.position, [20, 5]))
        parent.position.x += 10; renderer.flush()
        #expect(session.update(translation: [0, 20]))
        #expect(close(entity.scenePosition, anchor + [0, 20]))
        session.end()
    }

    @Test func rotationAndScaleKeepTheCapturedPointUnderThePointer() throws {
        let (_, renderer, entity) = fixture()
        let session = try #require(renderer.beginManipulation(at: [10, 0]))
        #expect(session.update(rotation: .pi / 2, scale: 2))
        #expect(close(entity.transform.matrix.apply(to: [10, 0]), [10, 0]))
        #expect(close(entity.scale, [2, 2]))
        session.end()
    }

    @Test func locksBoundsAndSnappingAreParentLocal() throws {
        let config = ManipulationComponent(operations: .translation, translationAxes: .x,
            translationBounds: .init(min: [-15, -15], max: [15, 15]), translationSnap: [10, 10])
        let (_, renderer, entity) = fixture(configuration: config)
        let session = try #require(renderer.beginManipulation(at: .zero))
        #expect(session.update(translation: [100, 100], rotation: 1, scale: 2))
        #expect(entity.position == [15, 0] && entity.rotation == 0 && entity.scale == [1, 1])
        session.end()
    }

    @Test func invalidSamplesAreAtomicAndDoNotEndTheCapture() throws {
        let (_, renderer, entity) = fixture()
        let session = try #require(renderer.beginManipulation(at: .zero))
        #expect(!session.update(translation: [.nan, 1]))
        #expect(!session.update(rotation: .infinity))
        #expect(!session.update(scale: 0))
        #expect(session.isActive && entity.transform == .identity)
        session.cancel()
    }

    @Test func physicsIsSuspendedNativelyAndConfigurationDoesNotPersistTransientState() throws {
        let physics = PhysicsBodyComponent(shape: .circle(radius: 20), velocity: [15, 8], angularVelocity: 2)
        let (world, renderer, entity) = fixture(physics: physics)
        let body = try #require(renderer.node(for: entity)?.physicsBody)
        let session = try #require(renderer.beginManipulation(at: .zero))
        #expect(!body.isDynamic && body.velocity == .zero && body.angularVelocity == 0)
        #expect(entity.components[PhysicsBodyComponent.self] == physics)
        let snapshot = try WorldSnapshot(data: world.snapshot().jsonData())
        #expect(snapshot.entities[0][PhysicsBodyComponent.self]?.isDynamic == true)
        #expect(snapshot.entities[0][ManipulationComponent.self] != nil)
        renderer.didSimulatePhysics()
        #expect(entity.components[PhysicsBodyComponent.self] == physics)
        #expect(session.update(translation: [25, 0]))
        session.end()
        #expect(body.isDynamic && body.velocity == .zero)
        #expect(entity.components[PhysicsBodyComponent.self]?.velocity == .zero)
    }

    @Test func optionalReleaseVelocityAndDescendantBodiesAreRestored() throws {
        let (world, renderer, child) = fixture(physics: .init(shape: .circle(radius: 10), velocity: [9, 2], angularVelocity: 1))
        child.components.remove(ManipulationComponent.self)
        let parent = Entity(components: InputTargetComponent(), ManipulationComponent(physicsRelease: .restoreVelocity))
        world.addEntity(parent); parent.addChild(child); renderer.flush()
        let body = try #require(renderer.node(for: child)?.physicsBody)
        let session = try #require(renderer.beginManipulation(of: parent, at: .zero))
        #expect(!body.isDynamic)
        session.cancel()
        #expect(body.isDynamic && abs(body.velocity.dx - 9) < 0.001 && abs(body.angularVelocity - 1) < 0.001)
    }

    @Test func appPhysicsEditsCancelWithoutRestoringStaleProperties() throws {
        let (_, renderer, entity) = fixture(physics: .init(shape: .circle(radius: 20), velocity: [4, 0]))
        let session = try #require(renderer.beginManipulation(at: .zero))
        entity.components[PhysicsBodyComponent.self]?.mass = 2
        entity.components[PhysicsBodyComponent.self]?.velocity = [99, 1]
        renderer.flush()
        #expect(!session.isActive)
        #expect(entity.components[PhysicsBodyComponent.self]?.mass == 2)
        #expect(entity.components[PhysicsBodyComponent.self]?.velocity == [99, 1])
        #expect(renderer.node(for: entity)?.physicsBody?.isDynamic == true)
    }

    @Test func removalAndActivationReuseCannotReviveOldCaptures() throws {
        let (world, renderer, entity) = fixture()
        let first = try #require(renderer.beginManipulation(at: .zero))
        entity.isEnabled = false; entity.isEnabled = true
        #expect(!first.isActive && !first.update(translation: [80, 0]))
        let second = try #require(renderer.beginManipulation(at: .zero))
        entity.removeFromParent(); world.addEntity(entity)
        #expect(!second.isActive && !second.update(translation: [80, 0]))
        #expect(entity.position == .zero)
    }

    @Test func disablingConfigurationOrHitTargetCancelsAnAncestorCapture() throws {
        let (world, renderer, child) = fixture()
        child.components.remove(ManipulationComponent.self)
        let parent = Entity(components: InputTargetComponent(), ManipulationComponent())
        world.addEntity(parent); parent.addChild(child); renderer.flush()
        let first = try #require(renderer.beginManipulation(at: .zero))
        #expect(first.entity === parent)
        child.components[InputTargetComponent.self]?.isEnabled = false
        #expect(!first.isActive)
        child.components[InputTargetComponent.self]?.isEnabled = true
        let second = try #require(renderer.beginManipulation(at: .zero))
        parent.components[ManipulationComponent.self]?.isEnabled = false
        #expect(!second.isActive)
    }

    @Test func foregroundTargetsDoNotClickThroughAndSubtreesCannotHaveTwoOwners() throws {
        let (world, renderer, entity) = fixture()
        let foreground = Entity(components: SpriteComponent(color: .red, size: [40, 40]), InputTargetComponent())
        foreground.zPosition = 2; world.addEntity(foreground)
        #expect(renderer.beginManipulation(at: .zero) == nil)
        foreground.removeFromParent()
        let session = try #require(renderer.beginManipulation(at: .zero))
        #expect(renderer.beginManipulation(of: entity, at: .zero) == nil)
        let child = Entity(components: InputTargetComponent(), ManipulationComponent())
        entity.addChild(child) // Structural edits cancel the previous capture.
        #expect(!session.isActive)
        let next = try #require(renderer.beginManipulation(of: entity, at: .zero))
        #expect(renderer.beginManipulation(of: child, at: .zero) == nil)
        next.end()
    }

    @Test func externalPoseAndReparentingWinOverTheGesture() throws {
        let (world, renderer, entity) = fixture()
        let first = try #require(renderer.beginManipulation(at: .zero))
        entity.position = [88, 0]
        #expect(!first.isActive && entity.position == [88, 0])
        let second = try #require(renderer.beginManipulation(of: entity, at: [88, 0]))
        let parent = Entity(); world.addEntity(parent); parent.addChild(entity)
        #expect(!second.isActive)
    }

    @Test func lifecycleCallbacksCanCancelAndCannotRecaptureDuringGlobalCancellation() throws {
        let (world, renderer, entity) = fixture()
        var began = 0, changed = 0, ended = 0, cancelled = 0
        var replacement: ManipulationSession?
        let tokens = [
            world.subscribe(to: ManipulationEvents.Began.self) { _ in began += 1 },
            world.subscribe(to: ManipulationEvents.Changed.self) { _ in changed += 1 },
            world.subscribe(to: ManipulationEvents.Ended.self) { _ in ended += 1 },
            world.subscribe(to: ManipulationEvents.Cancelled.self) { _ in
                cancelled += 1
                replacement = renderer.beginManipulation(of: entity, at: entity.scenePosition)
            }
        ]
        let session = try #require(renderer.beginManipulation(at: .zero))
        #expect(session.update(translation: [10, 0]))
        renderer.cancelManipulations()
        session.cancel(); session.end()
        #expect(began == 1 && changed == 1 && ended == 0 && cancelled == 1 && replacement == nil)
        for token in tokens { token.cancel() }
    }

    @Test func beganCallbackCanDisableTheEntityBeforeBeginReturns() {
        let (world, renderer, entity) = fixture()
        let token = world.subscribe(to: ManipulationEvents.Began.self) { _ in entity.isEnabled = false }
        #expect(renderer.beginManipulation(at: .zero) == nil)
        #expect(renderer.manipulationSessions.isEmpty)
        token.cancel()
    }

    @Test func reusingADescendantBodyCancelsTheParentCapture() throws {
        let (world, renderer, child) = fixture(physics: .init(shape: .circle(radius: 10)))
        child.components.remove(ManipulationComponent.self)
        let parent = Entity(components: InputTargetComponent(), ManipulationComponent())
        world.addEntity(parent); parent.addChild(child); renderer.flush()
        let session = try #require(renderer.beginManipulation(of: parent, at: .zero))
        child.isEnabled = false; child.isEnabled = true
        #expect(!session.isActive)
        #expect(child.components[PhysicsBodyComponent.self]?.isDynamic == true)
        #expect(renderer.node(for: child)?.physicsBody?.isDynamic == true)
    }

    @Test func singularDisplayedParentRejectsAnUpdateWithoutWritingANonfinitePose() throws {
        let (world, renderer, entity) = fixture()
        let parent = Entity(); world.addEntity(parent); parent.addChild(entity); renderer.flush()
        let session = try #require(renderer.beginManipulation(at: .zero))
        parent.scale = [0, 1]; renderer.flush()
        #expect(!session.update(translation: [20, 0]))
        #expect(!session.isActive)
        #expect(entity.position.x.isFinite && entity.position.y.isFinite)
        #expect(renderer.beginManipulation(of: entity, at: .zero) == nil)
    }

    @Test func animationCompletionCannotPublishABeganEventAfterCancellingSetup() {
        let (world, renderer, entity) = fixture()
        var began = 0
        let token = world.subscribe(to: ManipulationEvents.Began.self) { _ in began += 1 }
        withAnimation(.linear(duration: 10)) {
            entity.position = [100, 0]
        } completion: {
            entity.components[ManipulationComponent.self]?.isEnabled = false
        }
        renderer.flush()
        #expect(renderer.beginManipulation(of: entity, at: .zero) == nil)
        #expect(began == 0)
        token.cancel()
    }

    @Test func playbackStopCallbacksCannotOverwriteAUsersNewPoseDuringStartup() throws {
        let (world, renderer, entity) = fixture()
        _ = try entity.playAnimation(.move(to: [100, 0], duration: 5))
        renderer.flush()
        let token = world.subscribe(to: PlaybackEvents.Stopped.self) { _ in
            renderer.cancelManipulations()
            entity.position = [99, 0]
        }
        #expect(renderer.beginManipulation(of: entity, at: .zero) == nil)
        #expect(entity.position == [99, 0])
        #expect(renderer.manipulationSessions.isEmpty)
        token.cancel()
    }

    @Test(arguments: [false, true])
    func newlyDynamicBodiesCannotFightAnExistingCapture(initiallyStatic: Bool) throws {
        let (_, renderer, entity) = fixture(physics: initiallyStatic ? .init(shape: .circle(radius: 20), isDynamic: false) : nil)
        let session = try #require(renderer.beginManipulation(at: .zero))
        entity.components.set(PhysicsBodyComponent(shape: .circle(radius: 20), velocity: [8, 0]))
        #expect(!session.isActive)
        renderer.flush()
        #expect(renderer.node(for: entity)?.physicsBody?.isDynamic == true)
        #expect(entity.components[PhysicsBodyComponent.self]?.velocity == [8, 0])
    }

    @Test func driverOwnedEntitiesAndConnectedBodiesRejectCapture() {
        let (world, renderer, entity) = fixture(physics: .init(shape: .circle(radius: 20)))
        entity.components.set(CharacterControllerComponent(shape: .circle(radius: 20)))
        #expect(renderer.beginManipulation(at: .zero) == nil)
        entity.components.remove(CharacterControllerComponent.self)
        let other = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 10)))
        other.position = [80, 0]; world.addEntity(other)
        world.addEntity(Entity(components: PhysicsJointComponent(bodyA: entity.id, bodyB: other.id, constraint: .pin())))
        #expect(renderer.beginManipulation(at: .zero) == nil)
    }
}
