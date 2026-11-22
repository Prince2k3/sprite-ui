// Run after `swift build` from the package root:
// swiftc -parse-as-library -target arm64-apple-macosx15.0 -I .build/out/Products/Debug Demo/make-prefab.swift -L .build/out/Products/Debug -lSpriteUI -o /tmp/make-prefab
// /tmp/make-prefab Demo/SpriteUIDemo/Pendulum.prefab
import SpriteUI
import SwiftUI
import Foundation

@main struct GeneratePrefab {
    @MainActor static func main() throws {
        let root = Entity(name: "Pendulum", components: InputTargetComponent(), CollisionComponent(shape: .rectangle(size: [100, 140]), offset: [0, -50], filter: .init(group: .init(rawValue: 8), mask: .none)))
        let pivot = Entity(name: "pivot", components: PhysicsBodyComponent(shape: .circle(radius: 3), isDynamic: false, categoryBitMask: 4, collisionBitMask: 0), SpriteComponent(color: .orange, size: [8, 8]))
        let rod = Entity(name: "rod", components: PhysicsBodyComponent(shape: .rectangle(size: [10, 60]), mass: 0.5, linearDamping: 0.03, categoryBitMask: 2, collisionBitMask: 0), SpriteComponent(color: .cyan, size: [10, 60]))
        rod.position = [0, -30]
        let bob = Entity(name: "bob", components: PhysicsBodyComponent(shape: .circle(radius: 10), mass: 0.5, categoryBitMask: 2, collisionBitMask: 0), SpriteComponent(color: .mint, size: [20, 20]))
        bob.position = [20, -95]
        let hinge = Entity(name: "hinge", components: PhysicsJointComponent(bodyA: pivot.id, bodyB: rod.id, constraint: .pin()))
        let spring = Entity(name: "spring", components: PhysicsJointComponent(bodyA: rod.id, bodyB: bob.id, constraint: .spring(anchorA: [0, -30], frequency: 2, damping: 0.2)), SpriteComponent(color: .yellow, size: [1, 2]))
        let camera = Entity(name: "observer", components: CameraComponent(target: .entity(bob.id), isActive: false))
        for child in [pivot, rod, bob, hinge, spring, camera] { root.addChild(child) }
        let world = World(), renderer = SpriteRenderer(world: world)
        world.addEntity(root); renderer.flush()
        try PrefabResource(root: root, name: "Pendulum").write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
