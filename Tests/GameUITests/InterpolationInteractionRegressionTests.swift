@_spi(Backend) import ECSCore
import Foundation
@testable import GameUI
import SpriteBackend
import SpriteKit
import Testing

private struct ReviewInteractionMover: Component {}

@MainActor private struct ReviewInteractionSystem: System {
    static var phase: SystemPhase { .fixedSimulation }
    init(world: World) {}
    func update(context: UpdateContext) {
        for entity in context.entities(matching: EntityQuery(where: .has(ReviewInteractionMover.self))) {
            entity.position.x += 20
        }
    }
}

@MainActor @Suite struct InterpolationInteractionRegressionTests {
    private func fixture() -> (GameHost, Entity) {
        let host = GameHost()
        host.renderer.size = CGSize(width: 200, height: 200)
        host.world.fixedStep = .init(stepsPerSecond: 8)
        host.world.addSystem(ReviewInteractionSystem.self)
        let entity = Entity(components: ReviewInteractionMover(), TransformInterpolationComponent(),
                            SpriteComponent(color: .red, size: [4, 4]),
                            InputTargetComponent(), ManipulationComponent())
        host.world.addEntity(entity)
        frame(host, at: 0)
        return (host, entity)
    }

    private func frame(_ host: GameHost, at time: TimeInterval) {
        host.renderer.update(time)
        host.renderer.didSimulatePhysics()
        host.renderer.didFinishUpdate()
    }

    @Test(arguments: [false, true])
    func nativePanAdmissionAndCaptureUseTheSameDisplayedPose(draggableIsChild: Bool) throws {
        let (host, entity) = fixture()
        defer { withExtendedLifetime(host) {} }
        let draggable: Entity
        if draggableIsChild {
            entity.components.remove(SpriteComponent.self)
            entity.components.remove(InputTargetComponent.self)
            entity.components.remove(ManipulationComponent.self)
            draggable = Entity(components: SpriteComponent(color: .red, size: [4, 4]),
                               InputTargetComponent(), ManipulationComponent())
            entity.addChild(draggable)
        } else { draggable = entity }
        let input = GameManipulationInput(host: host)
        host.manipulationInput = input
        var beganPoint: CGPoint?
        let token = host.world.subscribe(to: ManipulationEvents.Began.self) { _ in
            beganPoint = host.renderer.viewPoint(from: .zero, relativeTo: draggable)
        }
        defer { token.cancel() }
        frame(host, at: 0.1875)
        #expect(entity.position == [20, 0] && entity.presentation.position == [10, 0])
        let point = CGPoint(x: 110, y: 100)
        #expect(input.admitContact(1, at: point))
        try #require(input.begin(.pan, contacts: [1]))
        defer { input.cancel() }
        #expect(input.session?.initialTransform.translation == (draggableIsChild ? .zero : [10, 0]))
        #expect(beganPoint == point)
        #expect(input.change(.pan, translation: .zero))
        #expect(host.renderer.viewPoint(from: .zero, relativeTo: draggable) == point)
        frame(host, at: 0.1875)
        #expect(input.session?.isActive == true)
        #expect(input.change(.pan, translation: CGPoint(x: 3, y: 0)))
        #expect(host.renderer.viewPoint(from: .zero, relativeTo: draggable) == CGPoint(x: 113, y: 100))
        #expect(host.world.fixedTransformSample(for: draggable) == nil)
        if draggableIsChild {
            frame(host, at: 0.3125)
            #expect(input.session?.isActive == true)
            #expect(host.renderer.viewPoint(from: .zero, relativeTo: draggable) == CGPoint(x: 113, y: 100))
            #expect(host.world.fixedTransformSample(for: entity) != nil)
        }
    }

    @Test(arguments: [false, true])
    func attachmentsAndPickingStayAlignedRegardlessOfRenderObserverOrder(writerFirst: Bool) throws {
        let (host, entity) = fixture()
        defer { withExtendedLifetime(host) {} }
        let unrelated = Entity()
        host.world.addEntity(unrelated)
        var writer: EventSubscription?
        func subscribeWriter() {
            writer = host.world.subscribe(to: RenderingEvents.DidUpdate.self) { _ in
                unrelated.position.x += 1
            }
        }
        if writerFirst { subscribeWriter() }
        host.attachmentStore.configure(["label"])
        let label = try #require(host.content.attachments.makeEntity(for: "label"))
        entity.addChild(label)
        if !writerFirst { subscribeWriter() }
        defer { writer?.cancel() }

        frame(host, at: 0.1875)

        let projection = try #require(host.attachmentStore.presentations.first)
        #expect(projection.position == CGPoint(x: 110, y: 100))
        #expect(host.renderer.inputTarget(at: CGPoint(x: 10, y: 0)) === entity)
        #expect(entity.presentation.position == [10, 0])
        #expect(entity.position == [20, 0])
    }
}
