import ECSCore
import Testing

@MainActor
@Suite struct HierarchyTests {
    @Test func findEntityChecksSelfThenDescendantsDepthFirst() {
        let root = Entity(name: "root")
        let a = Entity(name: "a"), b = Entity(name: "b"), deep = Entity(name: "target")
        let shallow = Entity(name: "target")
        a.addChild(deep)
        root.addChild(a)
        root.addChild(b)
        b.addChild(shallow)

        #expect(root.findEntity(named: "root") === root)
        #expect(root.findEntity(named: "target") === deep)
        #expect(b.findEntity(named: "target") === shallow)
        #expect(root.findEntity(named: "missing") == nil)
    }

    @Test func worldEntitiesLiveUnderAHiddenRoot() {
        let world = World()
        let player = Entity(name: "player")
        world.addEntity(player)
        #expect(world.entities.map(\.name) == ["player"])
        #expect(world.root.findEntity(named: "player") === player)
        #expect(player.isDescendant(of: world.root))
    }

    @Test func isDescendantWalksAncestors() {
        let a = Entity(), b = Entity(), c = Entity(), other = Entity()
        a.addChild(b)
        b.addChild(c)
        #expect(c.isDescendant(of: a))
        #expect(c.isDescendant(of: b))
        #expect(!c.isDescendant(of: c))
        #expect(!a.isDescendant(of: c))
        #expect(!c.isDescendant(of: other))
    }

    @Test func inputTargetIsInheritedAndCanBeOverridden() {
        let parent = Entity(components: InputTargetComponent())
        let child = Entity(), optedOut = Entity(components: InputTargetComponent(isEnabled: false))
        let grandchild = Entity()
        parent.addChild(child)
        parent.addChild(optedOut)
        optedOut.addChild(grandchild)

        #expect(parent.isInputTarget)
        #expect(child.isInputTarget)
        #expect(!optedOut.isInputTarget)
        #expect(!grandchild.isInputTarget)
        #expect(!Entity().isInputTarget)
    }
}
