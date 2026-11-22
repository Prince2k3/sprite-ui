@_spi(Backend) import ECSCore
import SpriteBackend
import SpriteKit
import SwiftUI
import Testing

@MainActor
@Suite struct WithAnimationTests {
    // MARK: Overload resolution (SwiftUI is imported here on purpose)

    @Test func everyCommonFormResolvesToSpriteUI() {
        var seen: [ActionAnimation?] = []
        func record() { seen.append(ActionTransaction.current?.animation) }

        withAnimation { record() }
        withAnimation(.spring(duration: 0.4, bounce: 0.2)) { record() }
        withAnimation(.easeInOut(duration: 0.2)) { record() } completion: {}
        withAnimation { record() } completion: {}
        withAnimation(.bouncy) { record() }
        withAnimation(.linear) { record() }
        withAnimation(.default) { record() }
        withAnimation(.spring) { record() }
        withAnimation(.easeOut(duration: 1).delay(0.5).repeatCount(2)) { record() }
        withAnimation(.disabled) { record() }
        ActionTransaction.sealPending()

        #expect(seen.count == 10)
        #expect(seen.allSatisfy { $0 != nil })
        #expect(seen[1]?.duration == 0.4)
        #expect(seen[8]?.delay == 0.5)
        #expect(seen[9]?.duration == 0)
    }

    @Test func returnsTheBodysResult() {
        let value = withAnimation(.linear) { 42 }
        #expect(value == 42)
    }

    // MARK: Curves

    @Test func curvesStartAtZeroAndEndAtOne() {
        let curves: [ActionAnimation.Curve] = [.linear, .easeIn, .easeOut, .easeInOut, .spring(bounce: 0), .spring(bounce: 0.5)]
        for curve in curves {
            #expect(abs(curve.progress(0)) < 0.001)
            #expect(curve.progress(1) == 1)
        }
    }

    @Test func bouncySpringsOvershoot() {
        let samples = stride(from: 0.0, through: 1.0, by: 0.01).map { ActionAnimation.Curve.spring(bounce: 0.5).progress($0) }
        #expect(samples.max()! > 1)
        let critical = stride(from: 0.0, through: 1.0, by: 0.01).map { ActionAnimation.Curve.spring(bounce: 0).progress($0) }
        #expect(critical.max()! <= 1.0001)
    }

    @Test func swiftUIMapping() {
        #expect(ActionAnimation.disabled.swiftUI == nil)
        #expect(ActionAnimation.easeInOut(duration: 0.3).swiftUI != nil)
        #expect(ActionAnimation.disabled.delay(0.2).swiftUI != nil)
    }

    // MARK: Renderer

    private func makeScene() -> (World, SpriteRenderer, Entity, SKNode) {
        let world = World()
        let renderer = SpriteRenderer(world: world)
        let entity = Entity(components: SpriteComponent(color: .red, size: [10, 10]))
        world.addEntity(entity)
        return (world, renderer, entity, renderer.node(for: entity)!)
    }

    @Test func animatedChangesRunKeyedActionsAndLeaveOthersAlone() {
        let (_, renderer, entity, node) = makeScene()

        withAnimation(.linear(duration: 1)) { entity.position = [100, 0] }
        renderer.flush()
        #expect(node.action(forKey: "transform.position") != nil)
        #expect(node.action(forKey: "transform.rotation") == nil)
        #expect(node.position == .zero)             // still on its way
        #expect(entity.position == [100, 0])        // model is already there

        // Animating another property doesn't cancel the move.
        withAnimation(.linear(duration: 1)) { entity.transform.rotation = 1 }
        renderer.flush()
        #expect(node.action(forKey: "transform.position") != nil)
        #expect(node.action(forKey: "transform.rotation") != nil)
    }

