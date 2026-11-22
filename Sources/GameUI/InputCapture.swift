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
final class InputContact {
    let id: UInt64
    let start: CGPoint
    let activationRevision: UInt64?
    weak var hit: Entity?
    var endedAt: TimeInterval?
    var cancelled = false
    init(id: UInt64, start: CGPoint, hit: Entity?) { self.id = id; self.start = start; self.hit = hit; activationRevision = hit?.activationRevision }
}

extension GameHost {
    @discardableResult
    func beginInput(at point: CGPoint) -> UInt64 {
        nextInputID &+= 1
        let hit = renderer.inputTarget(at: CGPoint(scenePoint: renderer.scenePoint(fromView: point)))
        let contact = InputContact(id: nextInputID, start: point, hit: hit)
        let now = ProcessInfo.processInfo.systemUptime
        inputContacts = inputContacts.filter { $0.value.endedAt.map { now - $0 < 0.5 } ?? true }
        inputContacts[contact.id] = contact
        return contact.id
    }
    func endInput(_ id: UInt64, cancelled: Bool = false) {
        inputContacts[id]?.endedAt = ProcessInfo.processInfo.systemUptime
        inputContacts[id]?.cancelled = cancelled
    }
    func cancelInputs() {
        for contact in inputContacts.values { contact.cancelled = true }
        inputContacts.removeAll()
    }
    func contact(startingAt start: CGPoint?, after completedID: UInt64 = 0) -> InputContact? {
        let now = ProcessInfo.processInfo.systemUptime
        let recent = inputContacts.values.filter {
            $0.id > completedID && !$0.cancelled && ($0.endedAt.map { now - $0 < 0.5 } ?? true)
        }
        let matches: [InputContact]
        if let start {
            matches = recent.filter { hypot($0.start.x - start.x, $0.start.y - start.y) <= 22 }
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
        if let contact, contact.cancelled { end() }
        if !attemptedCapture {
            guard let input = host.contact(startingAt: start, after: completedContacts[host.inputHostID] ?? 0) else { return nil }
            attemptedCapture = true
            sourceHost = host; contact = input
            if let hit = input.hit { target = resolver(hit) }
        }
        guard sourceHost === host, let contact, !contact.cancelled,
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
        return EntityTargetValue(entity: target, gestureValue: value, host: host)
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
final class GameInputRecognizer: UIGestureRecognizer {
    weak var host: GameHost?
    private var contacts: [ObjectIdentifier: UInt64] = [:]

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let view, let host else { return }
        for touch in touches { contacts[ObjectIdentifier(touch)] = host.beginInput(at: touch.location(in: view)) }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {}
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, cancelled: true) }
    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        for touch in touches {
            if let id = contacts.removeValue(forKey: ObjectIdentifier(touch)) { host?.endInput(id, cancelled: cancelled) }
        }
        if contacts.isEmpty { state = .failed }
    }
    override func reset() {
        for id in contacts.values { host?.endInput(id, cancelled: true) }
        contacts.removeAll()
        super.reset()
    }
}
#endif
