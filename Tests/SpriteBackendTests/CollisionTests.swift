import ECSCore
import Foundation
import SpriteKit
import SwiftUI
import Testing
@testable import SpriteBackend

@MainActor @Suite struct CollisionQueryTests {
    func entity(_ shape: CollisionShape, at position: SIMD2<Float>, group: CollisionGroup = .default) -> Entity {
        let entity = Entity(components: CollisionComponent(shape: shape, filter: .init(group: group)))
        entity.position = position; return entity
    }
    @Test func headlessQueriesSeeEditsImmediatelyAndSortDeterministically() {
        let world = World()
        let first = entity(.circle(radius: 2), at: [10, 0]), second = entity(.rectangle(size: [4, 4]), at: [20, 0])
        world.addEntity(second); world.addEntity(first)
        #expect(world.raycast(from: .zero, to: [100, 0], query: .all).map(\.entity.id) == [first.id, second.id])
        first.position = [30, 0]
        #expect(world.raycast(from: .zero, to: [100, 0]).first?.entity === second)
        second.components[CollisionComponent.self]?.isEnabled = false
        #expect(world.raycast(from: .zero, to: [100, 0]).first?.entity === first)
        first.removeFromParent()
        #expect(world.raycast(from: .zero, to: [100, 0]).isEmpty)
    }
    @Test func filtersAndExclusionsAreIndependentOfPhysicalResponse() {
        let world = World(), wall = CollisionGroup(rawValue: 1 << 4), bot = CollisionGroup(rawValue: 1 << 5)
        let a = entity(.circle(radius: 2), at: [10, 0], group: wall), b = entity(.circle(radius: 2), at: [20, 0], group: bot)
        b.components[CollisionComponent.self]?.filter.mask = .none
        world.addEntity(a); world.addEntity(b)
        #expect(world.raycast(from: .zero, to: [100, 0], filter: .init(mask: bot)).first?.entity === b)
        #expect(world.raycast(from: .zero, to: [100, 0], filter: .init(mask: bot, group: wall)).isEmpty)
        #expect(world.raycast(from: .zero, to: [100, 0], filter: .init(excluding: [a.id])).first?.entity === b)
        #expect(world.raycast(from: .zero, to: [100, 0], filter: .init(mask: .none)).isEmpty)
    }
    @Test func nestedTransformsOffsetsAndReflectionsUseSceneSpace() throws {
        let world = World(), parent = Entity()
        parent.position = [10, 20]; parent.rotation = .pi / 2; parent.scale = [-2, 3]
        world.root.position = [5, 0]
        let child = entity(.circle(radius: 1), at: [2, 0]); child.components[CollisionComponent.self]?.offset = [1, 0]
        parent.addChild(child); world.addEntity(parent)
        let hit = try #require(world.raycast(from: [15, 0], to: [15, 30]).first)
        #expect(hit.entity === child && abs(hit.position.y - 12) < 0.002)
        #expect(abs(hit.normal.y + 1) < 0.002)
    }
    @Test func bodyShapesAreQueryFallbacksAndExplicitCollidersOverrideThem() {
        let world = World(), entity = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 5)))
        entity.position = [10, 0]; world.addEntity(entity)
        #expect(abs(world.raycast(from: .zero, to: [20, 0]).first!.distance - 5) < 0.002)
        entity.components.set(CollisionComponent(shape: .rectangle(size: [2, 2])))
        #expect(abs(world.raycast(from: .zero, to: [20, 0]).first!.distance - 9) < 0.002)
        entity.components[CollisionComponent.self]?.isEnabled = false
        #expect(world.raycast(from: .zero, to: [20, 0]).isEmpty)
        entity.components.remove(CollisionComponent.self)
        #expect(!world.raycast(from: .zero, to: [20, 0]).isEmpty)
    }
    @Test func overlapsAndSweepsReturnEntityWitnesses() throws {
        let world = World(), wall = entity(.rectangle(size: [1, 100]), at: [50, 0])
        world.addEntity(wall)
        let hit = try #require(world.sweep(shape: .circle(radius: 2), from: .identity, to: [100, 0]).first)
        #expect(hit.entity === wall && abs(hit.distance - 47.5) < 0.002)
        #expect(world.overlaps(shape: .circle(radius: 2), transform: .init(tx: 50)).first?.entity === wall)
        #expect(world.overlaps(shape: .circle(radius: 2)).isEmpty)
    }
    @Test func collisionsRoundTripThroughWorldSnapshots() throws {
        let world = World(); SpriteRenderer.registerComponents()
        let original = entity(.polygon([[0, 0], [2, 0], [0, 2]]), at: [10, 0]); world.addEntity(original)
        let snapshot = try WorldSnapshot(data: world.snapshot().jsonData())
        world.restore(snapshot)
        #expect(world.entities[0].components[CollisionComponent.self] == original.components[CollisionComponent.self])
        #expect(!world.raycast(from: .zero, to: [20, 0]).isEmpty)
    }
}

