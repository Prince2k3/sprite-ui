import ECSCore
@testable import GameUI
import SpriteBackend
import SwiftUI
import Testing

@MainActor @Suite struct SceneDebugTests {
    func fixture() -> (GameHost, Entity, SceneDebugController) {
        let host = GameHost()
        host.renderer.size = CGSize(width: 402, height: 874)
        host.viewFrame = CGRect(x: 30, y: 60, width: 402, height: 874)
        let entity = Entity(name: "target", components:
            SpriteComponent(color: .blue, size: [100, 100]), InputTargetComponent())
        host.world.addEntity(entity)
        let controller = SceneDebugController()
        host.configureDebugController(controller)
        host.renderer.flush()
        controller.refresh()
        return (host, entity, controller)
    }

    @Test func bothGameViewInitializersAcceptAnOptionalDebugController() {
        let controller = SceneDebugController()
        _ = GameView(debug: controller) { _ in }
        _ = GameView(debug: controller) { _ in } attachments: {
            GameAttachment(id: "label") { Text("Label") }
        }
        _ = GameView { _ in }
        #expect(!controller.isAttached)
    }

    @Test func separateGameViewsKeepControllerSelectionAndInputIsolated() {
        let (first, a, debugA) = fixture(), (second, b, debugB) = fixture()
        #expect(debugA.scene === first.world && debugB.scene === second.world)
        first.setDebugPicking(true)
        #expect(first.pickDebugEntity(atView: CGPoint(x: 201, y: 437)) == a.id)
        #expect(debugA.selectedEntityID == a.id && debugB.selectedEntityID == nil)
        let point = CGPoint(x: 201, y: 437)
        first.beginInput(at: point); second.beginInput(at: point)
        #expect(TargetedInputCapture<Int>().resolve(1, start: point, host: first, resolver: { $0 }) == nil)
        #expect(TargetedInputCapture<Int>().resolve(1, start: point, host: second, resolver: { $0 })?.entity === b)
        #expect(!debugA.select(b))
        #expect(debugA.scene === first.world)
    }

