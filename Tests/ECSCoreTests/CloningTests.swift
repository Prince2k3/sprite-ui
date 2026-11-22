import ECSCore
import Testing

private struct CloneValue: Component, Equatable { var values: [Int] }
private struct CloneLink: EntityReferencingComponent, Codable {
    var target: Entity.ID
    @MainActor mutating func remapEntityReferences(_ context: EntityReferenceRemapping) { target = context.id(for: target) }
}
private final class CloneBox: Codable { var value: Int; init(_ value: Int) { self.value = value } }
private struct CloneOwnedStorage: Component, Codable {
    var box: CloneBox
    func cloned() -> Self? { Self(box: CloneBox(box.value)) }
}
private struct CloneRuntime: Component { func cloned() -> Self? { nil } }
@MainActor private final class CloneEntitySubclass: Entity { required init() { super.init() } }

@MainActor @Suite struct CloningTests {
    @Test func recursiveCopiesHaveFreshIDsAndIndependentUnregisteredComponents() throws {
        let world = World(), original = Entity(name: "assembly", components: CloneValue(values: [1, 2]), CloneRuntime())
        original.position = [10, 20]
        let a = Entity(name: "a"), b = Entity(name: "b")
        original.addChild(a); original.addChild(b)
        a.components.set(CloneLink(target: b.id)); b.components.set(CloneLink(target: a.id))
        world.addEntity(original)
        let copy = original.clone()
        let ca = try #require(copy.findEntity(named: "a")), cb = try #require(copy.findEntity(named: "b"))
        #expect(copy.world == nil && copy.parent == nil && original.world === world)
        #expect(copy.id != original.id && ca.id != a.id && cb.id != b.id)
        #expect(copy.children.map(\.name) == ["a", "b"] && ca.parent === copy)
        #expect(ca.components[CloneLink.self]?.target == cb.id && cb.components[CloneLink.self]?.target == ca.id)
        #expect(copy.transform == original.transform && !copy.components.has(CloneRuntime.self))
        copy.components[CloneValue.self]?.values.append(3)
        #expect(original.components[CloneValue.self]?.values == [1, 2])
        #expect(copy.components[CloneValue.self]?.values == [1, 2, 3])
    }
    @Test func nonrecursiveClonesRemapSelfButKeepChildrenAndOtherTargetsExternal() {
        let original = Entity(name: "root"), child = Entity(name: "child")
        original.addChild(child); original.components.set(CloneLink(target: original.id))
        let selfCopy = original.clone(recursive: false)
        #expect(selfCopy.children.isEmpty && selfCopy.components[CloneLink.self]?.target == selfCopy.id)
        original.components[CloneLink.self]?.target = child.id
        let childCopy = original.clone(recursive: false)
        #expect(childCopy.components[CloneLink.self]?.target == child.id)
        original.components[CloneLink.self]?.target = Entity().id
        #expect(original.clone().components[CloneLink.self]?.target == original.components[CloneLink.self]?.target)
    }
    @Test func customReferenceStorageIsDeepCopiedAndEntityTypesArePreserved() throws {
        let original = CloneEntitySubclass()
        original.components.set(CloneOwnedStorage(box: CloneBox(7)))
        let child = CloneEntitySubclass(); original.addChild(child)
        let copy: CloneEntitySubclass = original.clone()
        #expect(type(of: copy.children[0]) == CloneEntitySubclass.self)
        let copiedBox = try #require(copy.components[CloneOwnedStorage.self]?.box)
        copiedBox.value = 20
        #expect(original.components[CloneOwnedStorage.self]?.box.value == 7)
    }
    @Test func snapshotInstantiationAlsoRemapsSiblingAndSelfReferences() throws {
        CloneLink.registerComponent(named: "tests.clone-link")
        let root = Entity(name: "root"), child = Entity(name: "child")
        root.addChild(child); root.components.set(CloneLink(target: child.id)); child.components.set(CloneLink(target: child.id))
        let copy = root.snapshot().makeEntity()
        #expect(copy.components[CloneLink.self]?.target == copy.children[0].id)
        #expect(copy.children[0].components[CloneLink.self]?.target == copy.children[0].id)
        let second = root.snapshot().makeEntity()
        #expect(second.children[0].id != copy.children[0].id)
    }
    @Test func restoreRemapsRootIDCollisionsWithoutStealingLaterSavedIDs() throws {
        let world = World()
        let a = world.root.id, b = a + 1
        let snapshot = WorldSnapshot(entities: [EntitySnapshot(id: a, name: "a", components: [CloneLink(target: b)]), EntitySnapshot(id: b, name: "b", components: [CloneLink(target: a)])])
        let restored = world.restore(snapshot)
        let ra = try #require(restored[a]), rb = try #require(restored[b])
        #expect(ra.id != a && rb.id == b && ra.id != rb.id)
        #expect(ra.components[CloneLink.self]?.target == rb.id && rb.components[CloneLink.self]?.target == ra.id)
        #expect(world.allEntities.count == 2)
    }
    @Test func snapshotsFreezeCustomMutableStorageBeforeLaterInstantiation() throws {
        CloneOwnedStorage.registerComponent(named: "tests.clone-owned-storage")
        let source = Entity(components: CloneOwnedStorage(box: CloneBox(7)))
        let snapshot = source.snapshot()
        source.components[CloneOwnedStorage.self]?.box.value = 99
        let a = snapshot.makeEntity(), b = snapshot.makeEntity()
        a.components[CloneOwnedStorage.self]?.box.value = 12
        #expect(b.components[CloneOwnedStorage.self]?.box.value == 7)
        #expect(snapshot[CloneOwnedStorage.self]?.box.value == 7)
    }
    @Test func copyingDoesNotPublishWorldEventsOrAttachCopies() {
        let world = World(), entity = Entity(); world.addEntity(entity)
        var additions = 0
        let subscription = world.subscribe(to: WorldEvents.DidAddEntity.self) { _ in additions += 1 }
        let a = entity.clone(), b = entity.clone()
        #expect(additions == 0 && world.entities.count == 1 && a.id != b.id)
        withExtendedLifetime(subscription) {}
    }
}
