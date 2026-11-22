@_spi(Backend) import ECSCore
import Foundation
@testable import GameUI
import SpriteBackend
import SpriteKit
import SwiftUI
import Testing

@MainActor @Suite struct AttachmentTests {
    func fixture(interactive: Bool = false, sizing: AttachmentComponent.Sizing = .screen) -> (GameHost, Entity) {
        let host = GameHost(); host.renderer.size = CGSize(width: 200, height: 200)
        host.attachmentStore.configure(["label"])
        let anchor = host.content.attachments.makeEntity(for: "label")!
        anchor.components[AttachmentComponent.self]?.isInteractive = interactive
        anchor.components[AttachmentComponent.self]?.sizing = sizing
        host.world.addEntity(anchor); host.renderer.flush(); host.attachmentStore.refresh()
        return (host, anchor)
    }
    func projection(_ host: GameHost) throws -> AttachmentProjection { try #require(host.attachmentStore.presentations.first) }
    func context(_ host: GameHost, _ entity: Entity) throws -> AttachmentContext {
        AttachmentContext(entity: entity, store: host.attachmentStore, identity: try projection(host).id)
    }
    func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.0001 }

    @Test func namedAnchorsAreViewScopedAndFreshInstancesAreIndependent() throws {
        let (a, _) = fixture(), (b, _) = fixture()
        let first = try #require(a.content.attachments.entity(for: "label"))
        #expect(a.content.attachments.entity(for: "label") === first)
        #expect(a.content.attachments.makeEntity(for: "label") !== first)
        #expect(b.content.attachments.entity(for: "label") !== first)
        #expect(a.content.attachments.entity(for: "unknown") == nil)
    }
    @Test func offsetsUsePresentedAncestorTransformsAndProjectionRoundTripsThroughCamera() throws {
        let (host, anchor) = fixture()
        let parent = Entity(); parent.position = [20, 30]; parent.scale = [2, 3]
        parent.rotation = .pi / 2; host.world.addEntity(parent); parent.addChild(anchor)
        anchor.position = [4, 5]; anchor.components[AttachmentComponent.self]?.offset = [1, 2]
        let camera = Entity(components: CameraComponent(zoom: 2)); camera.position = [20, 30]; camera.rotation = .pi / 2
        host.world.addEntity(camera); host.renderer.flush(); host.attachmentStore.refresh()
        let p = try projection(host), expected = try #require(host.renderer.viewPoint(from: [1, 2], relativeTo: anchor))
        #expect(close(p.position.x, expected.x) && close(p.position.y, expected.y))
        let world = host.renderer.scenePoint(fromView: p.position)
        let expectedWorld = try #require(anchor.convert(position: [1, 2], to: nil))
        #expect(abs(world.x - expectedWorld.x) < 0.0001 && abs(world.y - expectedWorld.y) < 0.0001)
        // A native presented pose can differ from the component model mid-action.
        host.renderer.node(for: parent)?.position.x += 10
        host.renderer.didFinishUpdate()
        #expect(try projection(host).position != p.position)
    }
    @Test func screenSizingStaysUprightWhileSceneSizingFollowsRotationScaleAndShear() throws {
        let (host, anchor) = fixture()
        let parent = Entity(); parent.rotation = 0.4; parent.scale = [2, 3]
        host.world.addEntity(parent); parent.addChild(anchor); anchor.rotation = 0.7
        let camera = Entity(components: CameraComponent(zoom: 2)); host.world.addEntity(camera)
        host.renderer.flush(); host.attachmentStore.refresh()
        #expect(try projection(host).basis == .identity)
        anchor.components[AttachmentComponent.self]?.sizing = .scene
        host.renderer.flush(); host.attachmentStore.refresh()
        let p = try projection(host)
        let origin = try #require(host.renderer.viewPoint(from: .zero, relativeTo: anchor))
        let x = try #require(host.renderer.viewPoint(from: [1, 0], relativeTo: anchor))
        let y = try #require(host.renderer.viewPoint(from: [0, -1], relativeTo: anchor))
        #expect(close(p.basis.a, x.x - origin.x) && close(p.basis.b, x.y - origin.y))
        #expect(close(p.basis.c, y.x - origin.x) && close(p.basis.d, y.y - origin.y))
        #expect(abs(p.basis.a * p.basis.c + p.basis.b * p.basis.d) > 0.1) // Genuine shear.
    }
    @Test func alignmentAndHitRegionsUseTheTransformedContentRectangle() throws {
        let (host, anchor) = fixture(interactive: true, sizing: .scene)
        anchor.rotation = .pi / 2; anchor.components[AttachmentComponent.self]?.anchor = .bottom
        host.renderer.flush(); host.attachmentStore.refresh()
        let p = try projection(host), size = CGSize(width: 40, height: 20)
        let alignment = CGPoint(x: 20, y: 20).applying(p.transform(for: size))
        #expect(close(alignment.x, p.position.x) && close(alignment.y, p.position.y))
        host.attachmentStore.reportSize(size, for: p.id)
        let inside = CGPoint(x: 10, y: 10).applying(p.transform(for: size))
        #expect(host.attachmentStore.blocksInput(at: inside))
        let outside = CGPoint(x: 50, y: 10).applying(p.transform(for: size))
        #expect(!host.attachmentStore.blocksInput(at: outside))
    }
    @Test func pausedScenesStillRefreshAttachmentsAfterExplicitEdits() throws {
        let (host, anchor) = fixture()
        host.world.isPaused = true; anchor.position = [40, 30]
        host.renderer.update(1); host.renderer.didFinishUpdate()
        #expect(try projection(host).position == CGPoint(x: 140, y: 70))
    }
    @Test func visibilityFollowsHierarchyAndOldContextsNeverRevalidateAfterActivation() throws {
        let (host, anchor) = fixture(interactive: true)
        let parent = Entity(); host.world.addEntity(parent); parent.addChild(anchor)
        host.renderer.flush(); host.attachmentStore.refresh()
        let old = try context(host, anchor)
        #expect(old.isValid)
        parent.isEnabled = false; #expect(host.attachmentStore.presentations.isEmpty && !old.isValid)
        parent.isEnabled = true; host.renderer.flush(); host.attachmentStore.refresh()
        #expect(!old.perform { $0.name = "stale" })
        let fresh = try context(host, anchor); #expect(fresh.perform { $0.name = "fresh" })
        #expect(anchor.name == "fresh")
    }
    @Test func removedDefinitionsAndViewDisappearanceInvalidateOldActionsPermanently() throws {
        let (host, anchor) = fixture(interactive: true), old = try context(host, anchor)
        host.attachmentStore.configure([]); #expect(host.attachmentStore.presentations.isEmpty && !old.isValid)
        host.attachmentStore.configure(["label"]); #expect(!old.isValid)
        let shown = try context(host, anchor)
        host.attachmentStore.setVisible(false); #expect(!shown.isValid && host.attachmentStore.presentations.isEmpty)
        host.attachmentStore.setVisible(true); #expect(!shown.isValid)
        let active = try context(host, anchor)
        host.attachmentStore.setAppActive(false); host.attachmentStore.setAppActive(true)
        #expect(!active.isValid && !host.attachmentStore.presentations.isEmpty)
    }
    @Test func labelsPassThroughButInteractiveAttachmentsNeverTargetTheSceneBehindThem() throws {
        let (host, anchor) = fixture()
        let target = Entity(components: InputTargetComponent(), SpriteComponent(color: .blue, size: [80, 80]))
        host.world.addEntity(target); host.renderer.flush(); host.attachmentStore.refresh()
        let p = try projection(host); host.attachmentStore.reportSize(CGSize(width: 60, height: 30), for: p.id)
        let point = CGPoint(x: 100, y: 100)
        let prior = host.beginInput(at: point); host.endInput(prior)
        #expect(TargetedInputCapture<Int>().resolve(1, start: point, host: host, resolver: { $0 })?.entity === target)
        anchor.components[AttachmentComponent.self]?.isInteractive = true
        host.attachmentStore.refresh()
        // No new native scene contact is required to reject a control's tap.
        #expect(TargetedInputCapture<Int>().resolve(1, start: point, host: host, resolver: { $0 }) == nil)
        host.cancelInputs(); host.beginInput(at: point)
        #expect(host.contact(startingAt: point)?.hit == nil)
        #expect(TargetedInputCapture<Int>().resolve(1, start: nil, host: host, resolver: { $0 }) == nil)
    }
    @Test func aSceneDragKeepsItsOriginalCaptureWhenAPanelMovesOverItsStartingPoint() throws {
        let (host, anchor) = fixture(interactive: true)
        anchor.position = [70, 0]
        let target = Entity(components: InputTargetComponent(), SpriteComponent(color: .blue, size: [50, 50]))
        host.world.addEntity(target); host.renderer.flush(); host.attachmentStore.refresh()
        host.attachmentStore.reportSize(CGSize(width: 30, height: 30), for: try projection(host).id)
        let point = CGPoint(x: 100, y: 100); host.beginInput(at: point)
        let capture = TargetedInputCapture<Int>()
        #expect(capture.resolve(1, start: point, host: host, resolver: { $0 })?.entity === target)
        anchor.position = .zero; host.renderer.flush(); host.attachmentStore.refresh()
        #expect(capture.resolve(2, start: point, host: host, resolver: { $0 })?.entity === target)
    }
    @Test func clonedAndPooledAnchorsHaveIndependentIdentitiesAndNoStaleInputState() throws {
        let host = GameHost(); host.renderer.size = CGSize(width: 200, height: 200)
        host.attachmentStore.configure(["label"])
        let template = Entity(), label = Entity(components: AttachmentComponent(id: "label", isInteractive: true))
        template.addChild(label)
        let pool = try EntityPool(prefab: PrefabResource(root: template), scene: host.world, capacity: 2)
        let a = try #require(try pool.acquire()), b = try #require(try pool.acquire())
        host.renderer.flush(); host.attachmentStore.refresh()
        #expect(host.attachmentStore.presentations.count == 2)
        let p = try #require(host.attachmentStore.presentations.first { $0.id.entityID == a.children[0].id })
        let old = AttachmentContext(entity: a.children[0], store: host.attachmentStore, identity: p.id)
        #expect(old.isValid && a.children[0].id != b.children[0].id)
        try pool.release(a); #expect(!old.isValid && host.attachmentStore.presentations.count == 1)
        #expect(try pool.acquire() === a)
        host.renderer.flush(); host.attachmentStore.refresh()
        #expect(host.attachmentStore.presentations.count == 2 && !old.isValid)
    }
    @Test func hiddenSingularAndNonfiniteAnchorsDoNotRenderOrCaptureInput() throws {
        let (host, anchor) = fixture(interactive: true)
        anchor.scale = .zero; host.renderer.flush(); host.attachmentStore.refresh()
        #expect(host.attachmentStore.presentations.isEmpty)
        anchor.scale = .one; host.renderer.flush(); host.renderer.node(for: anchor)?.isHidden = true
        host.attachmentStore.refresh(); #expect(host.attachmentStore.presentations.isEmpty)
        host.renderer.node(for: anchor)?.isHidden = false
        anchor.components[AttachmentComponent.self]?.offset = [.nan, 0]
        host.attachmentStore.refresh(); #expect(host.attachmentStore.presentations.isEmpty)
    }
    @Test func removalDropsWeakReferencesAndCrossSceneProjectionFails() throws {
        let (host, original) = fixture()
        let foreign = World(), copy = original.clone(); foreign.addEntity(copy)
        #expect(host.renderer.viewPoint(from: .zero, relativeTo: copy) == nil)
        weak var weakAnchor: Entity?
        do {
            let another = try #require(host.content.attachments.makeEntity(for: "label"))
            weakAnchor = another; host.world.addEntity(another); host.attachmentStore.refresh()
            another.removeFromParent()
            #expect(!host.attachmentStore.presentations.contains { $0.id.entityID == another.id })
        }
        #expect(weakAnchor == nil)
    }
    @Test func componentRoundTripsThroughSnapshotsAndRetainsClonedConfiguration() throws {
        AttachmentComponent.registerComponent()
        let source = Entity(components: AttachmentComponent(id: "label", offset: [4, 5], anchor: .bottomTrailing, sizing: .scene, isInteractive: true))
        let restored = try JSONDecoder().decode(EntitySnapshot.self, from: JSONEncoder().encode(source.snapshot())).makeEntity()
        #expect(restored.components[AttachmentComponent.self] == source.components[AttachmentComponent.self])
        #expect(source.clone().components[AttachmentComponent.self] == source.components[AttachmentComponent.self])
    }
    @Test func builderSupportsConditionalAndRepeatedDefinitions() {
        @GameAttachmentBuilder func definitions(_ includes: Bool) -> [GameAttachment] {
            GameAttachment(id: "one") { Text("One") }
            if includes { GameAttachment(id: "two") { context in Text(context.entity.name) } }
            for index in 0..<2 { GameAttachment(id: "row-\(index)") { Text("Row") } }
        }
        #expect(definitions(true).map(\.id) == ["one", "two", "row-0", "row-1"])
        #expect(definitions(false).map(\.id) == ["one", "row-0", "row-1"])
    }
    @Test func nonScenePointersCreateMissesAndPreventFalseSinglePointerCaptures() {
        let (host, target, _) = InputSafetyTests().host()
        let point = CGPoint(x: 50, y: 100)
        host.beginInput(at: point, sceneTargetAllowed: false)
        #expect(TargetedInputCapture<Int>().resolve(1, start: point, host: host, resolver: { $0 }) == nil)
        host.cancelInputs(); host.beginInput(at: point)
        host.beginInput(at: CGPoint(x: 150, y: 100), sceneTargetAllowed: false)
        #expect(TargetedInputCapture<Int>().resolve(1, start: nil, host: host, resolver: { $0 }) == nil)
        #expect(target.isActive)
    }
    @Test func restorationKeepsIDsButCreatesNewViewIdentityAndRebindsSharedAnchors() throws {
        let host = GameHost(); host.renderer.size = CGSize(width: 200, height: 200)
        host.attachmentStore.configure(["label"])
        let original = try #require(host.content.attachments.entity(for: "label"))
        original.components[AttachmentComponent.self]?.isInteractive = true
        host.world.addEntity(original); host.attachmentStore.refresh()
        let before = try projection(host), oldContext = try context(host, original)
        host.world.restore(host.world.snapshot()); host.renderer.flush(); host.attachmentStore.refresh()
        let restored = try #require(host.content.attachments.entity(for: "label")), after = try projection(host)
        #expect(restored !== original && restored.id == original.id && restored.world === host.world)
        #expect(before.id != after.id && !oldContext.isValid)
    }
    @Test func clippedContentCannotHitOutsideTheGameViewEvenWhenItsViewOverflows() throws {
        let (host, anchor) = fixture(interactive: true)
        anchor.position = [-95, 0]; host.renderer.flush(); host.attachmentStore.refresh()
        let p = try projection(host), size = CGSize(width: 80, height: 40)
        let path = p.hitPath(for: size)
        let inverse = p.transform(for: size).inverted()
        #expect(path.contains(CGPoint(x: 5, y: 100).applying(inverse)))
        #expect(!path.contains(CGPoint(x: -5, y: 100).applying(inverse)))
        #expect(!path.contains(CGPoint(x: 5, y: 250).applying(inverse)))
    }
}
