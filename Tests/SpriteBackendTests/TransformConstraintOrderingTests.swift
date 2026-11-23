import ECSCore
import Foundation
import SpriteKit
import Testing
@testable import SpriteBackend

@MainActor @Suite struct TransformConstraintOrderingTests {
    @Test func completionGeneratedWritesSettleBeforeTheFinalPose() throws {
        let world = World(), target = Entity(), owner = Entity()
        target.position = [5, 0]
        owner.components.set(TransformConstraintComponent([TransformConstraint(.follow(.entity(target.id)))]))
        world.addEntity(target); world.addEntity(owner)
        let renderer = SpriteRenderer(world: world)
        renderer.update(0)
        // A no-op completion can enqueue another no-op transaction before the
        // eventual write: checking only dirty components misses this chain.
        withAnimation(.disabled) {} completion: {
            withAnimation(.disabled) {} completion: { owner.position = [100, 0] }
        }
        renderer.didFinishUpdate()
        #expect(owner.position == [5, 0])
        #expect(renderer.node(for: owner)?.position == CGPoint(x: 5, y: 0))
        #expect(owner.transformConstraintStatuses == [.active])
    }

    @Test func longCompletionChainsDeferAndRetryWithoutSpinning() {
        let world = World(), owner = Entity()
        owner.components.set(TransformConstraintComponent([TransformConstraint(.follow(.point([5, 0])))]))
        world.addEntity(owner)
        let renderer = SpriteRenderer(world: world)
        renderer.update(0)
        var count = 0
        func enqueue() {
            withAnimation(.disabled) {} completion: {
                count += 1; owner.position = [Float(count), 0]
                if count < 45 { enqueue() }
            }
        }
        enqueue()
        renderer.didFinishUpdate()
        #expect(count < 45)
        #expect(owner.transformConstraintStatuses == [.pendingChanges])
        renderer.didFinishUpdate()
        #expect(count == 45)
        #expect(owner.position == [5, 0])
        #expect(owner.transformConstraintStatuses == [.active])
    }

    @Test func droppedCompletionChainsCannotReparentAfterConstraints() throws {
        let world = World(), a = Entity(), b = Entity(), parent = Entity(), owner = Entity()
        parent.position = [100, 0]
        owner.components.set(TransformConstraintComponent([TransformConstraint(.follow(.point([5, 0])))]))
        for entity in [a, b, parent, owner] { world.addEntity(entity) }
        let renderer = SpriteRenderer(world: world)
        withAnimation(.linear(duration: 1)) { a.position = [10, 0] } completion: { b.removeFromParent() }
        withAnimation(.linear(duration: 1)) { b.position = [10, 0] } completion: { parent.addChild(owner) }
        renderer.flush()
        a.removeFromParent()
        renderer.didFinishUpdate()
        #expect(owner.parent === parent)
        #expect(owner.position == [-95, 0])
        #expect(renderer.presentedSceneMatrix(of: owner).apply(to: .zero) == [5, 0])
        #expect(owner.transformConstraintStatuses == [.active])
    }

    @Test func camerasCommitInTargetAndParentDependencyOrder() {
        let world = World(), target = Entity()
        target.position = [100, 40]; world.addEntity(target)
        let second = Entity(components: CameraComponent(smoothing: 0))
        let first = Entity(components: CameraComponent(target: .entity(target.id), smoothing: 0))
        second.components[CameraComponent.self]?.target = .entity(first.id)
        // The dependent camera has an earlier ID, so plain ID sorting is wrong.
        world.addEntity(second); world.addEntity(first)
        let nested = Entity(components: CameraComponent(target: .entity(target.id), smoothing: 0))
        first.addChild(nested)
        let renderer = SpriteRenderer(world: world)
        renderer.updateCameras(deltaTime: 0.1, time: 0)
        #expect(first.position == [100, 40])
        #expect(second.position == [100, 40])
        #expect(nested.position == .zero)
        #expect(renderer.presentedSceneMatrix(of: nested).apply(to: .zero) == [100, 40])
    }

