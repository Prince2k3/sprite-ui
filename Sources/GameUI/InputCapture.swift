@_spi(Backend) import ECSCore
import Foundation
import SpriteBackend
import SwiftUI

/// A view-scoped preference binds a targeted gesture to its own GameView even
/// when modifiers such as frame/padding sit between the view and the gesture.
struct GameHostReference: Equatable, Sendable {
    let id: UUID
    weak var host: GameHost?
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}
struct GameHostPreferenceKey: PreferenceKey {
    static let defaultValue: [GameHostReference] = []
    static func reduce(value: inout [GameHostReference], nextValue: () -> [GameHostReference]) { value += nextValue() }
}

@MainActor
struct InputViewportLatch {
    let viewport: GameViewport
    let cameraID: Entity.ID?
    private weak var camera: Entity?
    private let cameraActivation: UInt64?

    init(viewport: GameViewport, renderer: SpriteRenderer) {
        self.viewport = viewport
        cameraID = viewport.camera ?? renderer.activeCamera?.id
        let resolved = cameraID.flatMap { renderer.world.entity(withID: $0) }
        camera = resolved
        cameraActivation = resolved?.activationRevision
    }

    func isValid(in renderer: SpriteRenderer) -> Bool {
        guard renderer.resolvedViewports.contains(viewport), viewport.isInteractive,
              (viewport.camera ?? renderer.activeCamera?.id) == cameraID else { return false }
        guard let cameraID else { return true }
        return camera === renderer.world.entity(withID: cameraID) && camera?.activationRevision == cameraActivation
    }
}

@MainActor
final class InputContact {
    let id: UInt64
    let start: CGPoint
    let activationRevision: UInt64?
    let viewportID: String?
    var viewportLatch: InputViewportLatch?
    weak var hit: Entity?
    var endedAt: TimeInterval?
    var cancelled = false
    init(id: UInt64, start: CGPoint, hit: Entity?, viewportID: String? = nil) {
        self.id = id; self.start = start; self.hit = hit; self.viewportID = viewportID
        activationRevision = hit?.activationRevision
    }

    func hasValidViewport(in host: GameHost) -> Bool {
        let valid = viewportLatch?.isValid(in: host.renderer)
            ?? (host.inputScenePoint(fromView: start, viewportID: viewportID) != nil)
        if !valid { cancelled = true }
        return valid
    }
}

extension GameHost {
    /// An explicitly empty viewport configuration still presents the `main` pane.
    var usesScopedViewports: Bool { configuredViewports != nil || !renderer.viewports.isEmpty }

    @discardableResult
    func beginInput(at point: CGPoint, sceneTargetAllowed: Bool = true) -> UInt64 {
        nextInputID &+= 1
        let viewport = renderer.viewport(at: point)
        let viewportID = usesScopedViewports ? viewport?.id : nil
        let blocked = !sceneTargetAllowed || !attachmentStore.acceptsInput || attachmentStore.blocksInput(at: point)
            || debugBlocksInput(at: point) || viewport == nil
        let scene = blocked ? nil : inputScenePoint(fromView: point, viewportID: viewportID)
        let hit = scene.flatMap { renderer.inputTarget(at: CGPoint(scenePoint: $0)) }
        let contact = InputContact(id: nextInputID, start: point, hit: hit, viewportID: viewportID)
        if let viewport, viewportID != nil { contact.viewportLatch = InputViewportLatch(viewport: viewport, renderer: renderer) }
        let now = ProcessInfo.processInfo.systemUptime
        inputContacts = inputContacts.filter { $0.value.endedAt.map { now - $0 < 0.5 } ?? true }
        inputContacts[contact.id] = contact
        return contact.id
    }
    /// A latched pointer may leave its pane, but never switch to another camera.
    func inputScenePoint(fromView point: CGPoint, viewportID: String?) -> SIMD2<Float>? {
        if let viewportID {
            guard renderer.resolvedViewports.contains(where: { $0.id == viewportID && $0.isInteractive }) else { return nil }
            return renderer.scenePoint(fromView: point, inViewport: viewportID)
        }
        guard !usesScopedViewports, point.x.isFinite, point.y.isFinite else { return nil }
        return renderer.scenePoint(fromView: point)
    }
    func endInput(_ id: UInt64, cancelled: Bool = false) {
        guard let contact = inputContacts[id] else { return }
        contact.endedAt = ProcessInfo.processInfo.systemUptime
        contact.cancelled = contact.cancelled || cancelled
    }
    func cancelInputs() {
        guard !isCancellingInputs else { return }
        isCancellingInputs = true
        defer { isCancellingInputs = false }
        for contact in inputContacts.values { contact.cancelled = true }
        inputContacts.removeAll()
        manipulationInput?.cancel()
        renderer.cancelManipulations()
        if let nativeInputSession { nativeInputSession.cancelFromHost() }
        else { actionInput?.cancelAll() }
    }
    func contact(startingAt start: CGPoint?, after completedID: UInt64 = 0) -> InputContact? {
        let now = ProcessInfo.processInfo.systemUptime
        let recent = inputContacts.values.filter {
            $0.id > completedID && !$0.cancelled && ($0.endedAt.map { now - $0 < 0.5 } ?? true)
        }
        let matches: [InputContact]
        if let start {
            guard let viewport = renderer.viewport(at: start) else { return nil }
            let viewportID = usesScopedViewports ? viewport.id : nil
            matches = recent.filter { $0.viewportID == viewportID && hypot($0.start.x - start.x, $0.start.y - start.y) <= 22 }
        } else { matches = Array(recent) }
        let live = matches.filter { $0.endedAt == nil }
        // If a gesture can't identify its pointer unambiguously, don't deliver
        // the event to an arbitrary entity or another GameView.
        let candidates = live.isEmpty ? matches : live
        guard candidates.count == 1 else { return nil }
        return candidates.first
    }
}

