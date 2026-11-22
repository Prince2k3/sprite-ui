import SpriteUI
import Foundation
import Testing

@MainActor @Suite struct CloneReferenceTests {
    @Test func allEntitySteeringTargetsRemapInsideNestedGoalGroups() throws {
        let root = Entity(), target = Entity(name: "target"), follower = Entity(name: "follower"), external = Entity()
        root.addChild(target); root.addChild(follower)
        follower.components.set(SteeringComponent(maxSpeed: 100, maxForce: 300, goals: [
            .group("nested", [SteeringGoal(.seek(.entity(target.id))), SteeringGoal(.flee(.entity(target.id))), SteeringGoal(.arrive(.entity(target.id))), SteeringGoal(.pursue(target.id)), SteeringGoal(.evade(target.id))]),
            SteeringGoal(.seek(.entity(external.id))), SteeringGoal(.seek(.point([3, 4])))
        ]))
        let copy = root.clone(), copiedTarget = try #require(copy.findEntity(named: "target"))
        let steering = try #require(copy.findEntity(named: "follower")?.components[SteeringComponent.self])
        guard case .group(let group) = steering.goals[0].behavior else { Issue.record("Missing group"); return }
        #expect(group.map(\.behavior) == [.seek(.entity(copiedTarget.id)), .flee(.entity(copiedTarget.id)), .arrive(.entity(copiedTarget.id)), .pursue(copiedTarget.id), .evade(copiedTarget.id)])
        #expect(steering.goals[1].behavior == .seek(.entity(external.id)) && steering.goals[2].behavior == .seek(.point([3, 4])))
        #expect(follower.components[SteeringComponent.self]?.goals[0].behavior != steering.goals[0].behavior)
    }
    @Test func prefabFilesPreserveInfiniteGoalDefaultsAndRemapTargets() async throws {
        SteeringComponent.registerComponent()
        let root = Entity(), target = Entity(name: "target"), follower = Entity(name: "follower")
        root.addChild(target); root.addChild(follower)
        follower.components.set(SteeringComponent(maxSpeed: 100, maxForce: 300, goals: [SteeringGoal(.flee(.entity(target.id)))]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".prefab")
        defer { try? FileManager.default.removeItem(at: url) }
        try PrefabResource(root: root).write(to: url)
        let resource = try await ResourceLibrary().prefab(contentsOf: url), copy = resource.instantiate()
        #expect(copy.findEntity(named: "follower")?.components[SteeringComponent.self]?.goals[0].behavior == .flee(.entity(copy.findEntity(named: "target")!.id)))
        let world = World(); world.addEntity(root)
        let snapshot = try WorldSnapshot(data: world.snapshot().jsonData())
        #expect(snapshot.entities[0].children[1][SteeringComponent.self]?.goals[0].behavior == .flee(.entity(target.id)))
    }
}