    @Test func cameraFeedbackLeavesCamerasInPlace() {
        let world = World(), a = Entity(components: CameraComponent(smoothing: 0, trauma: 1, traumaDecay: 1)), b = Entity(components: CameraComponent(smoothing: 0))
        a.position = [10, 0]; b.position = [20, 0]
        a.components[CameraComponent.self]?.target = .entity(b.id)
        b.components[CameraComponent.self]?.target = .entity(a.id)
        world.addEntity(a); world.addEntity(b)
        let renderer = SpriteRenderer(world: world)
        renderer.updateCameras(deltaTime: 0.1, time: 0)
        #expect(a.position == [10, 0])
        #expect(b.position == [20, 0])
        #expect(a.components[CameraComponent.self]?.trauma == 0.9)
        renderer.updateCameras(deltaTime: 2, time: 2)
        #expect(a.components[CameraComponent.self]?.trauma == 0)
        #expect(renderer.node(for: a)?.childNode(withName: SpriteRenderer.cameraNodeName)?.position == .zero)
    }

    @Test func invalidSelfTargetsDoNotCreateFeedbackOrLoseDiagnostics() {
        let world = World(), owner = Entity()
        owner.position = [100, 100]
        owner.components.set(TransformConstraintComponent([
            TransformConstraint(.follow(.entity(owner.id), smoothing: .nan)),
            TransformConstraint(.positionBounds(min: [-5, -5], max: [5, 5]))
        ]))
        world.addEntity(owner)
        let renderer = SpriteRenderer(world: world)
        renderer.updateTransformConstraints(deltaTime: 0.1)
        #expect(owner.position == [5, 5])
        #expect(owner.transformConstraintStatuses == [.invalidConfiguration, .active])
        owner.components[TransformConstraintComponent.self]?.constraints[0].isEnabled = false
        #expect(owner.transformConstraintStatuses == [.disabled, .notRendered])
    }

    @Test func rejectedCameraTargetsLeaveIndependentLimitsActive() {
        let world = World(), owner = Entity(), camera = Entity(components: CameraComponent(isActive: false))
        owner.position = [100, 100]; owner.addChild(camera)
        owner.components.set(TransformConstraintComponent([
            TransformConstraint(.follow(.entity(camera.id))),
            TransformConstraint(.positionBounds(min: [-5, -5], max: [5, 5]))
        ]))
        world.addEntity(owner)
        let renderer = SpriteRenderer(world: world)
        renderer.updateTransformConstraints(deltaTime: 0.1)
        #expect(owner.position == [5, 5])
        #expect(owner.transformConstraintStatuses == [.cameraControlled, .active])
    }

    @Test func rejectedPhysicsRelationshipsDoNotBlockVisualFollowers() {
        let world = World(), body = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 5))), follower = Entity()
        body.position = [20, 30]
        body.components.set(TransformConstraintComponent([TransformConstraint(.follow(.entity(follower.id)))]))
        follower.components.set(TransformConstraintComponent([TransformConstraint(.follow(.entity(body.id)))]))
        world.addEntity(body); world.addEntity(follower)
        let renderer = SpriteRenderer(world: world)
        renderer.updateTransformConstraints(deltaTime: 0.1)
        #expect(body.transformConstraintStatuses == [.dynamicBody])
        #expect(follower.transformConstraintStatuses == [.active])
        #expect(follower.position == [20, 30])
    }

    @Test func inactiveCameraOwnersDescendantsAndFeedbackTargetsAreRejected() {
        let world = World(), camera = Entity(components: CameraComponent(isActive: false)), child = Entity(), follower = Entity()
        camera.components.set(TransformConstraintComponent([TransformConstraint(.follow(.point([100, 0])))]))
        child.components.set(TransformConstraintComponent([TransformConstraint(.follow(.point([100, 0])))]))
        follower.components.set(TransformConstraintComponent([TransformConstraint(.follow(.entity(camera.id), offset: [10, 0]))]))
        camera.components[CameraComponent.self]?.target = .entity(follower.id)
        camera.addChild(child); world.addEntity(camera); world.addEntity(follower)
        let renderer = SpriteRenderer(world: world)
        for _ in 0..<10 {
            renderer.updateTransformConstraints(deltaTime: 0.1)
            renderer.updateCameras(deltaTime: 0.1, time: 0)
        }
        for entity in [camera, child, follower] {
            #expect(entity.transformConstraintStatuses == [.cameraControlled])
            #expect(entity.position == .zero)
        }
    }
}
