@_spi(Backend) import ECSCore
import Foundation
@testable import GameUI
import SpriteBackend
import SwiftUI
import Testing

@MainActor @Suite struct ViewportAttachmentTests {
    private func fixture(interactive: Bool = true) -> (GameHost, Entity, Entity, Entity) {
        let host = GameHost(); host.renderer.size = CGSize(width: 200, height: 200)
        let a = Entity(components: CameraComponent()), b = Entity(components: CameraComponent())
        host.world.addEntity(a); host.world.addEntity(b)
        host.renderer.viewports = [
            GameViewport(id: "left", camera: a.id, frame: .init(x: 0, y: 0, width: 0.5, height: 1)),
            GameViewport(id: "right", camera: b.id, frame: .init(x: 0.5, y: 0, width: 0.5, height: 1))]
        host.attachmentStore.configure(["label"])
        let anchor = Entity(components: AttachmentComponent(id: "label", isInteractive: interactive))
        host.world.addEntity(anchor); host.renderer.flush(); host.attachmentStore.refresh()
        return (host, anchor, a, b)
    }

    private func projection(_ host: GameHost, _ viewportID: String) throws -> AttachmentProjection {
        try #require(host.attachmentStore.presentations.first { $0.id.viewportID == viewportID })
    }

    private func context(_ host: GameHost, _ entity: Entity, _ pane: String) throws -> AttachmentContext {
        AttachmentContext(entity: entity, store: host.attachmentStore, identity: try projection(host, pane).id)
    }

