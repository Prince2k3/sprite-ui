@_spi(Backend) import ECSCore
import Foundation
@testable import GameUI
import SpriteBackend
import SpriteKit
import SwiftUI
import Testing

@MainActor @Suite struct VisibilityAttachmentTests {
    private let map = RenderLayer(rawValue: 1 << 1)

    private func fixture(scoped: Bool = true, beforeObservers: ((GameHost) -> Void)? = nil) -> (GameHost, Entity, Entity, Entity) {
        let host = GameHost(); host.renderer.size = CGSize(width: 200, height: 200)
        let camera = Entity(components: CameraComponent(cullingMask: .default))
        let other = Entity(components: CameraComponent(cullingMask: map))
        host.world.addEntity(camera); host.world.addEntity(other); host.world.activeCamera = camera
        if scoped {
            host.renderer.viewports = [
                GameViewport(id: "world", camera: camera.id, frame: .init(x: 0, y: 0, width: 0.5, height: 1)),
                GameViewport(id: "map", camera: other.id, frame: .init(x: 0.5, y: 0, width: 0.5, height: 1))
            ]
        }
        beforeObservers?(host)
        host.attachmentStore.configure(["label"])
        let anchor = Entity(components: AttachmentComponent(id: "label", isInteractive: true))
        host.world.addEntity(anchor); host.renderer.flush(); host.renderer.didFinishUpdate()
        return (host, anchor, camera, other)
    }

    private func projection(_ host: GameHost, _ pane: String? = nil) throws -> AttachmentProjection {
        try #require(host.attachmentStore.presentations.first { $0.id.viewportID == pane })
    }

    private func context(_ host: GameHost, _ entity: Entity, _ pane: String? = nil) throws -> AttachmentContext {
        AttachmentContext(entity: entity, store: host.attachmentStore, identity: try projection(host, pane).id)
    }

