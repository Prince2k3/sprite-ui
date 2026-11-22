import ECSCore
import Foundation
import SpriteKit
import SwiftUI
import Testing
@testable import SpriteBackend

@MainActor @Suite struct PrefabTests {
    func mechanism() -> Entity {
        let root = Entity(name: "pendulum")
        let pivot = Entity(name: "pivot", components: PhysicsBodyComponent(shape: .circle(radius: 3), isDynamic: false))
        pivot.position = [0, 80]
        let bob = Entity(name: "bob", components: PhysicsBodyComponent(shape: .circle(radius: 10), mass: 1), SpriteComponent(color: .cyan, size: [20, 20]))
        bob.position = [0, 10]
        let joint = Entity(name: "joint", components: PhysicsJointComponent(bodyA: pivot.id, bodyB: bob.id, constraint: .spring(frequency: 2, damping: 0.2)))
        let camera = Entity(name: "camera", components: CameraComponent(target: .entity(bob.id), isActive: false))
        root.addChild(joint); root.addChild(camera); root.addChild(bob); root.addChild(pivot)
        return root
    }
    @Test func instancesHaveIndependentBodiesJointsAndCameraReferences() throws {
        let source = mechanism(), prefab = PrefabResource(root: source)
        let a = prefab.instantiate(), b = prefab.instantiate()
        a.position = [-100, 0]; b.position = [100, 0]
        let world = World(), renderer = SpriteRenderer(world: world)
        world.addEntity(a); world.addEntity(b); renderer.flush()
        for instance in [a, b] {
            let bob = try #require(instance.findEntity(named: "bob")), pivot = try #require(instance.findEntity(named: "pivot"))
            let joint = try #require(instance.findEntity(named: "joint")), camera = try #require(instance.findEntity(named: "camera"))
            #expect(joint.components[PhysicsJointComponent.self]?.bodyA == pivot.id && joint.components[PhysicsJointComponent.self]?.bodyB == bob.id)
            #expect(camera.components[CameraComponent.self]?.target == .entity(bob.id))
            #expect(joint.physicsJointStatus == .active)
            #expect(renderer.jointEntries[joint.id]?.joint.bodyB === renderer.node(for: bob)?.physicsBody)
        }
        #expect(renderer.jointEntries.count == 2 && prefab.entityCount == 5)
        a.findEntity(named: "joint")?.components[PhysicsJointComponent.self]?.isEnabled = false; renderer.flush()
        #expect(b.findEntity(named: "joint")?.physicsJointStatus == .active && renderer.jointEntries.count == 1)
        #expect(source.world == nil)
    }
    @Test func capturingFreezesTheTemplateAndSharesImmutableTextureResources() throws {
        let texture = TextureResource(image: SpriteImage(width: 1, height: 1, pixels: [255, 0, 0, 255]))
        let source = Entity(components: SpriteComponent(texture: texture, size: [20, 20]))
        let prefab = PrefabResource(root: source)
        source.components[SpriteComponent.self]?.size = [100, 100]
        let first = prefab.instantiate(), second = prefab.instantiate()
        first.components[SpriteComponent.self]?.opacity = 0.2
        #expect(second.components[SpriteComponent.self]?.size == [20, 20])
        #expect(second.components[SpriteComponent.self]?.opacity == 1)
        #expect(first.components[SpriteComponent.self]?.texture?.id == texture.id && second.components[SpriteComponent.self]?.texture?.id == texture.id)
    }
    @Test func namedCameraTargetsInsideTheSubtreeBecomeInstanceIDs() throws {
        let source = mechanism(); source.findEntity(named: "camera")?.components[CameraComponent.self]?.target = .named("bob")
        let copy = source.clone()
        #expect(copy.findEntity(named: "camera")?.components[CameraComponent.self]?.target == .entity(copy.findEntity(named: "bob")!.id))
        source.findEntity(named: "camera")?.components[CameraComponent.self]?.target = .named("external")
        #expect(source.clone().findEntity(named: "camera")?.components[CameraComponent.self]?.target == .named("external"))
    }
    @Test func runtimePlaybackAndHistoricalRequestsAreNotCopied() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let source = Entity(components: SpriteComponent(color: .cyan, size: [10, 10]))
        let texture = TextureResource(image: SpriteImage(width: 1, height: 1, pixels: [255, 255, 255, 255]))
        let clip = try AnimationResource(frames: [texture], framesPerSecond: 1)
        world.addEntity(source)
        let playback = try source.playAnimation(clip, options: .init(repeatMode: .forever))
        var emitter = ParticleEmitterComponent.sparks(); emitter.burst(5); source.components.set(emitter)
        var audio = AudioComponent(url: nil); audio.play(); source.components.set(audio); renderer.flush()
        let copy = source.clone()
        #expect(!copy.components.has(PlaybackStorage.self) && !copy.components.has(LegacyAudioPlaybackState.self))
        #expect(copy.components[ParticleEmitterComponent.self]?.burstID == 0 && copy.components[AudioComponent.self]?.playCount == 0)
        world.addEntity(copy); copy.stopAllPlayback()
        #expect(playback.isPlaying)
    }
    @Test func boundJointsRebaseSavedFramesWhenACloneIsPlacedAndRotated() throws {
        let world = World(), renderer = SpriteRenderer(world: world), group = Entity()
        group.position = [40, 60]; group.rotation = 0.3; world.addEntity(group)
        let source = mechanism(); source.position = [20, 10]; group.addChild(source); renderer.flush()
        // Freeze a stretched spring; its original 70-point rest frame must survive.
        source.findEntity(named: "bob")?.position = [0, -40]; renderer.flush()
        let prefab = PrefabResource(root: source), copy = prefab.instantiate()
        copy.position = [-100, 0]; copy.rotation = .pi / 2; world.addEntity(copy); renderer.flush()
        let joint = try #require(copy.findEntity(named: "joint"))
        #expect(joint.physicsJointStatus == .active)
        let encoded = try JSONEncoder().encode(joint.components[PhysicsJointComponent.self]!)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let reference = try #require(json["referencePose"] as? [String: Any])
        #expect((reference["space"] as? NSNumber)?.uint64Value == copy.id)
        let a = try #require(reference["a"] as? [String: Any]), b = try #require(reference["b"] as? [String: Any])
        #expect(abs((a["ty"] as! Double) - (b["ty"] as! Double) - 70) < 0.01)
        #expect(copy.findEntity(named: "bob")?.position == [0, -40])
        // Replacing a body reconstructs from that same instance-relative rest frame.
        copy.findEntity(named: "bob")?.components[PhysicsBodyComponent.self]?.shape = .circle(radius: 12); renderer.flush()
        #expect(joint.physicsJointStatus == .active)
    }
    @Test func fileResourcesCacheLoadsAndRetainExistingHandlesAfterClearing() async throws {
        let source = mechanism(), prefab = PrefabResource(root: source), library = ResourceLibrary()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".prefab")
        defer { try? FileManager.default.removeItem(at: url) }
        try prefab.write(to: url)
        async let first = library.prefab(contentsOf: url)
        async let second = library.prefab(contentsOf: url)
        let (a, b) = try await (first, second)
        #expect(a === b && library.cachedResourceCount == 1)
        let copy = a.instantiate()
        #expect(copy.findEntity(named: "joint")?.components[PhysicsJointComponent.self]?.bodyB == copy.findEntity(named: "bob")?.id)
        library.removeAllCachedResources(); #expect(library.cachedResourceCount == 0)
        #expect(a.instantiate().children.count == 4)
        let reloaded = try await library.prefab(contentsOf: url)
        #expect(reloaded !== a)
    }
    @Test func missingMalformedAndDuplicateIDResourcesFailAndCanBeRetried() async throws {
        let library = ResourceLibrary()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".prefab")
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: ResourceLoadingError.unreadable(url)) { try await library.prefab(contentsOf: url) }
        for text in ["junk", "{\"version\":9,\"root\":{\"id\":1}}", "{\"version\":1,\"root\":{\"id\":1,\"children\":[{\"id\":1}]}}"] {
            try Data(text.utf8).write(to: url)
            await #expect(throws: ResourceLoadingError.unreadable(url)) { try await library.prefab(contentsOf: url) }
        }
        try PrefabResource(root: mechanism()).write(to: url)
        #expect(try await library.prefab(contentsOf: url).entityCount == 5)
    }
    @Test func restoreRemapsJointsAndCameraWhenASavedIDConflictsWithTheWorldRoot() throws {
        let world = World(), renderer = SpriteRenderer(world: world), first = world.root.id
        let pivot = EntitySnapshot(id: first, name: "pivot", components: [PhysicsBodyComponent(shape: .circle(radius: 3), isDynamic: false)])
        let bob = EntitySnapshot(id: first + 1, name: "bob", components: [Transform(translation: [0, -30]), PhysicsBodyComponent(shape: .circle(radius: 5))])
        let joint = EntitySnapshot(id: first + 2, name: "joint", components: [PhysicsJointComponent(bodyA: first, bodyB: first + 1, constraint: .pin())])
        let camera = EntitySnapshot(id: first + 3, name: "camera", components: [CameraComponent(target: .entity(first), isActive: false)])
        let restored = world.restore(WorldSnapshot(entities: [joint, camera, pivot, bob])); renderer.flush()
        let restoredPivot = try #require(restored[first]), restoredJoint = try #require(restored[first + 2])
        #expect(restoredPivot.id != first)
        #expect(restoredJoint.components[PhysicsJointComponent.self]?.bodyA == restoredPivot.id)
        #expect(restoredJoint.physicsJointStatus == .active)
        #expect(restored[first + 3]?.components[CameraComponent.self]?.target == .entity(restoredPivot.id))
        #expect(Set(world.allEntities.map(\.id)).count == 4)
    }
    @Test func sceneFilesCanBeCachedAsPrefabs() async throws {
        let scene = SKScene(size: CGSize(width: 100, height: 100)); scene.name = "sample"
        let sprite = SKSpriteNode(color: .red, size: CGSize(width: 10, height: 10)); sprite.name = "sprite"; scene.addChild(sprite)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sks")
        defer { try? FileManager.default.removeItem(at: url) }
        try NSKeyedArchiver.archivedData(withRootObject: scene, requiringSecureCoding: false).write(to: url)
        let prefab = try await ResourceLibrary().prefab(contentsOf: url)
        #expect(prefab.entityCount == 2 && prefab.instantiate().findEntity(named: "sprite")?.components[SpriteComponent.self] != nil)
    }
}
