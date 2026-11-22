import ECSCore
import Gameplay
import GameplayECS
import Foundation
import Testing

@MainActor @Suite struct RelativeMovementTests {
    func scene() -> (World, Entity, Entity) {
        let world = World()
        let parent = Entity(); parent.position = [15, 10]; parent.rotation = .pi / 3; parent.scale = [2, 0.75]
        let child = Entity(); parent.addChild(child); world.addEntity(parent)
        return (world, parent, child)
    }

    @Test func pathWaypointsAndSpeedUseSceneSpace() {
        let (world, _, child) = scene()
        world.addSystem(PathFollowSystem.self)
        child.follow([[25, 10], [25, 20]], speed: 10, orientsToPath: true)
        world.update(deltaTime: 1.5)
        #expect(distance(child.scenePosition, [25, 15]) < 0.001)
        let heading = child.convert(direction: [1, 0], to: nil)!
        #expect(abs(heading.x) < 0.001 && heading.y > 0)
    }

    @Test func steeringIsIndependentOfParentTransform() {
        let (world, _, child) = scene()
        let direct = Entity(); direct.position = child.scenePosition; world.addEntity(direct)
        let steering = SteeringComponent(maxSpeed: 100, maxForce: 300, radius: 2, goals: [SteeringGoal(.seek(.point([200, 100])))])
        child.components.set(steering); direct.components.set(steering)
        world.addSystem(SteeringSystem.self)
        for _ in 0..<30 { world.update(deltaTime: 1 / 60) }
        #expect(distance(child.scenePosition, direct.scenePosition) < 0.001)
        #expect(distance(child.components[SteeringComponent.self]!.velocity, direct.components[SteeringComponent.self]!.velocity) < 0.001)
    }

    @Test func singularParentDoesNotConsumePathProgress() {
        let (world, parent, child) = scene()
        world.addSystem(PathFollowSystem.self)
        parent.scale = .zero
        child.follow([[25, 10]], speed: 100)
        world.update(deltaTime: 1)
        #expect(child.components[PathComponent.self]?.nextIndex == 0)
        #expect(child.position == .zero)
    }

    @Test func steeringParentAndChildCommitsAreIndependentOfQueryOrder() {
        for _ in 0..<20 {
            let (world, parent, child) = scene()
            child.position = [20, 5]
            let initial = child.scenePosition
            parent.components.set(SteeringComponent(maxSpeed: 100, maxForce: 0, velocity: [5, 10]))
            child.components.set(SteeringComponent(maxSpeed: 100, maxForce: 0, velocity: [-3, 4]))
            world.addSystem(SteeringSystem.self)
            world.update(deltaTime: 0.5)
            #expect(distance(child.scenePosition, initial + [-1.5, 2]) < 0.001)
        }
    }

    @Test func pathsOnBothParentAndChildSpendOnlyTheirOwnSceneDistance() {
        let (world, parent, child) = scene()
        child.position = [20, 5]
        let initial = child.scenePosition
        parent.follow([parent.scenePosition + [100, 0]], speed: 5, orientsToPath: true)
        child.follow([initial + [0, 100]], speed: 5, orientsToPath: true)
        world.addSystem(PathFollowSystem.self)
        world.update(deltaTime: 1)
        #expect(distance(child.scenePosition, initial + [0, 5]) < 0.001)
    }

    @Test func completionHandlersCanTeleportAndReplanAChildWithoutLosingTheirEdits() {
        let (world, parent, child) = scene()
        world.addSystem(PathFollowSystem.self)
        parent.follow([parent.scenePosition + [5, 0]], speed: 5)
        child.follow([child.scenePosition + [0, 100]], speed: 5)
        let subscription = world.subscribe(to: PathEvents.DidFinish.self, on: parent) { _ in
            try? child.setPosition([300, 300], relativeTo: nil)
            child.follow([[400, 300]], speed: 5)
        }
        world.update(deltaTime: 1)
        #expect(distance(child.scenePosition, [300, 300]) < 0.001)
        world.update(deltaTime: 1)
        #expect(distance(child.scenePosition, [305, 300]) < 0.001)
        _ = subscription
    }

    private func distance(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { let d = a - b; return (d * d).sum().squareRoot() }
}
