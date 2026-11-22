@_spi(Backend) import ECSCore
import Foundation
import SpriteKit
import SwiftUI
import Testing
@testable import SpriteBackend

@MainActor @Suite struct BackendActivationTests {
    @Test func disablesBodiesQueriesAndInputImmediatelyThenRestoresMotionOnSameNode() throws {
        let world = World(), renderer = SpriteRenderer(world: world), parent = Entity()
        let child = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 10)), InputTargetComponent())
        parent.addChild(child); world.addEntity(parent)
        let node = try #require(renderer.node(for: child)), body = try #require(node.physicsBody)
        node.position = CGPoint(x: 25, y: 40); body.velocity = CGVector(dx: 75, dy: 12)
        parent.isEnabled = false
        #expect(node.isHidden && node.isPaused && node.physicsBody == nil)
        #expect(child.position == [25, 40])
        #expect(abs((child.components[PhysicsBodyComponent.self]?.velocity.x ?? 0) - 75) < 0.001)
        #expect(world.raycast(from: [0, 40], to: [100, 40]).isEmpty)
        #expect(renderer.inputTarget(at: CGPoint(x: 25, y: 40)) == nil)
        child.applyImpulse([1000, 0])
        parent.isEnabled = true; renderer.flush()
        #expect(renderer.node(for: child) === node && !node.isHidden && !node.isPaused)
        let replacement = try #require(node.physicsBody)
        #expect(replacement !== body)
        #expect(abs((node.physicsBody?.velocity.dx ?? 0) - 75) < 0.001)
        #expect(world.raycast(from: [0, 40], to: [100, 40]).first?.entity === child)
    }
    @Test func dormantComponentEditsWinAndNewRenderersDoNotCreateDormantBodies() throws {
        let world = World(), entity = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 5)))
        entity.isEnabled = false; world.addEntity(entity)
        let renderer = SpriteRenderer(world: world), node = try #require(renderer.node(for: entity))
        #expect(node.isHidden && node.physicsBody == nil)
        entity.position = [30, 50]; entity.components[PhysicsBodyComponent.self]?.velocity = [10, 20]
        renderer.flush(); #expect(node.physicsBody == nil)
        entity.isEnabled = true; renderer.flush()
        #expect(node.position == CGPoint(x: 30, y: 50))
        #expect(abs((node.physicsBody?.velocity.dy ?? 0) - 20) < 0.001)
    }
    @Test func rootActivationPreservesScenePauseAndCameraFallsBack() {
        let world = World(), renderer = SpriteRenderer(world: world)
        let a = Entity(components: CameraComponent()), b = Entity(components: CameraComponent())
        world.addEntity(a); world.addEntity(b); world.activeCamera = a
        #expect(renderer.activeCamera === a)
        a.isEnabled = false; #expect(renderer.activeCamera === b)
        world.root.isEnabled = false; #expect(renderer.activeCamera == nil && renderer.physicsWorld.speed == 0)
        world.isPaused = true; world.root.isEnabled = true
        #expect(renderer.node(for: world.root)?.isPaused == true)
        world.isPaused = false; a.isEnabled = true
        #expect(renderer.activeCamera === a && renderer.physicsWorld.speed == 1)
    }
    @Test func bodyAndOwnerActivationRemoveAndRebuildJoints() throws {
        let (_, renderer, _, b, owner) = PhysicsJointTests().fixture()
        let old = try #require(renderer.jointEntries[owner.id]?.joint)
        b.isEnabled = false
        #expect(renderer.jointEntries.isEmpty && old.bodyA.joints.isEmpty)
        renderer.flush(); #expect(owner.physicsJointStatus == .waitingForBodies)
        b.isEnabled = true; renderer.flush(); #expect(owner.physicsJointStatus == .active)
        owner.isEnabled = false; renderer.flush(); #expect(owner.physicsJointStatus == .disabled)
        owner.isEnabled = true; renderer.flush(); #expect(owner.physicsJointStatus == .active)
    }
    @Test func queuedContactsDoNotLeakIntoAReactivatedLifetime() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let a = Entity(), b = Entity(); world.addEntity(a); world.addEntity(b)
        var contacts = 0
        let subscription = world.subscribe(to: PhysicsEvents.ContactBegan.self) { _ in contacts += 1 }
        renderer.reportContact(between: renderer.node(for: a), and: renderer.node(for: b), began: true)
        a.isEnabled = false; a.isEnabled = true
        renderer.publishContacts(); #expect(contacts == 0)
        renderer.reportContact(between: renderer.node(for: a), and: renderer.node(for: b), began: true)
        renderer.publishContacts(); #expect(contacts == 1)
        withExtendedLifetime(subscription) {}
    }
    @Test func characterMovementRejectsDormantCharacters() {
        let world = World(), parent = Entity(), child = Entity(components: CharacterControllerComponent(shape: .circle(radius: 5)))
        parent.addChild(child); world.addEntity(parent); parent.isEnabled = false
        #expect(throws: CharacterMovementError.inactiveEntity) { try child.moveCharacter(by: [20, 0]) }
        #expect(child.position == .zero)
    }
    @Test func playbackSuspendsWithoutLosingItsRequestedStateOrPosition() throws {
        let world = World(), parent = Entity(), child = Entity(components: SpriteComponent(color: .red, size: [10, 10]))
        parent.addChild(child); world.addEntity(parent)
        let controller = try child.playAnimation(PlaybackTests().clip(), options: .init(repeatMode: .forever))
        world.update(deltaTime: 0.2); parent.isEnabled = false
        #expect(controller.state == .playing && !controller.isPlaying)
        world.update(deltaTime: 0.4); #expect(abs(controller.currentTime - 0.2) < 0.0001)
        parent.isEnabled = true; #expect(controller.isPlaying)
        world.update(deltaTime: 0.1); #expect(abs(controller.currentTime - 0.3) < 0.0001)
        controller.pause(); parent.isEnabled = false; parent.isEnabled = true
        #expect(controller.state == .paused && !controller.isPlaying)
    }
    @Test func voicesPauseImmediatelyAndRemainSuspendedWhenSceneSettingsChange() throws {
        let world = World(), parent = Entity(), child = Entity()
        parent.addChild(child); world.addEntity(parent); world.addSystem(PlaybackSystem.self)
        let voice = TestAudioVoice()
        let controller = AudioPlaybackController(entity: child, resource: AudioResource(name: "test", duration: 10, data: Data()),
            options: .init(), volume: 1, isPositional: false, voice: voice)
        child.addPlayback(controller); controller.synchronize()
        world.update(deltaTime: 0.5); #expect(voice.playing)
        parent.isEnabled = false
        #expect(!voice.playing && controller.state == .playing)
        world.timeScale = 2; world.update(deltaTime: 1)
        #expect(!voice.playing && controller.currentTime == 0.5)
        parent.isEnabled = true
        #expect(voice.playing && voice.rate == 2)
        controller.pause(); parent.isEnabled = false; parent.isEnabled = true
        #expect(!voice.playing && controller.state == .paused)
    }
    @Test func activationPreservesNativeActionsAndParticleStreams() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let entity = Entity(components: ParticleEmitterComponent.smoke())
        world.addEntity(entity)
        withAnimation(.linear(duration: 5)) { entity.position = [100, 0] }
        renderer.flush()
        let node = try #require(renderer.node(for: entity)), stream = try #require(node.childNode(withName: "__emitter"))
        entity.isEnabled = false
        #expect(node.isPaused && node.isHidden && node.hasActions())
        entity.isEnabled = true
        #expect(!node.isPaused && !node.isHidden && node.hasActions())
        #expect(node.childNode(withName: "__emitter") === stream)
    }
}