@MainActor @Suite struct CollisionBackendTests {
    @Test func invisibleShapesAndParentCollidersControlInput() {
        let world = World(), renderer = SpriteRenderer(world: world)
        let parent = Entity(components: CollisionComponent(shape: .circle(radius: 5)), InputTargetComponent())
        let child = Entity(components: SpriteComponent(color: .red, size: [100, 100]))
        parent.addChild(child); world.addEntity(parent)
        #expect(renderer.inputTarget(at: .zero) === parent)
        #expect(renderer.inputTarget(at: CGPoint(x: 30, y: 0)) == nil)
        parent.components[CollisionComponent.self]?.isEnabled = false
        #expect(renderer.inputTarget(at: .zero) == nil)
    }
    @Test func inputUsesDisplayedTransformsWhileSceneQueriesUseModelTransforms() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let entity = Entity(components: CollisionComponent(shape: .circle(radius: 5)), InputTargetComponent())
        world.addEntity(entity)
        renderer.node(for: entity)?.position = CGPoint(x: 100, y: 0)
        #expect(renderer.inputTarget(at: CGPoint(x: 100, y: 0)) === entity)
        #expect(renderer.inputTarget(at: .zero) == nil)
        #expect(world.raycast(from: [-10, 0], to: [10, 0]).first?.entity === entity)
    }
    @Test func colliderEditsUpdatePhysicsAndRestoreFallbackWithoutLosingMotion() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let entity = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 5), categoryBitMask: 2, collisionBitMask: 4))
        world.addEntity(entity)
        let node = try #require(renderer.node(for: entity)); node.physicsBody?.velocity = CGVector(dx: 12, dy: 4)
        entity.components.set(CollisionComponent(shape: .rectangle(size: [4, 6]), offset: [2, 0], filter: .init(group: .init(rawValue: 8), mask: .init(rawValue: 16))))
        renderer.flush()
        let body = try #require(node.physicsBody)
        #expect(body.categoryBitMask == 8 && body.collisionBitMask == 16)
        #expect(abs(body.velocity.dx - 12) < 0.001)
        #expect(abs(Float(body.area) * 22500 - 24) < 0.01)
        entity.components.remove(CollisionComponent.self); renderer.flush()
        #expect(node.physicsBody?.categoryBitMask == 2 && node.physicsBody?.collisionBitMask == 4)
        #expect(abs((node.physicsBody?.velocity.dx ?? 0) - 12) < 0.001)
    }
    @Test func enablingAnInitiallyDisabledColliderRestoresPhysicsCopyBack() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let entity = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 5)), CollisionComponent(shape: .circle(radius: 3), isEnabled: false))
        world.addEntity(entity)
        let node = try #require(renderer.node(for: entity)); #expect(node.physicsBody == nil)
        entity.components[CollisionComponent.self]?.isEnabled = true; renderer.flush()
        #expect(node.physicsBody != nil)
        node.position = CGPoint(x: 10, y: 20); renderer.didSimulatePhysics()
        #expect(entity.position == [10, 20])
        entity.components[CollisionComponent.self]?.shape = .circle(radius: -1); renderer.flush()
        #expect(node.physicsBody == nil)
    }
}
