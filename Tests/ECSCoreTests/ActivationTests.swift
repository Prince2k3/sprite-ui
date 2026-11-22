@_spi(Backend) import ECSCore
import Foundation
import Testing

private struct ActivationTicks: Component { var count = 0 }
private struct ActivationTickSystem: System {
    init(world: World) {}
    mutating func update(context: UpdateContext) {
        for entity in context.entities(matching: EntityQuery(where: .has(ActivationTicks.self))) {
            entity.components[ActivationTicks.self]?.count += 1
        }
    }
}

@MainActor @Suite struct EntityActivationTests {
    @Test func parentSuspendsChildrenWithoutOverwritingLocalFlags() {
        let world = World(), parent = Entity(), child = Entity(), dormant = Entity()
        dormant.isEnabled = false
        parent.addChild(child); parent.addChild(dormant)
        #expect(parent.isEnabledInHierarchy && !parent.isActive)
        world.addEntity(parent)
        var transitions: [(Entity.ID, Bool)] = []
        let subscription = world.subscribe(to: WorldEvents.DidChangeEntityActivation.self) {
            transitions.append(($0.entity.id, $0.isEnabledInHierarchy))
        }
        parent.isEnabled = false
        #expect(!child.isActive && child.isEnabled && !dormant.isEnabled)
        #expect(world.entity(withID: child.id) === child && parent.children.count == 2)
        parent.isEnabled = true
        #expect(child.isActive && !dormant.isActive)
        #expect(transitions.map(\.0) == [parent.id, child.id, parent.id, child.id])
        #expect(transitions.map(\.1) == [false, false, true, true])
        withExtendedLifetime(subscription) {}
    }
    @Test func systemsSkipDormantEntitiesAndInspectionCanIncludeThem() {
        let world = World(), parent = Entity(), child = Entity(components: ActivationTicks())
        parent.addChild(child); world.addEntity(parent); world.addSystem(ActivationTickSystem.self)
        world.update(deltaTime: 1); parent.isEnabled = false; world.update(deltaTime: 1)
        #expect(child.components[ActivationTicks.self]?.count == 1)
        #expect(world.performQuery(EntityQuery()).isEmpty)
        #expect(world.performQuery(EntityQuery(includingDisabled: true)).count == 2)
        parent.isEnabled = true; world.update(deltaTime: 1)
        #expect(child.components[ActivationTicks.self]?.count == 2)
    }
    @Test func reentrantHandlersDoNotPublishStaleDescendantTransitions() {
        let world = World(), parent = Entity(), child = Entity()
        parent.addChild(child); world.addEntity(parent)
        var childChanges: [Bool] = []
        let subscription = world.subscribe(to: WorldEvents.DidChangeEntityActivation.self) { event in
            if event.entity === parent && !event.isEnabledInHierarchy { parent.isEnabled = true }
            if event.entity === child { childChanges.append(event.isEnabledInHierarchy) }
        }
        parent.isEnabled = false
        #expect(parent.isActive && child.isActive && childChanges == [true])
        withExtendedLifetime(subscription) {}
    }
    @Test func disabledAncestorAlsoBlocksInputAndReparentInvalidatesCaptureRevision() throws {
        let world = World(), parent = Entity(), child = Entity(components: InputTargetComponent())
        parent.isEnabled = false; parent.addChild(child); world.addEntity(parent)
        #expect(!child.isInputTarget)
        let revision = child.activationRevision
        try child.setParent(world.root)
        #expect(child.isInputTarget && child.isActive && child.activationRevision != revision)
        world.isPaused = true
        #expect(child.isActive) // Pause is independent of entity activation.
    }
    @Test func cloningAndSnapshotFilesKeepLocalEnablementAndOldFilesDefaultToTrue() throws {
        let parent = Entity(), child = Entity(); parent.addChild(child)
        parent.isEnabled = false
        let copy = parent.clone()
        #expect(!copy.isEnabled && copy.children[0].isEnabled && !copy.children[0].isEnabledInHierarchy)
        let data = try JSONEncoder().encode(parent.snapshot())
        let saved = try JSONDecoder().decode(EntitySnapshot.self, from: data).makeEntity()
        #expect(!saved.isEnabled && saved.children[0].isEnabled)
        let old = try JSONDecoder().decode(EntitySnapshot.self, from: Data("{}".utf8)).makeEntity()
        #expect(old.isEnabled)
    }
}
