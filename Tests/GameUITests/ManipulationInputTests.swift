import ECSCore
@testable import GameUI
import SpriteBackend
import SpriteKit
import SwiftUI
import Testing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor @Suite struct ManipulationInputTests {
    private let left = CGPoint(x: 50, y: 100)
    private let right = CGPoint(x: 150, y: 100)

    private func fixture() -> (GameHost, GameManipulationInput, Entity, Entity) {
        let host = GameHost()
        host.renderer.size = CGSize(width: 200, height: 200)
        let a = Entity(components: SpriteComponent(color: .red, size: [40, 40]),
                       InputTargetComponent(), ManipulationComponent())
        let b = Entity(components: SpriteComponent(color: .blue, size: [40, 40]),
                       InputTargetComponent(), ManipulationComponent())
        a.position = [-50, 0]; b.position = [50, 0]
        host.world.addEntity(a); host.world.addEntity(b); host.renderer.flush()
        let input = GameManipulationInput(host: host)
        host.manipulationInput = input
        return (host, input, a, b)
    }

    @Test func optInRoutingLeavesOrdinaryTargetedGesturesAvailable() {
        let (host, input, a, b) = fixture()
        defer { withExtendedLifetime(host) {} }
        b.components.remove(ManipulationComponent.self)
        #expect(!input.admitContact(1, at: .zero))
        #expect(!input.admitContact(2, at: right))
        host.beginInput(at: right)
        let targeted = TargetedInputCapture<Int>()
        #expect(targeted.resolve(1, start: right, host: host, resolver: { $0 })?.entity === b)
        #expect(input.admitContact(3, at: left))
        #expect(input.begin(.pan, contacts: [3]))
        #expect(input.session?.entity === a)
        input.finish(.pan)
    }

    @Test func frontmostPickableWithoutManipulationDoesNotClickThrough() {
        let (host, input, _, b) = fixture()
        defer { withExtendedLifetime(host) {} }
        b.position = [-50, 0]; b.transform.zPosition = 10
        b.components.remove(ManipulationComponent.self)
        host.renderer.flush()
        #expect(!input.admitContact(1, at: left))
        #expect(input.session == nil)
    }

    @Test func nearestAncestorIsStableAndDisabledNearestOwnerBlocksFallback() throws {
        let (host, input, a, _) = fixture()
        defer { withExtendedLifetime(host) {} }
        let child = Entity(components: SpriteComponent(color: .green, size: [20, 20]), ManipulationComponent())
        child.transform.zPosition = 10
        a.addChild(child); host.renderer.flush()
        #expect(input.admitContact(1, at: left))
        #expect(input.begin(.pan, contacts: [1]))
        let session = try #require(input.session)
        #expect(session.entity === child)
        #expect(input.change(.pan, translation: CGPoint(x: 15, y: -8)))
        #expect(child.position == [15, 8])
        #expect(a.position == [-50, 0])
        input.cancel()
        child.components[ManipulationComponent.self]?.isEnabled = false
        host.renderer.flush()
        #expect(!input.admitContact(2, at: CGPoint(x: 65, y: 92)))
    }

    @Test func disabledInputAndDisabledOperationsRejectRecognition() {
        let (host, input, a, _) = fixture()
        defer { withExtendedLifetime(host) {} }
        a.components[InputTargetComponent.self]?.isEnabled = false
        host.renderer.flush()
        #expect(!input.admitContact(1, at: left))
        a.components[InputTargetComponent.self]?.isEnabled = true
        a.components[ManipulationComponent.self]?.operations = [.rotation, .scale]
        host.renderer.flush()
        #expect(input.admitContact(2, at: left))
        #expect(!input.begin(.pan, contacts: [2]))
        #expect(input.begin(.rotation, contacts: [2]))
        input.cancel()
    }

    @Test func channelsComposeAndOnlyLastRecognizedChannelEndsCapture() throws {
        let (host, input, a, _) = fixture()
        defer { withExtendedLifetime(host) {} }
        var ended = 0
        let token = host.world.subscribe(to: ManipulationEvents.Ended.self) { _ in ended += 1 }
        #expect(input.admitContact(1, at: left))
        #expect(input.begin(.pan, contacts: [1]))
        let session = try #require(input.session)
        #expect(input.change(.pan, translation: CGPoint(x: 10, y: -5)))
        #expect(input.begin(.rotation, contacts: [1]))
        #expect(input.change(.rotation, rotation: .pi / 2))
        #expect(input.begin(.scale, contacts: [1]))
        #expect(input.change(.scale, scale: 2))
        #expect(a.position == [-40, 5])
        #expect(abs(a.rotation - .pi / 2) < 0.0001)
        #expect(a.scale == [2, 2])
        input.finish(.pan)
        #expect(session.isActive && ended == 0)
        #expect(input.change(.rotation, rotation: .pi))
        #expect(a.position == [-40, 5] && a.scale == [2, 2])
        input.finish(.rotation)
        #expect(session.isActive && ended == 0)
        input.finish(.scale)
        #expect(!session.isActive && input.session == nil && ended == 1)
        token.cancel()
    }

    @Test func unrelatedContactsCannotJoinOrStealACapture() throws {
        let (host, input, a, b) = fixture()
        defer { withExtendedLifetime(host) {} }
        #expect(input.admitContact(1, at: left))
        #expect(!input.admitContact(2, at: right))
        #expect(input.begin(.pan, contacts: [1]))
        #expect(!input.admitContact(3, at: right))
        #expect(!input.begin(.scale, contacts: [1, 3]))
        #expect(input.session?.entity === a)
        #expect(b.position == [50, 0])
        input.cancel()
        #expect(input.admitContact(4, at: right))
        #expect(input.begin(.pan, contacts: [4]))
        #expect(try #require(input.session).entity === b)
        input.cancel()
    }

    @Test func joiningAndLeavingFingersDoesNotMoveThePanAnchor() {
        let (host, input, a, _) = fixture()
        defer { withExtendedLifetime(host) {} }
        #expect(input.admitContact(1, at: left))
        #expect(input.begin(.pan, contacts: [1]))
        #expect(input.change(.pan, translation: CGPoint(x: 8, y: 0)))
        #expect(input.admitContact(2, at: CGPoint(x: 68, y: 100)))
        #expect(input.begin(.scale, contacts: [1, 2]))
        #expect(input.change(.scale, scale: 1))
        #expect(a.position == [-42, 0])
        input.releaseContact(2)
        input.finish(.scale)
        #expect(input.change(.pan, translation: CGPoint(x: 12, y: 0)))
        #expect(a.position == [-38, 0])
        input.finish(.pan)
    }

    @Test func restartedPanAccumulatesWhileAnotherChannelRemainsRecognized() {
        let (host, input, a, _) = fixture()
        defer { withExtendedLifetime(host) {} }
        #expect(input.admitContact(1, at: left))
        #expect(input.begin(.pan, contacts: [1]))
        #expect(input.begin(.scale, contacts: [1]))
        #expect(input.change(.pan, translation: CGPoint(x: 10, y: 0)))
        input.finish(.pan)
        #expect(input.begin(.pan, contacts: [1]))
        #expect(input.change(.pan, translation: CGPoint(x: 3, y: -2)))
        #expect(a.position == [-37, 2])
        // A duplicate/late end for an unrecognized channel cannot cancel scale.
        input.finish(.rotation, cancelled: true)
        #expect(input.session?.isActive == true)
        input.cancel()
    }

    @Test func everySampleUsesTheCurrentCamera() {
        let (host, input, a, _) = fixture()
        defer { withExtendedLifetime(host) {} }
        let camera = Entity(components: CameraComponent())
        host.world.addEntity(camera); host.renderer.flush()
        #expect(input.admitContact(1, at: left))
        #expect(input.begin(.pan, contacts: [1]))
        let initial = host.renderer.scenePoint(fromView: left)
        camera.position = [20, 30]
        camera.components[CameraComponent.self]?.zoom = 2
        host.renderer.flush()
        let expected = SIMD2<Float>(-50, 0)
            + host.renderer.scenePoint(fromView: CGPoint(x: 60, y: 90)) - initial
        #expect(input.change(.pan, translation: CGPoint(x: 10, y: -10)))
        #expect(a.position == expected)
        input.cancel()
    }

    @Test func controlsAndInteractiveAttachmentsBlockAdmission() throws {
        let (host, input, _, _) = fixture()
        defer { withExtendedLifetime(host) {} }
        #expect(!input.admitContact(1, at: left, sceneTargetAllowed: false))
        host.attachmentStore.configure(["button"])
        let anchor = try #require(host.content.attachments.entity(for: "button"))
        anchor.position = [-50, 0]
        anchor.components[AttachmentComponent.self]?.isInteractive = true
        host.world.addEntity(anchor); host.renderer.flush(); host.attachmentStore.refresh()
        let projection = try #require(host.attachmentStore.presentations.first)
        host.attachmentStore.reportSize(CGSize(width: 40, height: 40), for: projection.id)
        #expect(host.attachmentStore.blocksInput(at: left))
        #expect(!input.admitContact(2, at: left))
        anchor.components[AttachmentComponent.self]?.isInteractive = false
        host.attachmentStore.refresh()
        #expect(input.admitContact(3, at: left))
        input.cancel()
    }

    @Test func renderingReprojectsAStationaryPointerAfterCameraMovement() throws {
        let (host, input, a, _) = fixture()
        defer { withExtendedLifetime(host) {} }
        let camera = Entity(components: CameraComponent())
        host.world.addEntity(camera); host.renderer.flush()
        #expect(input.admitContact(1, at: left))
        #expect(input.begin(.pan, contacts: [1]))
        var changed = 0
        let token = host.world.subscribe(to: ManipulationEvents.Changed.self) { _ in changed += 1 }
        camera.position = [30, 20]
        camera.components[CameraComponent.self]?.zoom = 2
        host.renderer.update(1); host.renderer.didFinishUpdate()
        let projected = try #require(host.renderer.viewPoint(from: a.scenePosition))
        #expect(abs(projected.x - left.x) < 0.001 && abs(projected.y - left.y) < 0.001)
        #expect(changed == 1)
        host.renderer.update(2); host.renderer.didFinishUpdate()
        #expect(changed == 1)
        input.cancel(); token.cancel()
    }

    @Test func renderingReprojectsAStationaryPointerAfterParentMovement() throws {
        let (host, input, a, _) = fixture()
        defer { withExtendedLifetime(host) {} }
        let parent = Entity()
        host.world.addEntity(parent); parent.addChild(a); host.renderer.flush()
        #expect(input.admitContact(1, at: left))
        #expect(input.begin(.pan, contacts: [1]))
        parent.position = [20, 30]; parent.rotation = .pi / 4
        host.renderer.update(1); host.renderer.didFinishUpdate()
        let projected = try #require(host.renderer.viewPoint(from: a.scenePosition))
        #expect(abs(projected.x - left.x) < 0.001 && abs(projected.y - left.y) < 0.001)
        #expect(input.session?.isActive == true)
        input.cancel()
    }

    @Test func debugPanelAndPickingBlockAndCancelManipulation() {
        let (host, input, _, _) = fixture()
        defer { withExtendedLifetime(host) {} }
        let debug = SceneDebugController()
        host.configureDebugController(debug)
        host.reportDebugPanel(CGRect(x: 30, y: 80, width: 40, height: 40))
        #expect(!input.admitContact(1, at: left))
        host.debugInput.panelFrame = nil
        #expect(input.admitContact(2, at: left))
        #expect(input.begin(.pan, contacts: [2]))
        host.setDebugPicking(true)
        #expect(input.session == nil && input.activeChannels.isEmpty)
        #expect(!input.admitContact(3, at: left))
    }

    @Test func hostCancellationRestoresNativeDynamicsWithoutEditingConfiguration() throws {
        let (host, input, a, _) = fixture()
        defer { withExtendedLifetime(host) {} }
        let configuration = PhysicsBodyComponent(shape: .rectangle(size: [40, 40]), velocity: [8, 3], angularVelocity: 2)
        a.components.set(configuration)
        a.components[ManipulationComponent.self]?.physicsRelease = .restoreVelocity
        host.renderer.flush()
        #expect(input.admitContact(1, at: left))
        #expect(input.begin(.pan, contacts: [1]))
        let session = try #require(input.session)
        let body = try #require(host.renderer.node(for: a)?.physicsBody)
        #expect(!body.isDynamic)
        #expect(a.components[PhysicsBodyComponent.self] == configuration)
        host.beginInput(at: left)
        host.cancelInputs()
        #expect(!session.isActive && input.session == nil && input.activeChannels.isEmpty)
        #expect(host.inputContacts.isEmpty && body.isDynamic)
        #expect(a.components[PhysicsBodyComponent.self] == configuration)
        #expect(body.velocity == CGVector(dx: 8, dy: 3) && body.angularVelocity == 2)
    }

    @Test func cancellationRejectsReentrantCaptureAndClearsBeforePublishing() {
        let (host, input, _, _) = fixture()
        defer { withExtendedLifetime(host) {} }
        var sawCancellation = false
        var accepted = false
        let token = host.world.subscribe(to: ManipulationEvents.Cancelled.self) { _ in
            sawCancellation = input.session == nil && input.activeChannels.isEmpty
            accepted = input.admitContact(2, at: self.left)
            host.cancelInputs()
        }
        #expect(input.admitContact(1, at: left))
        #expect(input.begin(.pan, contacts: [1]))
        host.cancelInputs()
        #expect(sawCancellation && !accepted)
        #expect(input.admitContact(3, at: left))
        token.cancel(); input.cancel()
    }

    @Test func cancellationWhileBeginningCannotLeaveAnOrphanSession() {
        let (host, input, _, _) = fixture()
        defer { withExtendedLifetime(host) {} }
        let token = host.world.subscribe(to: ManipulationEvents.Began.self) { _ in host.cancelInputs() }
        #expect(input.admitContact(1, at: left))
        #expect(!input.begin(.pan, contacts: [1]))
        #expect(input.session == nil && input.activeChannels.isEmpty)
        token.cancel()
        #expect(input.admitContact(2, at: left))
        #expect(input.begin(.pan, contacts: [2]))
        input.cancel()
    }

    @Test func losingTheOriginalHitCannotRetargetAnotherEntity() {
        let (host, input, a, b) = fixture()
        defer { withExtendedLifetime(host) {} }
        #expect(input.admitContact(1, at: left))
        #expect(input.begin(.pan, contacts: [1]))
        a.components[InputTargetComponent.self]?.isEnabled = false
        b.position = [-50, 0]
        host.renderer.flush()
        #expect(!input.change(.pan, translation: CGPoint(x: 5, y: 0)))
        #expect(input.session == nil && b.position == [-50, 0])
        #expect(!input.begin(.pan, contacts: [1]))
    }

    @Test func anAdmittedContactCannotCaptureAReplacementBeforeRecognition() {
        let (host, input, a, b) = fixture()
        defer { withExtendedLifetime(host) {} }
        #expect(input.admitContact(1, at: left))
        a.position = [0, 70]; b.position = [-50, 0]
        host.renderer.flush()
        #expect(!input.begin(.pan, contacts: [1]))
        #expect(input.session == nil && b.position == [-50, 0])
        input.releaseContact(1)
        #expect(input.admitContact(2, at: left))
        #expect(input.begin(.pan, contacts: [2]))
        #expect(input.session?.entity === b)
        input.cancel()
    }

    @Test func viewDetachAndPresentationDisappearanceCancelEveryChannel() throws {
        let (host, input, _, _) = fixture()
        defer { withExtendedLifetime(host) {} }
        let view = GameSKView(); view.host = host
        input.attach(to: view)
#if os(macOS)
        #expect(view.gestureRecognizers.count == 3)
#else
        #expect(view.gestureRecognizers?.count == 3)
#endif
        #expect(input.admitContact(1, at: left))
        #expect(input.begin(.pan, contacts: [1]))
        #expect(input.begin(.rotation, contacts: [1]))
        let first = try #require(input.session)
        input.detach()
        #expect(!first.isActive && input.activeChannels.isEmpty)
#if os(macOS)
        #expect(view.gestureRecognizers.isEmpty)
#else
        #expect(view.gestureRecognizers?.isEmpty != false)
#endif
        #expect(input.admitContact(2, at: left))
        #expect(input.begin(.scale, contacts: [2]))
        let second = try #require(input.session)
        host.stopPresentation()
        #expect(!second.isActive && input.session == nil)
        #expect(!input.admitContact(3, at: left))
    }

    @Test func independentViewsHaveIndependentCaptureGroups() {
        let (first, inputA, a, _) = fixture()
        let (second, inputB, b, _) = fixture()
        defer { withExtendedLifetime(second) {} }
        #expect(inputA.admitContact(1, at: left))
        #expect(inputB.admitContact(1, at: left))
        #expect(inputA.begin(.pan, contacts: [1]))
        #expect(inputB.begin(.pan, contacts: [1]))
        #expect(inputA.change(.pan, translation: CGPoint(x: 5, y: 0)))
        #expect(inputB.change(.pan, translation: CGPoint(x: 9, y: 0)))
        #expect(a.position == [-45, 0] && b.position == [-41, 0])
        first.cancelInputs()
        #expect(inputA.session == nil && inputB.session?.isActive == true)
        inputB.cancel()
    }

    @Test func nativeFocusAndApplicationNotificationsCancelCapture() throws {
        let (host, input, _, _) = fixture()
        defer { withExtendedLifetime(host) {} }
        let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let view = SKView(frame: frame)
#if os(macOS)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
#else
        let window = UIWindow(frame: frame)
        window.addSubview(view)
#endif
        input.attach(to: view)
        defer { input.detach() }
        #expect(input.admitContact(1, at: left))
        #expect(input.begin(.pan, contacts: [1]))
        let focused = try #require(input.session)
#if os(macOS)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
#else
        NotificationCenter.default.post(name: UIWindow.didResignKeyNotification, object: window)
#endif
        #expect(!focused.isActive && input.session == nil)
        #expect(input.admitContact(2, at: left))
        #expect(input.begin(.scale, contacts: [2]))
        let foreground = try #require(input.session)
#if os(macOS)
        NotificationCenter.default.post(name: NSApplication.willResignActiveNotification, object: nil)
#else
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
#endif
        #expect(!foreground.isActive && input.activeChannels.isEmpty)
    }

    @Test func invalidSamplesDoNotPoisonLaterValidSamples() {
        let (host, input, a, _) = fixture()
        defer { withExtendedLifetime(host) {} }
        #expect(input.admitContact(1, at: left))
        #expect(input.begin(.pan, contacts: [1]))
        #expect(input.begin(.rotation, contacts: [1]))
        #expect(input.begin(.scale, contacts: [1]))
        let original = a.transform
        #expect(!input.change(.pan, translation: CGPoint(x: CGFloat.nan, y: 0)))
        #expect(!input.change(.rotation, rotation: .infinity))
        #expect(!input.change(.scale, scale: 0))
        #expect(!input.change(.scale, scale: .nan))
        #expect(a.transform == original)
        #expect(input.change(.scale, scale: 1.5))
        #expect(a.scale == [1.5, 1.5])
        input.cancel()
    }
}
