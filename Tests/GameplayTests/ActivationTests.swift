import ECSCore
import Gameplay
import GameplayECS
import Testing

@MainActor @Suite struct GameplayActivationTests {
    @Test func pathProgressAndSpatialQueriesRespectHierarchyEnablement() {
        let world = World(), parent = Entity(), child = Entity(components: SpatialIndexComponent())
        parent.addChild(child); world.addEntity(parent); world.addSystem(PathFollowSystem.self)
        child.follow([[100, 0]], speed: 10)
        world.updateSpatialIndex(); #expect(world.nearestEntity(to: .zero) === child)
        parent.isEnabled = false
        // Suppress stale index entries immediately, even before the next rebuild.
        #expect(world.nearestEntity(to: .zero) == nil)
        world.update(deltaTime: 1); #expect(child.position == .zero && child.isFollowingPath)
        world.updateSpatialIndex(); #expect(world.nearestEntity(to: .zero) == nil)
        parent.isEnabled = true; world.update(deltaTime: 1); world.updateSpatialIndex()
        #expect(child.position == [10, 0] && world.nearestEntity(to: .zero) === child)
    }
}