    @Test func componentDecodesOldPayloadsAndPreservesViewportThroughSnapshotsAndClones() throws {
        let legacy = try JSONDecoder().decode(AttachmentComponent.self, from: Data(#"{"attachmentID":"label"}"#.utf8))
        #expect(legacy.viewportID == nil && legacy.isEnabled && !legacy.isInteractive)
        AttachmentComponent.registerComponent()
        let component = AttachmentComponent(id: "label", offset: [4, 5], anchor: .bottomTrailing, sizing: .scene,
                                            isInteractive: true, viewportID: "right")
        let original = Entity(components: component)
        let clone = original.clone()
        let restored = try JSONDecoder().decode(EntitySnapshot.self, from: JSONEncoder().encode(original.snapshot())).makeEntity()
        #expect(restored.components[AttachmentComponent.self] == component)
        #expect(clone.components[AttachmentComponent.self] == component)
        #expect(try JSONDecoder().decode(AttachmentComponent.self, from: JSONEncoder().encode(legacy)) == legacy)
    }

    @Test func allPaneAnchorsHaveDistinctSwiftUIIdentitiesAndPublicPaneContexts() throws {
        let (host, anchor, _, _) = fixture()
        let left = try projection(host, "left"), right = try projection(host, "right")
        #expect(host.attachmentStore.presentations.count == 2)
        #expect(left.id != right.id && left.id.entityID == right.id.entityID)
        #expect(left.entity === anchor && right.entity === anchor)
        #expect(left.position == CGPoint(x: 50, y: 100) && right.position == CGPoint(x: 150, y: 100))
        #expect(try context(host, anchor, "left").viewportID == "left")
        #expect(try context(host, anchor, "right").viewportID == "right")
        let oldIdentity = AttachmentIdentity(entityID: anchor.id, instance: ObjectIdentifier(anchor), activation: anchor.activationRevision, definition: 1)
        #expect(oldIdentity.viewportID == nil)
    }

    @Test func explicitPaneSelectionRestrictsProjectionAndInvalidatesOtherContexts() throws {
        let (host, anchor, _, _) = fixture()
        let leftContext = try context(host, anchor, "left")
        anchor.components[AttachmentComponent.self]?.viewportID = "right"
        #expect(!leftContext.isValid)
        host.attachmentStore.refresh()
        #expect(host.attachmentStore.presentations.map(\.id.viewportID) == ["right"])
        anchor.components[AttachmentComponent.self]?.viewportID = "missing"
        host.attachmentStore.refresh()
        #expect(host.attachmentStore.presentations.isEmpty)
    }

    @Test func measuredSizesBelongToIndividualPaneInstances() throws {
        let (host, _, _, _) = fixture()
        let left = try projection(host, "left"), right = try projection(host, "right")
        host.attachmentStore.reportSize(CGSize(width: 80, height: 40), for: left.id)
        host.attachmentStore.reportSize(CGSize(width: 10, height: 10), for: right.id)
        #expect(host.attachmentStore.blocksInput(at: CGPoint(x: 70, y: 100)))
        #expect(!host.attachmentStore.blocksInput(at: CGPoint(x: 170, y: 100)))
        #expect(host.attachmentStore.blocksInput(at: right.position))
    }

    @Test func contentAndHitPathsClipToOffsetPaneRectangles() throws {
        let (host, anchor, _, _) = fixture()
        anchor.components[AttachmentComponent.self]?.viewportID = "right"
        host.attachmentStore.refresh()
        let p = try projection(host, "right"), size = CGSize(width: 180, height: 80)
        host.attachmentStore.reportSize(size, for: p.id)
        let path = p.hitPath(for: size), inverse = p.transform(for: size).inverted()
        #expect(path.contains(CGPoint(x: 110, y: 100).applying(inverse)))
        #expect(!path.contains(CGPoint(x: 90, y: 100).applying(inverse)))
        #expect(!path.contains(CGPoint(x: 210, y: 100).applying(inverse)))
        #expect(p.contains(CGPoint(x: 110, y: 100), size: size))
        #expect(!p.contains(CGPoint(x: 90, y: 100), size: size))
        #expect(!host.attachmentStore.blocksInput(at: CGPoint(x: 90, y: 100)))
        #expect(host.attachmentStore.blocksInput(at: CGPoint(x: 110, y: 100)))
    }

    @Test func overflowFromOnePlayerCannotBlockTheOtherPlayer() throws {
        let (host, anchor, _, _) = fixture()
        anchor.components[AttachmentComponent.self]?.viewportID = "left"
        host.attachmentStore.refresh()
        let left = try projection(host, "left")
        host.attachmentStore.reportSize(CGSize(width: 300, height: 100), for: left.id)
        #expect(host.attachmentStore.blocksInput(at: CGPoint(x: 90, y: 100)))
        #expect(!host.attachmentStore.blocksInput(at: CGPoint(x: 110, y: 100)))
    }

    @Test func overlappingPanesCoverLowerAttachmentsRegardlessOfTheirEntityZ() throws {
        let (host, anchor, camera, _) = fixture()
        host.renderer.viewports = [GameViewport(id: "back", camera: camera.id),
            GameViewport(id: "front", camera: camera.id, frame: .init(x: 0.25, y: 0.25, width: 0.5, height: 0.5))]
        anchor.components[AttachmentComponent.self]?.viewportID = "back"
        anchor.transform.zPosition = 10_000
        host.renderer.flush(); host.attachmentStore.refresh()
        let back = try projection(host, "back"), size = CGSize(width: 180, height: 180)
        host.attachmentStore.reportSize(size, for: back.id)
        let path = back.hitPath(for: size), inverse = back.transform(for: size).inverted()
        #expect(path.contains(CGPoint(x: 25, y: 100).applying(inverse)))
        #expect(!path.contains(CGPoint(x: 100, y: 100).applying(inverse)))
        #expect(host.attachmentStore.blocksInput(at: CGPoint(x: 25, y: 100)))
        #expect(!host.attachmentStore.blocksInput(at: CGPoint(x: 100, y: 100)))
        anchor.components[AttachmentComponent.self]?.viewportID = nil
        host.attachmentStore.refresh()
        #expect(host.attachmentStore.presentations.map(\.id.viewportID) == ["back", "front"])
    }

    @Test func noninteractiveMinimapCannotRunAttachmentActionsOrClickThroughToWorld() throws {
        let (host, anchor, camera, _) = fixture()
        host.renderer.viewports = [GameViewport(id: "back", camera: camera.id),
            GameViewport(id: "map", camera: camera.id, frame: .init(x: 0.25, y: 0.25, width: 0.5, height: 0.5), isInteractive: false)]
        host.attachmentStore.refresh()
        let map = try projection(host, "map"), back = try projection(host, "back")
        host.attachmentStore.reportSize(CGSize(width: 180, height: 100), for: back.id)
        host.attachmentStore.reportSize(CGSize(width: 180, height: 100), for: map.id)
        #expect(!map.interactive && back.interactive)
        #expect(!(try context(host, anchor, "map")).perform { $0.name = "unexpected" })
        #expect(host.attachmentStore.blocksInput(at: CGPoint(x: 25, y: 100)))
        #expect(!host.attachmentStore.blocksInput(at: CGPoint(x: 100, y: 100)))
        let target = Entity(components: SpriteComponent(color: .red, size: [200, 200]), InputTargetComponent())
        host.world.addEntity(target)
        host.beginInput(at: CGPoint(x: 100, y: 100))
        #expect(host.contact(startingAt: nil)?.hit == nil)
    }

    @Test func eachProjectionUsesItsOwnPresentedCameraAndFullAffineTransform() throws {
        let (host, anchor, camera, otherCamera) = fixture()
        let parent = Entity(); parent.scale = [2, 3]; parent.rotation = 0.4
        host.world.addEntity(parent); parent.addChild(anchor)
        anchor.rotation = 0.7; anchor.components[AttachmentComponent.self]?.offset = [4, 5]
        otherCamera.position = [20, 30]; otherCamera.rotation = 0.3
        otherCamera.components[CameraComponent.self]?.zoom = 2
        camera.position = [-10, 5]
        host.renderer.flush(); host.attachmentStore.refresh()
        #expect(try projection(host, "left").basis == .identity)
        #expect(try projection(host, "right").basis == .identity)
        anchor.components[AttachmentComponent.self]?.sizing = .scene
        host.attachmentStore.refresh()
        for pane in ["left", "right"] {
            let p = try projection(host, pane)
            let origin = try #require(host.renderer.viewPoint(from: [4, 5], relativeTo: anchor, inViewport: pane))
            let x = try #require(host.renderer.viewPoint(from: [5, 5], relativeTo: anchor, inViewport: pane))
            let y = try #require(host.renderer.viewPoint(from: [4, 4], relativeTo: anchor, inViewport: pane))
            #expect(p.position == origin)
            #expect(abs(p.basis.a - (x.x - origin.x)) < 0.0001 && abs(p.basis.b - (x.y - origin.y)) < 0.0001)
            #expect(abs(p.basis.c - (y.x - origin.x)) < 0.0001 && abs(p.basis.d - (y.y - origin.y)) < 0.0001)
            #expect(abs(p.basis.a * p.basis.c + p.basis.b * p.basis.d) > 0.1)
        }
        #expect(try projection(host, "left").basis != projection(host, "right").basis)
    }

    @Test func removingAndReaddingAPaneDoesNotReviveOldContextsOrMeasuredSizes() throws {
        let (host, anchor, _, _) = fixture()
        let left = try projection(host, "left"), old = try context(host, anchor, "left")
        let original = host.renderer.viewports
        host.attachmentStore.reportSize(CGSize(width: 80, height: 40), for: left.id)
        host.renderer.viewports.removeFirst(); host.attachmentStore.refresh()
        #expect(!old.isValid)
        host.renderer.viewports = original; host.attachmentStore.refresh()
        let fresh = try projection(host, "left")
        #expect(fresh.id != left.id && !old.isValid)
        #expect(!host.attachmentStore.blocksInput(at: fresh.position))
        #expect((try context(host, anchor, "left")).perform { $0.name = "fresh" })
    }

    @Test func replacingAndRestoringAPaneCameraPermanentlyRetiresItsOldContext() throws {
        let (host, anchor, camera, _) = fixture()
        let old = try context(host, anchor, "left"), identity = try projection(host, "left").id
        let replacement = Entity(components: CameraComponent())
        host.world.addEntity(replacement)
        host.renderer.viewports[0].camera = replacement.id
        #expect(!old.isValid)
        host.attachmentStore.refresh()
        #expect(try projection(host, "left").id != identity)
        host.renderer.viewports[0].camera = camera.id; host.attachmentStore.refresh()
        #expect(!old.isValid)
        #expect(try context(host, anchor, "left").isValid)
    }

    @Test func cameraRemovalAndReactivationCreateFreshPaneIdentity() throws {
        let (host, anchor, camera, _) = fixture()
        let old = try context(host, anchor, "left")
        camera.removeFromParent()
        #expect(!old.isValid)
        host.world.addEntity(camera); host.renderer.flush(); host.attachmentStore.refresh()
        #expect(!old.isValid)
        #expect(try context(host, anchor, "left").isValid)
        let active = try context(host, anchor, "left")
        camera.isEnabled = false
        #expect(!active.isValid)
        camera.isEnabled = true; host.renderer.flush(); host.attachmentStore.refresh()
        #expect(!active.isValid)
    }

    @Test func automaticCameraSwitchInvalidatesOldActionsButCameraMotionKeepsPaneState() throws {
        let (host, anchor, camera, replacement) = fixture()
        host.renderer.viewports[0].camera = nil; host.world.activeCamera = camera
        host.attachmentStore.refresh()
        let old = try context(host, anchor, "left"), identity = try projection(host, "left").id
        camera.position = [20, 30]; camera.components[CameraComponent.self]?.zoom = 2
        host.renderer.flush(); host.attachmentStore.refresh()
        #expect(old.isValid)
        #expect(try projection(host, "left").id == identity)
        host.world.activeCamera = replacement
        #expect(!old.isValid)
        host.attachmentStore.refresh()
        host.world.activeCamera = camera; host.attachmentStore.refresh()
        #expect(!old.isValid)
    }

    @Test func legacySingleViewUsesOneProjectionAndNilContextViewport() throws {
        let (host, anchor, _, _) = fixture()
        host.renderer.viewports = []; host.attachmentStore.refresh()
        let p = try #require(host.attachmentStore.presentations.first)
        let context = AttachmentContext(entity: anchor, store: host.attachmentStore, identity: p.id)
        #expect(host.attachmentStore.presentations.count == 1 && p.id.viewportID == nil && context.viewportID == nil)
        #expect(p.position == CGPoint(x: 100, y: 100) && context.isValid)
        host.attachmentStore.reportSize(CGSize(width: 40, height: 20), for: p.id)
        #expect(host.attachmentStore.blocksInput(at: p.position))
    }

    @Test func explicitlyConfiguredEmptyListHasAMainPaneContext() throws {
        let host = GameHost(); host.renderer.size = CGSize(width: 200, height: 200)
        host.configureViewports([])
        host.attachmentStore.configure(["label"])
        let anchor = Entity(components: AttachmentComponent(id: "label"))
        host.world.addEntity(anchor); host.attachmentStore.refresh()
        #expect(host.attachmentStore.presentations.count == 1)
        #expect(try context(host, anchor, "main").viewportID == "main")
    }
}