    @Test func unanimatedChangesSetDirectlyAndCancelRunningActions() {
        let (_, renderer, entity, node) = makeScene()

        withAnimation(.linear(duration: 1)) { entity.position = [100, 0] }
        renderer.flush()
        entity.position = [5, 5]
        renderer.flush()
        #expect(node.action(forKey: "transform.position") == nil)
        #expect(node.position == CGPoint(x: 5, y: 5))
    }

    @Test func disabledOptsOutInsideAnOuterAnimation() {
        let (_, renderer, entity, node) = makeScene()

        withAnimation(.linear(duration: 1)) {
            entity.transform.rotation = 1
            withAnimation(.disabled) { entity.position = [7, 7] }
        }
        renderer.flush()
        #expect(node.position == CGPoint(x: 7, y: 7))
        #expect(node.action(forKey: "transform.rotation") != nil)
    }

    @Test func spriteAnimationsUseTheChildNode() {
        let (_, renderer, entity, node) = makeScene()
        let sprite = node.children.first as! SKSpriteNode

        withAnimation(.easeIn(duration: 1)) { entity.components[SpriteComponent.self]?.opacity = 0 }
        renderer.flush()
        #expect(sprite.action(forKey: "sprite.opacity") != nil)
        #expect(sprite.action(forKey: "sprite.size") == nil)
        #expect(sprite.alpha == 1)
    }

    @Test func presentationReadsTheScreenWhileTheModelIsAtTheTarget() {
        let (_, renderer, entity, _) = makeScene()

        withAnimation(.linear(duration: 1)) { entity.position = [100, 0] }
        renderer.flush()
        #expect(entity.position == [100, 0])
        #expect(entity.presentation.position == [0, 0])
        #expect(entity.presentation[SpriteComponent.self]?.opacity == 1)
    }

    // MARK: Completion

    @Test func completionFiresAtFlushWhenNothingAnimates() {
        let (_, renderer, entity, _) = makeScene()
        var fired = 0

        withAnimation(.linear(duration: 1)) {} completion: { fired += 1 }
        withAnimation(.disabled) { entity.position = [1, 1] } completion: { fired += 1 }
        #expect(fired == 0)
        renderer.flush()
        #expect(fired == 2)
        renderer.flush()
        #expect(fired == 2)
    }

    @Test func completionWaitsForActionsAndFiresWhenTheyAreReplaced() {
        let (_, renderer, entity, _) = makeScene()
        var fired = false

        withAnimation(.linear(duration: 1)) { entity.position = [100, 0] } completion: { fired = true }
        renderer.flush()
        #expect(!fired)

        entity.position = [0, 0]          // replaces the running move
        renderer.flush()
        #expect(fired)
    }

    @Test func completionWaitsForEveryAction() {
        let (_, renderer, entity, _) = makeScene()
        var fired = false

        withAnimation(.linear(duration: 1)) {
            entity.position = [100, 0]
            entity.transform.rotation = 1
        } completion: { fired = true }
        renderer.flush()

        entity.position = [0, 0]
        renderer.flush()
        #expect(!fired)                   // rotation still running

        entity.transform.rotation = 0
        renderer.flush()
        #expect(fired)
    }

    @Test func removingTheEntityFinishesItsAnimationsAtTheNextFlush() {
        let (world, renderer, entity, _) = makeScene()
        var fired = false

        withAnimation(.linear(duration: 1)) { entity.position = [100, 0] } completion: { fired = true }
        renderer.flush()
        world.removeEntity(entity)
        #expect(!fired)
        renderer.flush()
        #expect(fired)
    }

    @Test func repeatForeverNeverCompletes() {
        let (_, renderer, entity, node) = makeScene()
        var fired = false

        withAnimation(.linear(duration: 1).repeatForever()) { entity.position = [100, 0] } completion: { fired = true }
        renderer.flush()
        #expect(node.action(forKey: "transform.position") != nil)
        entity.position = [0, 0]
        renderer.flush()
        #expect(!fired)
    }
}
