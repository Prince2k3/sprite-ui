import Foundation
import SpriteUI
import Testing

private struct ReplaySavedValue: Component, Codable, Equatable { var value: Int }
private struct ReplayRootRuntime: Component { var value: Int }
private struct ReplayControllerReference: Component {
    let controller: InputReplayController
    @MainActor func cloned() -> Self? { nil }
}

@MainActor @Suite struct InputReplayWorldTests {
    private func fixture() -> (World, InputReplayController, Entity) {
        ReplaySavedValue.registerComponent()
        let world = World()
        world.fixedStep = .init(stepsPerSecond: 20)
        let entity = Entity(name: "saved", components: ReplaySavedValue(value: 7))
        let child = Entity(name: "child", components: ReplaySavedValue(value: 3))
        entity.addChild(child)
        entity.position = [8, 9]
        world.root.position = [10, -5]
        world.addEntity(entity)
        world.random = SeededGenerator(seed: 42)
        for _ in 0..<7 { _ = world.random.next() }
        return (world, InputReplayController(world: world, input: InputController()), entity)
    }

    private func startingTape(_ controller: InputReplayController) throws -> InputRecording {
        try controller.startRecording()
        try controller.stop()
        return try #require(controller.recording)
    }

    @Test func defaultProviderRestoresEntitiesRootPoseAndFullAdvancedRandomState() throws {
        let (world, controller, saved) = fixture()
        let expectedRandom = world.random
        let savedID = saved.id
        world.resources.set(ReplayRootRuntime(value: 1))
        let tape = try startingTape(controller)
        world.resources.set(ReplayRootRuntime(value: 99))
        world.removeEntity(saved)
        world.addEntity(Entity(name: "replacement"))
        world.root.position = [-99, -99]
        world.random = SeededGenerator(seed: 88)

        try controller.startPlayback(tape, paused: true)

        let restored = try #require(world.entity(withID: savedID))
        #expect(restored !== saved && restored.name == "saved")
        #expect(restored.position == [8, 9])
        #expect(restored.components[ReplaySavedValue.self] == ReplaySavedValue(value: 7))
        #expect(restored.children.first?.name == "child")
        #expect(world.entities.count == 1 && world.root.position == [10, -5])
        #expect(world.random == expectedRandom)
        // Runtime services remain application-owned rather than being silently
        // replaced by entity snapshot restoration.
        #expect(world.resources[ReplayRootRuntime.self]?.value == 99)
    }

    @Test func restoreCallbacksCannotConsumeTheSavedRandomStream() throws {
        let (world, controller, _) = fixture()
        let tape = try startingTape(controller)
        let expectedRandom = world.random
        var attachments = 0
        let token = world.subscribe(to: WorldEvents.DidAddEntity.self) { _ in
            attachments += 1
            _ = world.random.next()
        }
        defer { token.cancel() }

        try controller.startPlayback(tape, paused: true)

        #expect(attachments == 2)
        #expect(world.random == expectedRandom)
    }

    @Test func fileArchiveCanRestoreIntoAnotherWorld() throws {
        let (world, controller, _) = fixture()
        let tape = try startingTape(controller)
        let expectedRandom = world.random
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".replay.json")
        defer { try? FileManager.default.removeItem(at: url) }
        try tape.write(to: url)
        let loaded = try InputRecording(contentsOf: url)
        let other = World()
        other.fixedStep = .init(stepsPerSecond: 60)
        let playback = InputReplayController(world: other, input: InputController())

        try playback.startPlayback(loaded, paused: true)

        #expect(other.entities.first?.components[ReplaySavedValue.self]?.value == 7)
        #expect(other.entities.first?.children.first?.components[ReplaySavedValue.self]?.value == 3)
        #expect(other.random == expectedRandom)
        #expect(other.fixedStep == tape.configuration)
    }

    private func replacingSnapshot(in tape: InputRecording,
                                   _ change: (inout [String: Any]) throws -> Void) throws -> InputRecording {
        var envelope = try #require(JSONSerialization.jsonObject(with: tape.initialState) as? [String: Any])
        let base64 = try #require(envelope["snapshot"] as? String)
        let data = try #require(Data(base64Encoded: base64))
        var snapshot = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        try change(&snapshot)
        envelope["snapshot"] = try JSONSerialization.data(withJSONObject: snapshot).base64EncodedString()
        return try InputRecording(configuration: tape.configuration,
                                  initialState: JSONSerialization.data(withJSONObject: envelope), frames: tape.frames)
    }

    @Test func unknownComponentFailsBeforeRemovingExistingEntities() throws {
        let (world, controller, saved) = fixture()
        let tape = try startingTape(controller)
        let bad = try replacingSnapshot(in: tape) { snapshot in
            var entities = try #require(snapshot["entities"] as? [[String: Any]])
            var components = try #require(entities[0]["components"] as? [[String: Any]])
            components[0]["type"] = "Missing.Replay.Component"
            entities[0]["components"] = components
            snapshot["entities"] = entities
        }
        saved.components.set(ReplaySavedValue(value: 99))

        #expect(throws: (any Error).self) { try controller.startPlayback(bad, paused: true) }

        #expect(world.entity(withID: saved.id) === saved)
        #expect(saved.components[ReplaySavedValue.self]?.value == 99)
    }

    @Test func duplicateSavedIdentityFailsBeforeReplacingTheWorld() throws {
        let (world, controller, saved) = fixture()
        let tape = try startingTape(controller)
        let bad = try replacingSnapshot(in: tape) { snapshot in
            var entities = try #require(snapshot["entities"] as? [[String: Any]])
            entities.append(entities[0])
            snapshot["entities"] = entities
        }

        #expect(throws: (any Error).self) { try controller.startPlayback(bad, paused: true) }

        #expect(world.entities.count == 1 && world.entity(withID: saved.id) === saved)
    }

    @Test func defaultProviderDoesNotRetainItsWorldThroughRootRuntime() throws {
        var world: World? = World()
        weak var weakWorld = world
        let controller = InputReplayController(world: try #require(world), input: InputController())
        world?.resources.set(ReplayControllerReference(controller: controller))
        world = nil

        #expect(weakWorld == nil)
        #expect(throws: (any Error).self) { try controller.startRecording() }
    }
}
