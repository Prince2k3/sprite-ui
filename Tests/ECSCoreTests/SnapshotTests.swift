@testable import ECSCore
import Foundation
import Testing

private struct SavedHealth: Component, Codable, Equatable { var hp: Int }
private struct Inventory: Component, Codable, Equatable { var items: [String] }
private struct Scratch: Component, Equatable { var note: String }   // not Codable: never saved

@MainActor @Suite struct SnapshotTests {
    init() {
        SavedHealth.registerComponent()
        Inventory.registerComponent(named: "inventory")
    }

    private func makeWorld() -> (World, Entity, Entity) {
        let world = World()
        let hero = Entity(name: "hero", components: SavedHealth(hp: 3), Scratch(note: "temp"))
        hero.transform = Transform(translation: [10, 20], rotation: 0.5, scale: [2, 2], zPosition: 4)
        let bag = Entity(name: "bag", components: Inventory(items: ["key", "map"]), InputTargetComponent())
        hero.addChild(bag)
        world.addEntity(hero)
        world.addEntity(Entity(name: "rock"))
        return (world, hero, bag)
    }

    @Test func keepsHierarchyAndRegisteredComponents() throws {
        let (world, hero, _) = makeWorld()
        let snapshot = try WorldSnapshot(data: world.snapshot().jsonData())
        #expect(snapshot.entities.map(\.name) == ["hero", "rock"])
        #expect(snapshot.entityCount == 3)

        let savedHero = try #require(snapshot.entities.first)
        #expect(savedHero.id == hero.id)
        #expect(savedHero[SavedHealth.self] == SavedHealth(hp: 3))
        #expect(savedHero[Transform.self] == hero.transform)
        #expect(savedHero[Scratch.self] == nil)
        let savedBag = try #require(savedHero.children.first)
        #expect(savedBag[Inventory.self]?.items == ["key", "map"])
        #expect(savedBag[InputTargetComponent.self]?.isEnabled == true)
    }

    @Test func usesRegisteredNamesAndSortedKeys() throws {
        let (world, _, _) = makeWorld()
        let json = try #require(String(data: world.snapshot().jsonData(), encoding: .utf8))
        #expect(json.contains("\"type\":\"inventory\""))
        #expect(json.contains("\"type\":\"ECSCore.Transform\""))
        #expect(!json.contains("Scratch"))
        #expect(try world.snapshot().jsonData() == world.snapshot().jsonData())
        #expect(ComponentRegistry.name(of: Inventory.self) == "inventory")
        #expect(!ComponentRegistry.isRegistered(Scratch.self))
    }

    @Test func skipsComponentsItDoesNotKnow() throws {
        let json = """
        {"version":1,"entities":[{"id":9,"name":"ghost","components":[
          {"type":"SomeOtherApp.Mystery","value":{"x":1}},
          {"type":"ECSCore.Transform","value":{"translation":[1,2],"rotation":0,"scale":[1,1],"zPosition":0}}
        ]}]}
        """
        let snapshot = try WorldSnapshot(data: Data(json.utf8))
        let ghost = try #require(snapshot.entities.first)
        #expect(ghost.components.count == 1)
        #expect(ghost[Transform.self]?.translation == [1, 2])
    }

    @Test func restoreReplacesTheWorldKeepingIDs() throws {
        let (world, hero, bag) = makeWorld()
        let saved = world.snapshot()

        hero.components[SavedHealth.self]?.hp = 0
        hero.position = [99, 99]
        world.addEntity(Entity(name: "added later"))

        let restored = world.restore(saved)
        #expect(world.entities.map(\.name) == ["hero", "rock"])
        #expect(hero.world == nil)                               // the old objects are gone

        let newHero = try #require(world.entity(withID: hero.id))
        #expect(newHero !== hero && restored[hero.id] === newHero)
        #expect(newHero.components[SavedHealth.self] == SavedHealth(hp: 3))
        #expect(newHero.position == [10, 20])
        #expect(newHero.components[Scratch.self] == nil)
        let newBag = try #require(newHero.findEntity(named: "bag"))
        #expect(newBag.id == bag.id && newBag.parent === newHero)
        #expect(world.allEntities.count == 3)

        // New entities never reuse a restored ID.
        #expect(Entity().id > bag.id)
    }

    @Test func takenIDsGetNewOnes() throws {
        let world = World()
        let twin = EntitySnapshot(id: 500, name: "twin")
        let rootID = EntitySnapshot(id: world.root.id, name: "clash")
        let restored = world.restore(WorldSnapshot(entities: [twin, twin, rootID]))
        let ids = world.entities.map(\.id)
        #expect(ids.first == 500)
        #expect(Set(ids).count == 3 && !ids.contains(world.root.id))
        #expect(restored[world.root.id]?.name == "clash")
    }

    @Test func makeEntityGivesFreshCopies() {
        let (_, hero, _) = makeWorld()
        let copy = hero.snapshot().makeEntity()
        #expect(copy.id != hero.id)
        #expect(copy.components[SavedHealth.self] == SavedHealth(hp: 3))
        #expect(copy.children.map(\.name) == ["bag"])
    }

    @Test func leavesOutFilteredEntities() {
        let (world, _, _) = makeWorld()
        #expect(world.snapshot(including: { $0.name != "rock" }).entities.map(\.name) == ["hero"])
    }

    @Test func writesAndReadsFiles() throws {
        let (world, hero, _) = makeWorld()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try world.snapshot().write(to: url)
        let other = World()
        other.restore(try WorldSnapshot(contentsOf: url))
        #expect(other.entity(withID: hero.id)?.components[SavedHealth.self] == SavedHealth(hp: 3))
    }
}
