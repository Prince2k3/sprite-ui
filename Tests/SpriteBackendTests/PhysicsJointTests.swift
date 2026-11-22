import ECSCore
import Foundation
import SpriteKit
import Testing
@testable import SpriteBackend

@MainActor @Suite struct PhysicsJointTests {
    func fixture(_ constraint: PhysicsJointConstraint = .pin()) -> (World, SpriteRenderer, Entity, Entity, Entity) {
        let world = World(), renderer = SpriteRenderer(world: world)
        let a = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 3), isDynamic: false))
        let b = Entity(components: PhysicsBodyComponent(shape: .rectangle(size: [12, 30]), mass: 1))
        a.position = [0, 50]; b.position = [0, 20]
        let connection = Entity(components: PhysicsJointComponent(bodyA: a.id, bodyB: b.id, constraint: constraint))
        // Order deliberately differs from the joint's endpoint order.
        world.addEntity(connection); world.addEntity(b); world.addEntity(a); renderer.flush()
        return (world, renderer, a, b, connection)
    }
    @Test func allFiveKindsBindToTheReferencedBodiesAndProperties() throws {
        let cases: [PhysicsJointConstraint] = [
            .pin(anchor: [2, 0], angleLimits: -0.4...0.7, frictionTorque: 0.3, rotationSpeed: 1.5),
            .fixed(anchor: [1, 0]), .spring(frequency: 3, damping: 0.5),
            .sliding(axis: [0, 5], distanceLimits: -12...20), .limit(maxLength: 45)
        ]
        for constraint in cases {
            let (_, renderer, a, b, owner) = fixture(constraint)
            let joint = try #require(renderer.jointEntries[owner.id]?.joint)
            #expect(joint.bodyA === renderer.node(for: a)?.physicsBody)
            #expect(joint.bodyB === renderer.node(for: b)?.physicsBody)
            #expect(joint.bodyA.joints.contains(where: { $0 === joint }))
            #expect(owner.physicsJointStatus == .active)
            // SpriteKit returns native class-cluster objects. Their documented
            // Objective-C properties work, but Swift subclass casts need not.
            func number(_ key: String) throws -> Double {
                try #require(joint.value(forKey: key) as? NSNumber).doubleValue
            }
            switch constraint {
            case .pin:
                #expect(try number("shouldEnableLimits") == 1)
                #expect(try abs(number("lowerAngleLimit") + 0.4) < 0.0001 && abs(number("upperAngleLimit") - 0.7) < 0.0001)
                #expect(try abs(number("frictionTorque") - 0.3) < 0.0001 && abs(number("rotationSpeed") - 1.5) < 0.0001)
            case .fixed: break // Identity/body membership above verifies installation.
            case .spring:
                #expect(try abs(number("frequency") - 3) < 0.0001 && abs(number("damping") - 0.5) < 0.0001)
            case .sliding:
                #expect(try number("shouldEnableLimits") == 1)
                #expect(try abs(number("lowerDistanceLimit") + 12) < 0.0001 && abs(number("upperDistanceLimit") - 20) < 0.0001)
            case .limit: #expect(try abs(number("maxLength") - 45) < 0.0001)
            }
        }
    }
    @Test func missingEndpointsWaitAndNewRendererMirrorsExistingConnections() throws {
        let world = World()
        let a = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 3), isDynamic: false))
        let b = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 5)))
        let owner = Entity(components: PhysicsJointComponent(bodyA: a.id, bodyB: b.id, constraint: .pin()))
        world.addEntity(owner); #expect(owner.physicsJointStatus == .notRendered)
        let renderer = SpriteRenderer(world: world)
        #expect(owner.physicsJointStatus == .waitingForBodies)
        world.addEntity(a); renderer.flush(); #expect(owner.physicsJointStatus == .waitingForBodies)
        world.addEntity(b); renderer.flush(); #expect(owner.physicsJointStatus == .active)
        let other = World(), root = Entity()
        let c = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 3)))
        let d = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 3)))
        let connection = Entity(components: PhysicsJointComponent(bodyA: c.id, bodyB: d.id, constraint: .fixed()))
        root.addChild(connection); root.addChild(d); root.addChild(c); other.addEntity(root)
        let newRenderer = SpriteRenderer(world: other)
        #expect(connection.physicsJointStatus == .active)
        #expect(newRenderer.jointEntries.count == 1)
    }
    @Test func bodyReplacementAndColliderDisableRemoveOldNativeLinks() throws {
        let (_, renderer, a, b, owner) = fixture(.spring())
        let oldJoint = try #require(renderer.jointEntries[owner.id]?.joint), oldBody = try #require(renderer.node(for: b)?.physicsBody)
        b.components[PhysicsBodyComponent.self]?.shape = .circle(radius: 8); renderer.flush()
        let replacement = try #require(renderer.jointEntries[owner.id]?.joint)
        #expect(replacement !== oldJoint && replacement.bodyB !== oldBody && oldBody.joints.isEmpty)
        #expect(renderer.node(for: a)?.physicsBody?.joints.count == 1)
        b.components.set(CollisionComponent(shape: .circle(radius: 7), isEnabled: false)); renderer.flush()
        #expect(owner.physicsJointStatus == .waitingForBodies && renderer.jointEntries.isEmpty)
        #expect(replacement.bodyA.joints.isEmpty)
        b.components[CollisionComponent.self]?.isEnabled = true; renderer.flush()
        #expect(owner.physicsJointStatus == .active)
    }
    @Test func removalAndReaddingBodiesAndOwnersAreSafe() throws {
        let (world, renderer, a, b, owner) = fixture()
        let body = try #require(renderer.node(for: a)?.physicsBody)
        b.removeFromParent()
        #expect(renderer.jointEntries.isEmpty && body.joints.isEmpty)
        renderer.flush(); #expect(owner.physicsJointStatus == .waitingForBodies)
        world.addEntity(b); renderer.flush(); #expect(owner.physicsJointStatus == .active)
        owner.removeFromParent(); #expect(body.joints.isEmpty && renderer.jointEntries.isEmpty)
        world.addEntity(owner); renderer.flush(); #expect(owner.physicsJointStatus == .active)
        owner.components.remove(PhysicsJointComponent.self); renderer.flush()
        #expect(owner.physicsJointStatus == nil && body.joints.isEmpty)
    }
    @Test func removingAnAncestorDetachesItsJointsBeforeTheNativeTree() throws {
        let (world, renderer, a, b, owner) = fixture()
        let group = Entity(); world.addEntity(group); group.addChild(b); renderer.flush()
        let body = try #require(renderer.node(for: a)?.physicsBody)
        #expect(owner.physicsJointStatus == .active)
        group.removeFromParent()
        #expect(renderer.jointEntries.isEmpty && body.joints.isEmpty)
        renderer.flush(); #expect(owner.physicsJointStatus == .waitingForBodies)
    }
    @Test func ordinaryMotionAndUnrelatedBodyEditsDoNotRecreateJoints() throws {
        let (_, renderer, a, b, owner) = fixture()
        let joint = try #require(renderer.jointEntries[owner.id]?.joint)
        renderer.node(for: b)?.position = CGPoint(x: 15, y: 25); renderer.didSimulatePhysics(); renderer.flush()
        b.components[PhysicsBodyComponent.self]?.friction = 0.9; a.position = [5, 50]; renderer.flush()
        #expect(renderer.jointEntries[owner.id]?.joint === joint)
    }
    @Test func severalConnectionsCanShareABodyAndDisableIndependently() throws {
        let (world, renderer, a, b, owner) = fixture()
        let other = Entity(components: PhysicsJointComponent(bodyA: a.id, bodyB: b.id, constraint: .limit(maxLength: 60)))
        world.addEntity(other); renderer.flush()
        #expect(renderer.jointEntries.count == 2)
        let second = try #require(renderer.jointEntries[other.id]?.joint)
        owner.components[PhysicsJointComponent.self]?.isEnabled = false; renderer.flush()
        #expect(owner.physicsJointStatus == .disabled && renderer.jointEntries.count == 1)
        #expect(renderer.jointEntries[other.id]?.joint === second)
        owner.components[PhysicsJointComponent.self]?.isEnabled = true; renderer.flush()
        #expect(renderer.jointEntries.count == 2)
    }
    @Test func invalidModelsFailClosedAndCanBeCorrected() throws {
        let (_, renderer, a, b, owner) = fixture()
        for invalid: PhysicsJointConstraint in [.spring(frequency: -.infinity), .limit(maxLength: 0), .pin(frictionTorque: -1), .sliding(axis: .zero), .fixed(anchor: [.nan, 0])] {
            owner.components[PhysicsJointComponent.self]?.constraint = invalid; renderer.flush()
            #expect(owner.physicsJointStatus == .invalidConfiguration && renderer.jointEntries.isEmpty)
        }
        owner.components[PhysicsJointComponent.self]?.constraint = .pin()
        owner.components[PhysicsJointComponent.self]?.bodyB = a.id; renderer.flush()
        #expect(owner.physicsJointStatus == .invalidBodies)
        owner.components[PhysicsJointComponent.self]?.bodyB = b.id
        b.components[PhysicsBodyComponent.self]?.isDynamic = false; renderer.flush()
        #expect(owner.physicsJointStatus == .invalidBodies)
        b.components[PhysicsBodyComponent.self]?.isDynamic = true; renderer.flush()
        #expect(owner.physicsJointStatus == .active)
        b.components.remove(PhysicsBodyComponent.self); renderer.flush()
        #expect(owner.physicsJointStatus == .waitingForBodies)
    }
    @Test func unsupportedTransformsAndNestedBodyPairsAreRejectedWithoutCrashing() throws {
        let (_, renderer, a, b, owner) = fixture()
        b.scale = [0, 1]; renderer.flush()
        #expect(owner.physicsJointStatus == .invalidTransform && renderer.jointEntries.isEmpty)
        b.scale = [-1, 1]; renderer.flush(); #expect(owner.physicsJointStatus == .invalidTransform)
        b.scale = [1, 1]; renderer.flush(); #expect(owner.physicsJointStatus == .active)
        a.addChild(b); renderer.flush(); #expect(owner.physicsJointStatus == .invalidBodies)
    }
    @Test func referenceFramesSurviveSnapshotsRebuildsAndParameterEdits() throws {
        let (world, renderer, _, b, owner) = fixture(.spring(frequency: 2, damping: 0.1))
        let initial = try JSONEncoder().encode(try #require(owner.components[PhysicsJointComponent.self]))
        let firstJSON = try #require(JSONSerialization.jsonObject(with: initial) as? [String: Any])
        #expect(firstJSON["referencePose"] != nil)
        b.position = [35, -30]; b.rotation = 0.6
        b.components[PhysicsBodyComponent.self]?.velocity = [20, 30]; renderer.flush()
        let velocity = renderer.node(for: b)!.physicsBody!.velocity
        owner.components[PhysicsJointComponent.self]?.constraint = .spring(frequency: 5, damping: 0.4); renderer.flush()
        #expect(b.position == [35, -30] && abs(renderer.node(for: b)!.position.x - 35) < 0.001)
        #expect(abs(renderer.node(for: b)!.physicsBody!.velocity.dx - velocity.dx) < 0.001)
        let data = try world.snapshot().jsonData()
        let saved = try WorldSnapshot(data: data); world.restore(saved); renderer.flush()
        let restored = try #require(world.entity(withID: owner.id))
        #expect(restored.physicsJointStatus == .active && renderer.jointEntries.count == 1)
        let restoredJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored.components[PhysicsJointComponent.self]!)) as? [String: Any])
        #expect(NSDictionary(dictionary: firstJSON["referencePose"] as! [String: Any]).isEqual(to: restoredJSON["referencePose"] as! [String: Any]))
        #expect(world.entity(withID: b.id)?.position == [35, -30])
    }
    @Test func rebindAndAnchorChangesCaptureNewFramesButTuningKeepsTheOldOne() throws {
        let (_, renderer, _, b, owner) = fixture(.spring())
        let old = try JSONEncoder().encode(owner.components[PhysicsJointComponent.self]!)
        b.position = [100, -60]; renderer.flush()
        owner.components[PhysicsJointComponent.self]?.rebind(); renderer.flush()
        let rebound = try JSONEncoder().encode(owner.components[PhysicsJointComponent.self]!)
        // Compare decoded values rather than JSON key order.
        #expect(try JSONDecoder().decode(PhysicsJointComponent.self, from: old) != JSONDecoder().decode(PhysicsJointComponent.self, from: rebound))
        b.position = [120, -70]; renderer.flush()
        owner.components[PhysicsJointComponent.self]?.constraint = .spring(anchorA: [1, 0]); renderer.flush()
        #expect(owner.physicsJointStatus == .active)
    }
    @Test func endpointChangesRebindAndPauseDoesNotRecreateNativeConnections() throws {
        let (world, renderer, _, b, owner) = fixture(.spring())
        let oldJoint = try #require(renderer.jointEntries[owner.id]?.joint)
        world.isPaused = true; world.timeScale = 0.5; renderer.flush()
        #expect(renderer.jointEntries[owner.id]?.joint === oldJoint)
        #expect(renderer.physicsWorld.speed == 0)
        let replacement = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 5)))
        replacement.position = [20, -10]; world.addEntity(replacement)
        owner.components[PhysicsJointComponent.self]?.bodyB = replacement.id; renderer.flush()
        let newJoint = try #require(renderer.jointEntries[owner.id]?.joint)
        #expect(newJoint !== oldJoint && newJoint.bodyB === renderer.node(for: replacement)?.physicsBody)
        #expect(renderer.node(for: b)?.physicsBody?.joints.isEmpty == true)
        world.isPaused = false; renderer.flush()
        #expect(renderer.physicsWorld.speed == 0.5 && renderer.jointEntries[owner.id]?.joint === newJoint)
        let otherWorld = World(), foreignBody = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 2)))
        otherWorld.addEntity(foreignBody)
        owner.components[PhysicsJointComponent.self]?.bodyB = foreignBody.id; renderer.flush()
        #expect(owner.physicsJointStatus == .waitingForBodies && renderer.jointEntries.isEmpty)
    }
    @Test func malformedSavedReferenceAndMappedAnchorOverflowNeverReachNativeFactories() throws {
        let (_, renderer, a, _, owner) = fixture()
        let encoded = try JSONEncoder().encode(owner.components[PhysicsJointComponent.self]!)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var reference = try #require(json["referencePose"] as? [String: Any])
        var pose = try #require(reference["a"] as? [String: Any]); pose["a"] = 0; pose["b"] = 0
        reference["a"] = pose; json["referencePose"] = reference
        let invalid = try JSONDecoder().decode(PhysicsJointComponent.self, from: JSONSerialization.data(withJSONObject: json))
        owner.components.set(invalid); renderer.flush()
        #expect(owner.physicsJointStatus == .invalidTransform && renderer.jointEntries.isEmpty)
        a.scale = [4, 4]
        owner.components[PhysicsJointComponent.self]?.constraint = .fixed(anchor: [.greatestFiniteMagnitude, 0]); renderer.flush()
        #expect(owner.physicsJointStatus == .invalidConfiguration && renderer.jointEntries.isEmpty)
    }
    @Test func coincidentSpringAndLimitAnchorsAreSafeAndRoundTripThroughAFile() throws {
        let (world, renderer, a, b, owner) = fixture(.spring())
        b.position = a.position; renderer.flush()
        owner.components[PhysicsJointComponent.self]?.rebind(); renderer.flush()
        #expect(owner.physicsJointStatus == .active)
        owner.components[PhysicsJointComponent.self]?.constraint = .limit(maxLength: 20); renderer.flush()
        #expect(owner.physicsJointStatus == .active)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try world.snapshot().write(to: url)
        world.restore(try WorldSnapshot(contentsOf: url)); renderer.flush()
        let loaded = try #require(world.entity(withID: owner.id))
        #expect(loaded.physicsJointStatus == .active)
        let joint = try #require(renderer.jointEntries[loaded.id]?.joint)
        #expect(joint.bodyA === renderer.node(for: try #require(world.entity(withID: a.id)))?.physicsBody)
        #expect(joint.bodyB === renderer.node(for: try #require(world.entity(withID: b.id)))?.physicsBody)
    }
    @Test func sceneAndLocalTransformsArePreservedWhileBindingNestedBodies() throws {
        let world = World(), renderer = SpriteRenderer(world: world), group = Entity()
        group.position = [30, 10]; group.rotation = 0.3; group.scale = [2, 2]
        world.addEntity(group)
        let a = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 2), isDynamic: false))
        let b = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 5)))
        a.position = [10, 30]; b.position = [10, -30]; group.addChild(a); group.addChild(b)
        let owner = Entity(components: PhysicsJointComponent(bodyA: a.id, bodyB: b.id, constraint: .spring(anchorA: [1, 0], anchorB: [-1, 0])))
        world.addEntity(owner); renderer.flush()
        #expect(owner.physicsJointStatus == .active)
        #expect(renderer.node(for: a)?.position == CGPoint(x: 10, y: 30))
        #expect(renderer.node(for: b)?.position == CGPoint(x: 10, y: -30))
        group.scale = [2, 1]; b.rotation = 0.5; renderer.flush()
        #expect(owner.physicsJointStatus == .invalidTransform)
    }
}