private enum PoolTestFailure: Error { case reset }

@MainActor @Suite struct EntityPoolTests {
    func prefab() -> PrefabResource {
        let root = Entity(name: "projectile", components: PhysicsBodyComponent(shape: .circle(radius: 5)))
        let child = Entity(name: "dormant-child"); child.isEnabled = false; root.addChild(child)
        return PrefabResource(root: root)
    }
    @Test func prewarmingReusesIdentityAndNodesAndHonorsCapacity() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let pool = try EntityPool(prefab: prefab(), scene: world, capacity: 2, prewarm: 2,
                                  onAcquire: { $0.position = [12, 30] }, onRelease: { $0.position = .zero })
        #expect(pool.availableCount == 2 && pool.leasedCount == 0)
        let first = try #require(try pool.acquire()), second = try #require(try pool.acquire())
        let node = try #require(renderer.node(for: first))
        #expect(first.position == [12, 30] && !first.children[0].isEnabled)
        #expect(try pool.acquire() == nil)
        #expect(try pool.release(first)); #expect(!first.isActive && first.position == .zero)
        #expect(try !pool.release(first))
        let again = try #require(try pool.acquire())
        #expect(again === first && renderer.node(for: again) === node && pool.totalCount == 2)
        #expect(pool.leasedEntities.map(\.id) == [first.id, second.id].sorted())
    }
    @Test func disabledPoolContainerSuspendsLeasesWithoutReleasingThem() throws {
        let world = World(), pool = try EntityPool(prefab: prefab(), scene: world, capacity: 1)
        let entity = try #require(try pool.acquire()); pool.container.isEnabled = false
        #expect(!entity.isActive && entity.isEnabled && pool.leasedCount == 1)
        pool.container.isEnabled = true; #expect(entity.isActive)
        try pool.removeAll(); #expect(entity.world == nil && pool.totalCount == 0)
        #expect(try pool.acquire() != nil)
    }
    @Test func jointedPrefabsReuseTheirReferencesAndResetRestFrames() throws {
        let world = World(), renderer = SpriteRenderer(world: world), template = Entity()
        let a = Entity(name: "pivot", components: PhysicsBodyComponent(shape: .circle(radius: 3), isDynamic: false))
        let b = Entity(name: "bob", components: PhysicsBodyComponent(shape: .circle(radius: 8)))
        b.position = [0, -40]
        let hinge = Entity(name: "hinge", components: PhysicsJointComponent(bodyA: a.id, bodyB: b.id, constraint: .spring()))
        template.addChild(a); template.addChild(b); template.addChild(hinge)
        let pool = try EntityPool(prefab: PrefabResource(root: template), scene: world, capacity: 1,
            onAcquire: { entity in entity.visit { $0.components[PhysicsJointComponent.self]?.rebind() } })
        let instance = try #require(try pool.acquire()); renderer.flush()
        let copyHinge = try #require(instance.findEntity(named: "hinge"))
        let first = try #require(renderer.jointEntries[copyHinge.id]?.joint)
        try pool.release(instance); #expect(renderer.jointEntries.isEmpty && first.bodyA.joints.isEmpty)
        let again = try #require(try pool.acquire { $0.position = [100, 100] }); renderer.flush()
        let second = try #require(renderer.jointEntries[copyHinge.id]?.joint)
        #expect(again === instance && second !== first)
        let pivot = try #require(instance.findEntity(named: "pivot"))
        #expect(second.bodyA === renderer.node(for: pivot)?.physicsBody)
        #expect(copyHinge.physicsJointStatus == .active)
    }
    @Test func resetFailuresDoNotLeakLeasesOrCapacity() throws {
        let world = World()
        let pool = try EntityPool(prefab: prefab(), scene: world, capacity: 1, onRelease: { _ in throw PoolTestFailure.reset })
        #expect(throws: PoolTestFailure.self) { try pool.acquire { _ in throw PoolTestFailure.reset } }
        #expect(pool.availableCount == 1 && pool.leasedCount == 0)
        let entity = try #require(try pool.acquire())
        #expect(throws: PoolTestFailure.self) { try pool.release(entity) }
        #expect(!entity.isActive && pool.availableCount == 1)
        #expect(try pool.acquire() === entity)
    }
    @Test func reentrancyForeignInstancesAndExternalRemovalAreHandled() throws {
        let world = World(), pool = try EntityPool(prefab: prefab(), scene: world, capacity: 1)
        let entity = try #require(try pool.acquire { _ in
            #expect(throws: EntityPoolError.reentrantOperation) { try pool.acquire() }
        })
        #expect(try !pool.release(Entity()))
        entity.removeFromParent(); #expect(pool.totalCount == 0)
        #expect(try pool.acquire() !== entity)
        pool.container.removeFromParent()
        #expect(throws: EntityPoolError.notInScene) { try pool.acquire() }
    }
    @Test(arguments: [false, true]) func releaseCancelsOldPlaybackParticlesAndAnimationCompletions(flushed: Bool) throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let pool = try EntityPool(prefab: prefab(), scene: world, capacity: 1)
        let entity = try #require(try pool.acquire())
        entity.components.set(SpriteComponent(color: .red, size: [10, 10]))
        let clip = try entity.playAnimation(PlaybackTests().clip(), options: .init(repeatMode: .forever))
        var particles = ParticleEmitterComponent.sparks(); particles.burst(30); entity.components.set(particles)
        var completed = false
        withAnimation(.linear(duration: 5)) { entity.position = [100, 0] } completion: { completed = true }
        if flushed { renderer.flush() }
        let node = try #require(renderer.node(for: entity))
        if flushed { #expect(node.hasActions() && node.childNode(withName: "__burst") != nil) }
        try pool.release(entity); let again = try #require(try pool.acquire()); renderer.flush()
        #expect(again === entity && clip.state == .stopped && !completed)
        #expect(!node.hasActions() && node.childNode(withName: "__burst") == nil)
        #expect(entity.components[PlaybackStorage.self] == nil)
    }
    @Test func invalidCapacityIsRejectedBeforeAddingAContainer() {
        let world = World()
        #expect(throws: EntityPoolError.invalidCapacity) { try EntityPool(prefab: prefab(), scene: world, capacity: 0) }
        #expect(throws: EntityPoolError.invalidCapacity) { try EntityPool(prefab: prefab(), scene: world, capacity: 1, prewarm: 2) }
        #expect(world.entities.isEmpty)
    }
}