    @Test func legacyPayloadAndUnmarkedAnchorsRemainVisibleWithAnyNonemptyCameraMask() throws {
        let decoded = try JSONDecoder().decode(AttachmentComponent.self, from: Data(#"{"attachmentID":"label"}"#.utf8))
        #expect(decoded.isEnabled && !decoded.isInteractive && decoded.viewportID == nil)
        let (host, anchor, camera, _) = fixture(scoped: false)
        let old = try context(host, anchor)
        camera.components[CameraComponent.self]?.cullingMask = map
        #expect(old.isValid && host.attachmentStore.presentations.count == 1)
        anchor.components.set(VisibilityComponent())
        #expect(host.attachmentStore.presentations.isEmpty && !old.isValid)
        anchor.components.remove(VisibilityComponent.self)
        #expect(host.attachmentStore.presentations.count == 1 && !old.isValid)
        #expect(try context(host, anchor).isValid)
        camera.components[CameraComponent.self]?.cullingMask = .none
        #expect(host.attachmentStore.presentations.isEmpty)
    }

    @Test func projectionsAndActionsUseEachPanesEffectiveVisibilityDespitePrimaryHiddenFlags() throws {
        let (host, anchor, _, _) = fixture()
        anchor.components.set(VisibilityComponent(layers: map))
        host.renderer.didFinishUpdate()
        #expect(try #require(host.renderer.node(for: anchor)).isHidden)
        #expect(!host.renderer.isPresentationHidden(try #require(host.renderer.node(for: anchor))))
        #expect(host.attachmentStore.presentations.map(\.id.viewportID) == ["map"])
        let overview = try projection(host, "map")
        host.attachmentStore.reportSize(CGSize(width: 40, height: 20), for: overview.id)
        #expect(host.attachmentStore.blocksInput(at: overview.position))
        #expect(!host.attachmentStore.blocksInput(at: CGPoint(x: 50, y: 100)))
        #expect((try context(host, anchor, "map")).perform { $0.name = "visible map" })
        host.renderer.viewports[1].cullingMask = .default
        #expect(!(try context(host, anchor, "map")).isValid)
        #expect(!host.attachmentStore.blocksInput(at: overview.position))
        host.attachmentStore.refresh()
        #expect(host.attachmentStore.presentations.isEmpty)
    }

    @Test func hideShowEventsRetireOnlyTheAffectedPaneAndItsMeasuredInputArea() throws {
        let (host, anchor, camera, _) = fixture()
        anchor.components.set(VisibilityComponent(layers: [.default, map]))
        let world = try context(host, anchor, "world"), overview = try context(host, anchor, "map")
        let before = try projection(host, "world"), mapBefore = try projection(host, "map")
        host.attachmentStore.reportSize(CGSize(width: 40, height: 20), for: before.id)
        host.attachmentStore.reportSize(CGSize(width: 40, height: 20), for: mapBefore.id)
        camera.components[CameraComponent.self]?.cullingMask = .none
        camera.components[CameraComponent.self]?.cullingMask = .default
        let after = try projection(host, "world")
        #expect(!world.isValid && overview.isValid)
        #expect(after.id != before.id)
        #expect(try projection(host, "map").id == mapBefore.id)
        #expect(!host.attachmentStore.blocksInput(at: after.position))
        #expect(host.attachmentStore.blocksInput(at: mapBefore.position))
        #expect(!world.perform { $0.name = "stale" })
        #expect((try context(host, anchor, "world")).perform { $0.name = "fresh" })
    }

    @Test func hierarchyGatesCannotBeEscapedAndNeutralParentsAllowIndependentArtwork() throws {
        let (host, anchor, _, _) = fixture()
        let parent = Entity(components: VisibilityComponent(layers: .default))
        host.world.addEntity(parent); parent.addChild(anchor)
        anchor.components.set(VisibilityComponent(layers: map))
        host.attachmentStore.refresh()
        #expect(host.attachmentStore.presentations.isEmpty)
        parent.components[VisibilityComponent.self]?.layers = [.default, map]
        #expect(host.attachmentStore.presentations.map(\.id.viewportID) == ["map"])
        let old = try context(host, anchor, "map")
        parent.components[VisibilityComponent.self]?.isVisible = false
        parent.components[VisibilityComponent.self]?.isVisible = true
        #expect(!old.isValid)
        parent.components.remove(VisibilityComponent.self)
        #expect(try context(host, anchor, "map").isValid)
        anchor.components[VisibilityComponent.self]?.layers = .none
        #expect(host.attachmentStore.presentations.isEmpty)
    }

    @Test func observedNativeHidingAndComponentRemovalNeverReviveStaleContexts() throws {
        let (host, anchor, _, _) = fixture(scoped: false)
        let native = try #require(host.renderer.node(for: anchor)), old = try context(host, anchor)
        native.isHidden = true
        #expect(!old.isValid)
        native.isHidden = false; host.attachmentStore.refresh()
        #expect(!old.isValid)
        let shown = try context(host, anchor)
        anchor.components.remove(AttachmentComponent.self)
        anchor.components.set(AttachmentComponent(id: "label", isInteractive: true))
        #expect(!shown.isValid)
        #expect(try context(host, anchor).isValid)
    }

    @Test func visibleCameraMotionAndMaskChangesPreserveContextsAndMeasurements() throws {
        let (host, anchor, camera, _) = fixture()
        anchor.components.set(VisibilityComponent(layers: [.default, map]))
        let old = try context(host, anchor, "world"), before = try projection(host, "world")
        host.attachmentStore.reportSize(CGSize(width: 40, height: 20), for: before.id)
        camera.position = [10, 5]; camera.components[CameraComponent.self]?.zoom = 2
        camera.components[CameraComponent.self]?.cullingMask = [.default, map]
        host.renderer.flush(); host.renderer.didFinishUpdate()
        let after = try projection(host, "world")
        #expect(old.isValid && before.id == after.id && before.position != after.position)
        #expect(host.attachmentStore.blocksInput(at: after.position))
    }

    @Test func noninteractivePanesStillPresentVisibleContentButCannotRunActions() throws {
        let (host, anchor, _, _) = fixture()
        anchor.components.set(VisibilityComponent(layers: map))
        host.renderer.viewports[1].isInteractive = false; host.attachmentStore.refresh()
        let p = try projection(host, "map"), overview = try context(host, anchor, "map")
        #expect(overview.isValid && !p.interactive)
        #expect(!overview.perform { $0.name = "unexpected" })
        host.attachmentStore.reportSize(CGSize(width: 40, height: 20), for: p.id)
        #expect(!host.attachmentStore.blocksInput(at: p.position))
    }

    @Test func snapshotsPreserveVisibilityAndViewportWhileReplacingActionContexts() throws {
        let (host, anchor, _, _) = fixture()
        anchor.components.set(VisibilityComponent(layers: map))
        anchor.components[AttachmentComponent.self]?.viewportID = "map"
        host.attachmentStore.refresh()
        let old = try context(host, anchor, "map")
        let snapshot = try JSONDecoder().decode(WorldSnapshot.self, from: JSONEncoder().encode(host.world.snapshot()))
        #expect(anchor.clone().components[VisibilityComponent.self] == VisibilityComponent(layers: map))
        host.world.restore(snapshot); host.renderer.flush(); host.attachmentStore.refresh()
        let restored = try #require(host.world.entity(withID: anchor.id))
        #expect(restored !== anchor && restored.components[VisibilityComponent.self]?.layers == map)
        #expect(restored.components[AttachmentComponent.self]?.viewportID == "map")
        #expect(!old.isValid && !old.perform { $0.name = "stale" })
        #expect(host.attachmentStore.presentations.map(\.id.viewportID) == ["map"])
        #expect((try context(host, restored, "map")).perform { $0.name = "restored" })
        restored.components[VisibilityComponent.self]?.isVisible = false
        let hiddenSnapshot = host.world.snapshot()
        host.world.restore(hiddenSnapshot); host.renderer.flush(); host.attachmentStore.refresh()
        #expect(host.attachmentStore.presentations.isEmpty)
    }

    @Test func staleCallbackAfterSamePaneMaskReplacementCannotRetireFreshContextOrSize() throws {
        let (host, anchor, _, _) = fixture()
        let old = try context(host, anchor, "world"), before = try projection(host, "world")
        let mapBefore = try projection(host, "map"), overview = try context(host, anchor, "map")
        host.renderer.viewports[0].cullingMask = .default
        host.attachmentStore.refresh()
        let after = try projection(host, "world"), fresh = try context(host, anchor, "world")
        host.attachmentStore.reportSize(CGSize(width: 40, height: 20), for: after.id)
        #expect(before.id != after.id && fresh.isValid)
        #expect(!old.perform { $0.name = "stale" })
        #expect(fresh.isValid && overview.isValid)
        #expect(host.attachmentStore.blocksInput(at: after.position))
        #expect(try projection(host, "world").id == after.id)
        #expect(try projection(host, "map").id == mapBefore.id)
        #expect(fresh.perform { $0.name = "fresh" })
    }

    @Test func reentrantCancellationCannotReviveAttachmentContextsOrMeasuredRegions() throws {
        var input: GameManipulationInput?
        let (host, anchor, _, _) = fixture(beforeObservers: { input = GameManipulationInput(host: $0) })
        let nativeInput = try #require(input)
        anchor.components.set(SpriteComponent(color: .red, size: [40, 40]))
        anchor.components.set(InputTargetComponent()); anchor.components.set(ManipulationComponent())
        anchor.components.set(VisibilityComponent(layers: .default))
        host.renderer.flush(); host.attachmentStore.refresh()
        let old = try context(host, anchor, "world"), before = try projection(host, "world")
        // Start outside the measured UI, then let its retained measurement arrive.
        #expect(nativeInput.admitContact(1, at: before.position))
        #expect(nativeInput.begin(.pan, contacts: [1]))
        host.attachmentStore.reportSize(CGSize(width: 40, height: 20), for: before.id)
        let token = host.world.subscribe(to: ManipulationEvents.Cancelled.self) { event in
            if event.entity === anchor { anchor.components[VisibilityComponent.self]?.isVisible = true }
        }
        defer { token.cancel() }
        anchor.components[VisibilityComponent.self]?.isVisible = false
        #expect(anchor.components[VisibilityComponent.self]?.isVisible == true)
        #expect(!old.isValid && !old.perform { $0.name = "stale" })
        let after = try projection(host, "world")
        #expect(after.id != before.id)
        #expect(!host.attachmentStore.blocksInput(at: after.position))
        #expect((try context(host, anchor, "world")).perform { $0.name = "fresh" })
    }

    @Test func earlierVisibilitySubscriberCannotReviveAttachmentAfterReentrantShow() throws {
        var token: EventSubscription?
        let (host, anchor, _, _) = fixture(beforeObservers: { host in
            token = host.world.subscribe(to: VisibilityEvents.DidChange.self) { event in
                if event.entity.components[VisibilityComponent.self]?.isVisible == false {
                    event.entity.components[VisibilityComponent.self]?.isVisible = true
                }
            }
        })
        defer { token?.cancel() }
        anchor.components.set(VisibilityComponent(layers: [.default, map]))
        let old = try context(host, anchor, "world"), before = try projection(host, "world")
        host.attachmentStore.reportSize(CGSize(width: 40, height: 20), for: before.id)
        anchor.components[VisibilityComponent.self]?.isVisible = false
        #expect(anchor.components[VisibilityComponent.self]?.isVisible == true)
        #expect(!old.isValid && !old.perform { $0.name = "stale" })
        let after = try projection(host, "world")
        #expect(after.id != before.id)
        #expect(!host.attachmentStore.blocksInput(at: after.position))
        #expect((try context(host, anchor, "world")).perform { $0.name = "fresh" })
    }

    @Test func reentrantCameraMaskHidingRetiresOnlyTheHiddenPane() throws {
        var token: EventSubscription?
        let (host, anchor, camera, _) = fixture(beforeObservers: { host in
            token = host.world.subscribe(to: VisibilityEvents.DidChange.self) { event in
                if event.entity.components[CameraComponent.self]?.cullingMask == RenderLayer.none {
                    event.entity.components[CameraComponent.self]?.cullingMask = .default
                }
            }
        })
        defer { token?.cancel() }
        let old = try context(host, anchor, "world"), overview = try context(host, anchor, "map")
        let before = try projection(host, "world"), mapBefore = try projection(host, "map")
        host.attachmentStore.reportSize(CGSize(width: 40, height: 20), for: before.id)
        camera.components[CameraComponent.self]?.cullingMask = .none
        #expect(!old.isValid && overview.isValid)
        #expect(try projection(host, "world").id != before.id)
        #expect(try projection(host, "map").id == mapBefore.id)
        #expect(!host.attachmentStore.blocksInput(at: before.position))
        #expect((try context(host, anchor, "world")).perform { $0.name = "fresh" })
    }

    @Test func reentrantContinuouslyVisibleCameraEditsKeepAttachmentContextAndSize() throws {
        var token: EventSubscription?
        let (host, anchor, camera, _) = fixture(beforeObservers: { host in
            token = host.world.subscribe(to: VisibilityEvents.DidChange.self) { event in
                if event.entity.components[CameraComponent.self]?.cullingMask == RenderLayer.all {
                    event.entity.components[CameraComponent.self]?.cullingMask = .default
                }
            }
        })
        defer { token?.cancel() }
        let old = try context(host, anchor, "world"), before = try projection(host, "world")
        host.attachmentStore.reportSize(CGSize(width: 40, height: 20), for: before.id)
        camera.components[CameraComponent.self]?.cullingMask = .all
        #expect(old.isValid)
        #expect(try projection(host, "world").id == before.id)
        #expect(host.attachmentStore.blocksInput(at: before.position))
    }
}
