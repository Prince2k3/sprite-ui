import ECSCore
import Foundation
import Gameplay
import Testing
@testable import SpriteBackend

@MainActor @Suite struct CharacterControllerTests {
    func fixture(at point: SIMD2<Float> = .zero, shape: CollisionShape = .circle(radius: 2)) -> (World, Entity) {
        let world = World(), character = Entity(components: CharacterControllerComponent(shape: shape))
        character.position = point; world.addEntity(character); return (world, character)
    }
    @discardableResult func wall(_ world: World, at point: SIMD2<Float>, size: SIMD2<Float> = [1, 100]) -> Entity {
        let wall = Entity(components: CollisionComponent(shape: .rectangle(size: size)))
        wall.position = point; world.addEntity(wall); return wall
    }
    @Test func fastMovementStopsAtThinWallAndReportsSceneContacts() throws {
        let (world, character) = fixture(); let wall = wall(world, at: [50, 0])
        let result = try character.moveCharacter(by: [1000, 0])
        #expect(abs(character.position.x - 47.49) < 0.002)
        #expect(result.contacts.first?.entity === wall)
        #expect(result.contacts.first!.normal.x < -0.99)
        #expect(abs(result.displacement.x - character.position.x) < 0.001)
        #expect(result.remainingTranslation.x > 950 && !result.isOverlapping)
    }
    @Test func slidesAlongWallRepeatedlyAndCanMoveAway() throws {
        let (world, character) = fixture(); wall(world, at: [10, 0], size: [2, 200])
        for _ in 0..<10 { try character.moveCharacter(by: [4, 3]) }
        #expect(abs(character.position.x - 6.99) < 0.003 && abs(character.position.y - 30) < 0.01)
        let result = try character.moveCharacter(by: [-5, 0])
        #expect(result.contacts.isEmpty && abs(character.position.x - 1.99) < 0.003)
    }
    @Test func perpendicularWallsStopAtCornerAndRespectSlideBudget() throws {
        let (world, character) = fixture()
        wall(world, at: [10, 0], size: [2, 100]); wall(world, at: [0, 15], size: [100, 2])
        let result = try character.moveCharacter(by: [30, 30])
        #expect(abs(character.position.x - 6.99) < 0.003 && abs(character.position.y - 11.99) < 0.003)
        #expect(result.contacts.count == 2)
        character.position = .zero; character.components[CharacterControllerComponent.self]?.maxSlides = 1
        try character.moveCharacter(by: [30, 30])
        #expect(character.position.y < 8)
    }
    @Test func recoversEmbeddedAndExactlyTouchingSpawnPositions() throws {
        let (world, character) = fixture(at: [9, 0]); wall(world, at: [10, 0], size: [4, 100])
        let result = try character.moveCharacter(by: [-5, 3])
        #expect(result.recoveryTranslation.x < -2.99 && !result.isOverlapping)
        #expect(abs(character.position.x - 0.99) < 0.003 && abs(character.position.y - 3) < 0.003)
        character.position = [6, 0]
        let touching = try character.moveCharacter(by: [0, 5])
        #expect(!touching.isOverlapping && abs(character.position.y - 5) < 0.003)
    }
    @Test func impossibleGapReportsOverlapAndDoesNotAdvanceRequestedMotion() throws {
        let (world, character) = fixture(shape: .circle(radius: 3))
        wall(world, at: [-3, 0], size: [2, 100]); wall(world, at: [3, 0], size: [2, 100])
        let result = try character.moveCharacter(by: [0, 50])
        #expect(result.isOverlapping && abs(character.position.y) < 0.001)
        #expect(result.remainingTranslation == [0, 50])
    }
    @Test func nestedAffineOffsetsAndRelativeMovementAreSceneAware() throws {
        let (world, character) = fixture()
        let parent = Entity(); parent.position = [20, 30]; parent.rotation = .pi / 2; parent.scale = [-2, 3]
        world.addEntity(parent); parent.addChild(character)
        character.components[CharacterControllerComponent.self]?.offset = [1, 0]
        wall(world, at: [20, 50], size: [100, 2])
        let result = try character.moveCharacter(by: [-20, 0], relativeTo: parent)
        #expect(abs(result.requestedTranslation.y - 40) < 0.001)
        // Origin 30, offset -2, vertical radius 4: contact at origin y=47.
        #expect(abs(character.scenePosition.y - 46.99) < 0.01)
        #expect(abs(character.scenePosition.x - 20) < 0.002)
    }
    @Test func filtersIgnoreSensorsSelfAndDescendantsAndSeeMovedWalls() throws {
        let (world, character) = fixture()
        let child = Entity(components: CollisionComponent(shape: .circle(radius: 100)))
        character.addChild(child)
        let sensor = wall(world, at: [5, 0]); sensor.components[CollisionComponent.self]?.filter.mask = .none
        let blocker = wall(world, at: [10, 0]); blocker.components[CollisionComponent.self]?.isEnabled = false
        #expect(try character.moveCharacter(by: [20, 0]).contacts.isEmpty)
        blocker.position = [30, 0]; blocker.components[CollisionComponent.self]?.isEnabled = true
        #expect(try character.moveCharacter(by: [20, 0]).contacts.first?.entity === blocker)
        #expect(character.position.x < 28)
    }
    @Test func invalidMovesAreAtomicAndConfigurationRoundTrips() throws {
        let (world, character) = fixture(); let original = character.position
        #expect(throws: CharacterMovementError.invalidConfiguration) { try character.moveCharacter(by: [.nan, 0]) }
        character.components[CharacterControllerComponent.self]?.shape = .edgeChain([[0, 0], [1, 0]])
        #expect(throws: CharacterMovementError.invalidConfiguration) { try character.moveCharacter(by: [1, 0]) }
        #expect(character.position == original)
        character.components.set(CharacterControllerComponent(shape: .rectangle(size: [2, 3])))
        character.components.set(PhysicsBodyComponent(shape: .circle(radius: 2)))
        #expect(throws: CharacterMovementError.dynamicPhysicsBody) { try character.moveCharacter(by: [1, 0]) }
        character.components.remove(PhysicsBodyComponent.self)
        SpriteRenderer.registerComponents()
        let snapshot = try WorldSnapshot(data: world.snapshot().jsonData()); world.restore(snapshot)
        #expect(world.entities[0].components[CharacterControllerComponent.self] == character.components[CharacterControllerComponent.self])
    }
    @Test func controllersAreQueryableAndRecoverFromOtherCharacters() throws {
        let (world, character) = fixture()
        let other = Entity(components: CharacterControllerComponent(shape: .circle(radius: 3)))
        other.position = [10, 0]; world.addEntity(other)
        let result = try character.moveCharacter(by: [20, 0])
        #expect(result.contacts.first?.entity === other && abs(character.position.x - 4.99) < 0.01)
        other.position = character.position + [1, 0]
        let recovery = try character.moveCharacter(by: .zero)
        #expect(recovery.recoveryTranslation.x < -3.99 && !recovery.isOverlapping)
        other.components[CharacterControllerComponent.self]?.isEnabled = false
        #expect(try character.moveCharacter(by: [30, 0]).contacts.isEmpty)
    }
    @Test func failedConversionsAndDisabledControllersLeaveTransformUnchanged() throws {
        let (world, character) = fixture(); let original = character.transform
        let otherWorld = World(), other = Entity(); otherWorld.addEntity(other)
        #expect(throws: EntityTransformError.differentWorlds) { try character.moveCharacter(by: [1, 0], relativeTo: other) }
        character.components[CharacterControllerComponent.self]?.isEnabled = false
        #expect(throws: CharacterMovementError.disabledController) { try character.moveCharacter(by: [1, 0]) }
        character.components[CharacterControllerComponent.self]?.isEnabled = true
        #expect(throws: EntityTransformError.nonfiniteTransform) { try character.moveCharacter(by: [.greatestFiniteMagnitude, .greatestFiniteMagnitude]) }
        #expect(character.transform == original)
        let parent = Entity(); parent.scale = [0, 1]; world.addEntity(parent); parent.addChild(character)
        #expect(throws: EntityTransformError.noninvertibleTransform) { try character.moveCharacter(by: [1, 0]) }
        #expect(character.transform == original)
    }
    @Test func repeatedSeededMovesStayInsideBoundaryAndOutsideRotatedWalls() throws {
        let (world, character) = fixture(at: [-30, -30])
        let boundary = Entity(components: CollisionComponent(shape: .edgeLoop(rectangle: [100, 100])))
        world.addEntity(boundary)
        let block = wall(world, at: .zero, size: [4, 60]); block.rotation = 0.3
        var rng = SeededGenerator(seed: 77)
        for _ in 0..<200 {
            let result = try character.moveCharacter(by: [Float.random(in: -150...150, using: &rng), Float.random(in: -150...150, using: &rng)])
            #expect(!result.isOverlapping)
            #expect(abs(character.position.x) < 48.001 && abs(character.position.y) < 48.001)
            #expect(world.overlaps(shape: .circle(radius: 2), transform: character.sceneTransformMatrix, filter: .init(excluding: [character.id])).isEmpty)
        }
    }
    @Test func openEdgeBoundariesAndPolygonCharactersSlide() throws {
        let (world, character) = fixture(shape: .rectangle(size: [4, 4]))
        let boundary = Entity(components: CollisionComponent(shape: .edgeLoop(rectangle: [40, 40])))
        world.addEntity(boundary)
        try character.moveCharacter(by: [100, 10])
        #expect(abs(character.position.x - 17.99) < 0.004 && abs(character.position.y - 10) < 0.004)
        #expect(!world.overlaps(shape: .rectangle(size: [4, 4]), transform: character.sceneTransformMatrix).contains(where: { $0.entity === boundary }))
    }
}