    @Test func sharingAControllerKeepsFirstBindingAndForeignCleanupCannotDetachIt() {
        let (first, entity, controller) = fixture()
        let second = GameHost()
        second.configureDebugController(controller)
        #expect(first.activeDebugController === controller)
        #expect(second.activeDebugController == nil)
        #expect(second.renderer.debugController == nil)
        second.setDebugPicking(true)
        second.reportDebugPanel(CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(!second.isDebugPicking && second.debugInput.panelFrame == nil)
        second.setDebugVisible(false)
        #expect(controller.isAttached && controller.scene === first.world)
        #expect(controller.select(entity))
        first.setDebugVisible(false)
        second.setDebugVisible(true)
        #expect(controller.scene === second.world)
        first.setDebugVisible(false)
        #expect(controller.scene === second.world)
    }

    @Test func rejectedReplacementCannotLeaveHiddenDebuggingActive() {
        let (first, _, a) = fixture(), (second, _, b) = fixture()
        #expect(first.world.isProfilingEnabled)
        first.configureDebugController(b)
        #expect(first.activeDebugController == nil && first.renderer.debugController == nil)
        #expect(!first.world.isProfilingEnabled && !a.isAttached)
        #expect(b.scene === second.world && second.activeDebugController === b)
        #expect(first.renderer.children.allSatisfy { $0.name != "__sceneDebug" })
    }

    @Test func panelsBlockNativeAndSwiftUIGesturesUsingGlobalGeometry() {
        let (host, entity, _) = fixture()
        let point = CGPoint(x: 201, y: 437)
        let prior = host.beginInput(at: point); host.endInput(prior)
        #expect(TargetedInputCapture<Int>().resolve(1, start: point, host: host, resolver: { $0 })?.entity === entity)
        host.reportDebugPanel(CGRect(x: 220, y: 480, width: 80, height: 60))
        #expect(host.debugPanelContains(point))
        // A SwiftUI control can arrive without a new native contact.
        #expect(TargetedInputCapture<Int>().resolve(2, start: point, host: host, resolver: { $0 }) == nil)
        #expect(TargetedInputCapture<Int>().resolve(2, start: nil, host: host, resolver: { $0 }) == nil)
        host.cancelInputs(); host.beginInput(at: point)
        #expect(host.contact(startingAt: point)?.hit == nil)
        #expect(TargetedInputCapture<Int>().resolve(3, start: nil, host: host, resolver: { $0 }) == nil)
        // Use the latest host position when converting the recorded global panel.
        host.viewFrame.origin = CGPoint(x: 130, y: 60)
        #expect(!host.debugPanelContains(point))
        #expect(host.debugPanelContains(CGPoint(x: 101, y: 437)))
    }

    @Test func anExistingGameplayDragSurvivesAPanelMovingOverItsStart() {
        let (host, entity, _) = fixture()
        let point = CGPoint(x: 201, y: 437)
        host.beginInput(at: point)
        let capture = TargetedInputCapture<Int>()
        #expect(capture.resolve(1, start: point, host: host, resolver: { $0 })?.entity === entity)
        host.reportDebugPanel(CGRect(x: 220, y: 480, width: 80, height: 60))
        #expect(capture.resolve(2, start: point, host: host, resolver: { $0 })?.entity === entity)
        host.setDebugPicking(true)
        #expect(capture.resolve(3, start: point, host: host, resolver: { $0 }) == nil)
    }

    @Test func explicitPickingSuppressesOldCapturesAndChoosesTheFrontEntity() {
        let (host, entity, controller) = fixture()
        let point = CGPoint(x: 201, y: 437)
        host.beginInput(at: point)
        let capture = TargetedInputCapture<Int>()
        #expect(capture.resolve(1, start: point, host: host, resolver: { $0 })?.entity === entity)
        #expect(host.pickDebugEntity(atView: point) == nil)
        #expect(controller.selectedEntityID == nil)
        let front = Entity(name: "front", components: SpriteComponent(color: .red, size: [60, 60]))
        front.components[Transform.self]?.zPosition = 10
        host.world.addEntity(front); host.renderer.flush()
        host.setDebugPicking(true)
        #expect(capture.resolve(2, start: point, host: host, resolver: { $0 }) == nil)
        #expect(host.pickDebugEntity(atView: point) == front.id)
        host.beginInput(at: point)
        #expect(host.contact(startingAt: point)?.hit == nil)
        host.setDebugPicking(false)
        host.beginInput(at: point)
        #expect(TargetedInputCapture<Int>().resolve(3, start: point, host: host, resolver: { $0 })?.entity === entity)
    }

    @Test func simulationControlsNeverSelectAnEntityBehindTheirPanel() {
        let (host, entity, controller) = fixture()
        #expect(controller.select(entity))
        host.setDebugPicking(true)
        host.reportDebugPanel(CGRect(x: 200, y: 450, width: 160, height: 100))
        let point = CGPoint(x: 201, y: 437)
        #expect(host.pickDebugEntity(atView: point) == nil)
        #expect(controller.selectedEntityID == entity.id)
        controller.isPaused = true
        #expect(controller.canStep)
        #expect(controller.stepFrame())
        #expect(controller.isStepPending && !controller.canStep)
        #expect(!controller.stepFrame())
    }

    @Test func interactiveAttachmentsKeepPriorityOverPicking() throws {
        let (host, _, controller) = fixture()
        host.attachmentStore.configure(["button"])
        let anchor = try #require(host.content.attachments.entity(for: "button"))
        anchor.components[AttachmentComponent.self]?.isInteractive = true
        host.world.addEntity(anchor); host.renderer.flush(); host.attachmentStore.refresh()
        let projection = try #require(host.attachmentStore.presentations.first)
        host.attachmentStore.reportSize(CGSize(width: 120, height: 50), for: projection.id)
        host.setDebugPicking(true)
        #expect(host.attachmentStore.blocksInput(at: projection.position))
        #expect(host.pickDebugEntity(atView: projection.position) == nil)
        #expect(controller.selectedEntityID == nil)
        anchor.components[AttachmentComponent.self]?.isInteractive = false
        host.attachmentStore.refresh()
        #expect(host.pickDebugEntity(atView: projection.position) != nil)
    }

    @Test func disappearanceAndControllerReplacementClearRegionsPickingAndContacts() {
        let (host, _, original) = fixture()
        host.setDebugPicking(true)
        host.reportDebugPanel(CGRect(x: 200, y: 450, width: 160, height: 100))
        host.beginInput(at: CGPoint(x: 201, y: 437))
        host.setDebugVisible(false)
        #expect(!original.isAttached && original.scene == nil)
        #expect(!host.isDebugPicking && host.debugInput.panelFrame == nil && host.inputContacts.isEmpty)
        // Representable updates after disappearance must not reattach.
        host.configureDebugController(original)
        #expect(!original.isAttached)
        host.setDebugVisible(true)
        #expect(original.scene === host.world)
        host.setDebugPicking(true)
        let replacement = SceneDebugController(options: [.statistics])
        host.configureDebugController(replacement)
        #expect(!original.isAttached && replacement.scene === host.world)
        #expect(!host.isDebugPicking && host.debugInput.panelFrame == nil)
        host.configureDebugController(nil)
        #expect(!replacement.isAttached && host.activeDebugController == nil)
    }

    @Test func inactiveHostsAndSelectionOptionChangesCannotKeepPicking() {
        let (host, _, controller) = fixture()
        host.setDebugPicking(true)
        host.reportDebugPanel(CGRect(x: 200, y: 450, width: 160, height: 100))
        host.setDebugInputActive(false)
        #expect(!host.isDebugPicking && host.debugInput.panelFrame == nil)
        #expect(host.pickDebugEntity(atView: CGPoint(x: 201, y: 437)) == nil)
        host.setDebugInputActive(true)
        #expect(!host.isDebugPicking)
        host.setDebugPicking(true)
        controller.options.remove(.selection)
        #expect(!host.isDebugPicking)
        #expect(host.pickDebugEntity(atView: CGPoint(x: 201, y: 437)) == nil)
    }

    @Test func stoppingPresentationDetachesAndClearsInput() {
        let (host, _, controller) = fixture()
        host.setDebugPicking(true)
        // Native dismantling and SwiftUI disappearance share this cleanup path.
        // No SKView/graphics context is needed to exercise it in unit tests.
        host.stopPresentation()
        #expect(!controller.isAttached && host.renderer.debugController == nil)
        #expect(!host.isDebugPicking && host.debugInput.panelFrame == nil)
    }

    @Test func invalidPanelFramesAndOutOfBoundsPicksAreIgnored() {
        let (host, entity, controller) = fixture()
        host.reportDebugPanel(.infinite)
        #expect(host.debugInput.panelFrame == nil)
        host.setDebugPicking(true)
        #expect(controller.select(entity))
        #expect(host.pickDebugEntity(atView: CGPoint(x: -1, y: 437)) == nil)
        #expect(controller.selectedEntityID == entity.id)
    }

    @Test func hidingEveryPanelOptionImmediatelyReleasesItsInputRegion() {
        let (host, _, controller) = fixture()
        let point = CGPoint(x: 201, y: 437)
        host.reportDebugPanel(CGRect(x: 220, y: 480, width: 80, height: 60))
        #expect(host.debugBlocksInput(at: point))
        controller.options = [.bounds]
        #expect(!host.debugBlocksInput(at: point))
    }
}