private extension CGPoint {
    init(scenePoint point: SIMD2<Float>) { self.init(x: CGFloat(point.x), y: CGFloat(point.y)) }
}

/// Each attached targeted gesture has its own latch. Capturing one finger never
/// overwrites another gesture's target. Removal, disabling, cancellation, or a
/// reparent that changes the resolved target cancels delivery for this gesture.
@MainActor
final class TargetedInputCapture<Value> {
    private var contact: InputContact?
    private weak var target: Entity?
    private weak var sourceHost: GameHost?
    private var attemptedCapture = false
    private var completedContacts: [UUID: UInt64] = [:]

    func resolve(_ value: Value, start: CGPoint?, host: GameHost?, resolver: (Entity) -> Entity?) -> EntityTargetValue<Value>? {
        guard let host else { return nil }
        // A control may not create an SKView contact at all. Reject its starting
        // region before considering any recent scene contact at that location.
        if host.isDebugPicking { return nil }
        if !attemptedCapture, let start,
           host.attachmentStore.blocksInput(at: start) || host.debugBlocksInput(at: start) {
            attemptedCapture = true; sourceHost = host; target = nil; return nil
        }
        if let contact, contact.cancelled { end() }
        if !attemptedCapture {
            guard let input = host.contact(startingAt: start, after: completedContacts[host.inputHostID] ?? 0) else { return nil }
            attemptedCapture = true
            sourceHost = host; contact = input
            if let hit = input.hit, !host.debugBlocksInput(at: input.start) { target = resolver(hit) }
        }
        guard sourceHost === host, let contact, !contact.cancelled, contact.hasValidViewport(in: host),
              let hit = contact.hit, hit.world === host.world, hit.isInputTarget,
              hit.activationRevision == contact.activationRevision,
              hit.components[CollisionComponent.self]?.isEnabled != false,
              // Only a fallback controller supplies this hit's interaction shape.
              (hit.components[CollisionComponent.self] != nil || hit.components[PhysicsBodyComponent.self] != nil ||
               hit.components[CharacterControllerComponent.self]?.isEnabled != false),
              let target, target.world === host.world, target.isActive, resolver(hit) === target else {
            target = nil
            return nil
        }
        var result = EntityTargetValue(entity: target, gestureValue: value, host: host, viewportID: contact.viewportID)
        result.viewportLatch = contact.viewportLatch
        result.contact = contact
        return result
    }

    func end() {
        if let contact, let sourceHost {
            completedContacts[sourceHost.inputHostID] = max(completedContacts[sourceHost.inputHostID] ?? 0, contact.id)
        }
        contact = nil; target = nil; sourceHost = nil; attemptedCapture = false
    }
}

#if os(iOS) || os(tvOS) || os(visionOS)
import UIKit

/// Observes UIKit contacts without recognizing a competing gesture or cancelling
/// SwiftUI input. The observer stays possible until every finger has lifted.
final class GameInputRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    weak var host: GameHost?
    weak var coordinateView: UIView?
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    private var contacts: [ObjectIdentifier: UInt64] = [:]

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let coordinateView, let host, coordinateView.window != nil, host.attachmentStore.acceptsInput else { return }
        for touch in touches {
            let point = touch.location(in: coordinateView)
            guard coordinateView.bounds.contains(point) else { continue }
            let sceneHit = touch.view?.isDescendant(of: coordinateView) == true
            contacts[ObjectIdentifier(touch)] = host.beginInput(at: point, sceneTargetAllowed: sceneHit)
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {}
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, cancelled: true) }
    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        for touch in touches {
            host?.manipulationInput?.releaseTouch(touch, cancelled: cancelled)
            if let id = contacts.removeValue(forKey: ObjectIdentifier(touch)) { host?.endInput(id, cancelled: cancelled) }
        }
        if contacts.isEmpty { state = .failed }
    }
    override func reset() {
        cancelTrackedContacts()
        super.reset()
    }
    func cancelTrackedContacts() {
        for id in contacts.values { host?.endInput(id, cancelled: true) }
        contacts.removeAll()
    }
}
#endif
