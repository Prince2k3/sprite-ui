@_spi(Backend) import ECSCore
import SpriteBackend
import SpriteKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One capture group per native game surface. Additional fingers/channels may
/// join only the same nearest manipulation ancestor. Other targets keep their
/// normal SwiftUI input. No public gesture modifier is required.
@MainActor
final class GameManipulationInput: NSObject {
    enum Channel: Hashable {
        case pan, rotation, scale
        var operation: ManipulationComponent.Operations {
            switch self {
            case .pan: .translation
            case .rotation: .rotation
            case .scale: .scale
            }
        }
    }

    private struct Contact {
        let point: CGPoint
        let hit: Entity
        let target: Entity
        let revision: UInt64
    }

    weak var host: GameHost?
    private weak var view: SKView?
    private(set) var session: ManipulationSession?
    private(set) var activeChannels: Set<Channel> = []
    private var contacts: [UInt64: Contact] = [:]
    private var capturedContact: Contact?
    private var nextContact: UInt64 = 0
    private var channelContacts: [Channel: Set<UInt64>] = [:]
    private var anchor = CGPoint.zero
    private var initialScenePoint = SIMD2<Float>.zero
    private var viewTranslation = CGPoint.zero
    private var panBase = CGPoint.zero
    private var rotation: Float = 0
    private var rotationBase: Float = 0
    private var scale: Float = 1
    private var scaleBase: Float = 1
    private var generation: UInt64 = 0
    private var isBeginning = false
    private var isCancelling = false
    private var isApplyingSample = false
    private var frameSubscription: EventSubscription?
    private var observers: [NSObjectProtocol] = []
#if os(macOS)
    private var recognizers: [NSGestureRecognizer] = []
    private var admissionEventTime: TimeInterval?
#else
    private var recognizers: [UIGestureRecognizer] = []
    private var touchIDs: [ObjectIdentifier: UInt64] = [:]
#endif

    init(host: GameHost) {
        self.host = host
        super.init()
        frameSubscription = host.world.subscribe(to: RenderingEvents.DidUpdate.self) { [weak self] _ in
            self?.refreshCapture()
        }
    }

    // These entry points also accept simulated samples, without native hardware.
    @discardableResult
    func admitContact(_ id: UInt64, at point: CGPoint, sceneTargetAllowed: Bool = true) -> Bool {
        guard !isCancelling, !isBeginning, !isApplyingSample, sceneTargetAllowed, let host, !host.isCancellingInputs,
              point.x.isFinite, point.y.isFinite,
              CGRect(origin: .zero, size: host.renderer.size).contains(point),
              host.attachmentStore.acceptsInput, !host.attachmentStore.blocksInput(at: point),
              !host.debugBlocksInput(at: point) else { return false }
        if let contact = contacts[id] { return valid(contact) }
        let scene = host.renderer.scenePoint(fromView: point)
        guard let hit = host.renderer.inputTarget(at: CGPoint(x: CGFloat(scene.x), y: CGFloat(scene.y))),
              let target = manipulationTarget(for: hit),
              session.map({ $0.isActive && $0.entity === target }) ?? true,
              contacts.values.allSatisfy({ $0.target === target }) else { return false }
        contacts[id] = Contact(point: point, hit: hit, target: target, revision: hit.activationRevision)
        return true
    }

    func releaseContact(_ id: UInt64, cancelled: Bool = false) {
        let owned = contacts.removeValue(forKey: id) != nil
        if owned && cancelled { cancel() }
    }

    @discardableResult
    func begin(_ channel: Channel, contacts ids: Set<UInt64>) -> Bool {
        guard !isCancelling, !isBeginning, !isApplyingSample, !activeChannels.contains(channel), let host, !host.isCancellingInputs,
              !ids.isEmpty else { return false }
        let admitted = ids.sorted().compactMap { contacts[$0] }
        guard admitted.count == ids.count, admitted.allSatisfy({ valid($0) }),
              let first = admitted.first,
              admitted.allSatisfy({ $0.target === first.target }),
              first.target.components[ManipulationComponent.self]?.operations.contains(channel.operation) == true else { return false }
        if let session {
            guard session.isActive, session.entity === first.target else { return false }
        } else {
            let revision = generation
            isBeginning = true
            let scene = host.renderer.scenePoint(fromView: first.point)
            let hit = host.renderer.inputTarget(at: CGPoint(x: CGFloat(scene.x), y: CGFloat(scene.y)))
            let created = hit.flatMap { manipulationTarget(for: $0) === first.target
                ? host.renderer.beginManipulation(at: scene) : nil }
            isBeginning = false
            guard revision == generation, let created, created.isActive, created.entity === first.target else {
                created?.cancel(); return false
            }
            session = created
            capturedContact = first
            anchor = first.point; initialScenePoint = scene
            viewTranslation = .zero; rotation = 0; scale = 1
        }
        activeChannels.insert(channel)
        switch channel {
        case .pan: panBase = viewTranslation
        case .rotation: rotationBase = rotation
        case .scale: scaleBase = scale
        }
        return true
    }

    @discardableResult
    func change(_ channel: Channel, translation: CGPoint = .zero, rotation: Float = 0, scale: Float = 1) -> Bool {
        guard !isCancelling, !isApplyingSample, activeChannels.contains(channel) else { return false }
        guard let session, session.isActive, let capturedContact, valid(capturedContact),
              let host, host.attachmentStore.acceptsInput, !host.isDebugPicking else {
            if session != nil { cancel() }
            return false
        }
        switch channel {
        case .pan:
            guard translation.x.isFinite, translation.y.isFinite else { return false }
            let value = CGPoint(x: panBase.x + translation.x, y: panBase.y + translation.y)
            guard value.x.isFinite, value.y.isFinite else { return false }
            viewTranslation = value
        case .rotation:
            guard rotation.isFinite, (rotationBase + rotation).isFinite else { return false }
            self.rotation = rotationBase + rotation
        case .scale:
            guard scale.isFinite, scale > 0, (scaleBase * scale).isFinite else { return false }
            self.scale = scaleBase * scale
        }
        return refreshCapture()
    }

    /// Reprojects a stationary pointer after the renderer settles its camera and
    /// displayed parent pose. Unchanged poses do not emit another Changed event.
    @discardableResult
    func refreshCapture() -> Bool {
        guard !isCancelling, !isApplyingSample, let session else { return false }
        guard session.isActive, let capturedContact, valid(capturedContact), let host else {
            cancel(); return false
        }
        isApplyingSample = true
        defer { isApplyingSample = false }
        // Use translation, never the changing pinch/pan centroid. Convert the
        // fixed view anchor through the CURRENT camera on every sample.
        let point = CGPoint(x: anchor.x + viewTranslation.x, y: anchor.y + viewTranslation.y)
        let displacement = host.renderer.scenePoint(fromView: point) - initialScenePoint
        let changed = session.update(translation: displacement, rotation: self.rotation, scale: self.scale)
        if self.session === session, !session.isActive { cancel() }
        return changed
    }

    func finish(_ channel: Channel, cancelled: Bool = false) {
        guard activeChannels.contains(channel) else { return }
        if cancelled { cancel(); return }
        activeChannels.remove(channel)
        guard activeChannels.isEmpty else { return }
        let completed = session
        session = nil; capturedContact = nil
        completed?.end()
    }

    func cancel() {
        guard !isCancelling else { return }
        isCancelling = true
        generation &+= 1
        let cancelled = session
        session = nil; capturedContact = nil
        activeChannels.removeAll(); contacts.removeAll(); channelContacts.removeAll()
#if !os(macOS)
        touchIDs.removeAll()
#endif
        // Disable only our recognizers, so held contacts cannot resume a capture
        // after focus/context cancellation. Other SwiftUI gestures stay intact.
        for recognizer in recognizers { recognizer.isEnabled = false }
        cancelled?.cancel()
        for recognizer in recognizers { recognizer.isEnabled = true }
        isCancelling = false
    }

    private func manipulationTarget(for hit: Entity) -> Entity? {
        var current: Entity? = hit
        while let entity = current {
            if let component = entity.components[ManipulationComponent.self] {
                return component.isEnabled && !component.operations.intersection(.all).isEmpty ? entity : nil
            }
            current = entity.parent
        }
        return nil
    }

    private func valid(_ contact: Contact) -> Bool {
        guard let host, host.attachmentStore.acceptsInput, !host.debugBlocksInput(at: contact.point),
              !host.attachmentStore.blocksInput(at: contact.point),
              contact.hit.world === host.world, contact.hit.isInputTarget,
              contact.hit.activationRevision == contact.revision,
              contact.hit.components[CollisionComponent.self]?.isEnabled != false,
              manipulationTarget(for: contact.hit) === contact.target else { return false }
        return true
    }

    func attach(to view: SKView) {
        if self.view === view { return }
        detach()
        self.view = view
#if os(macOS)
        recognizers = [NSPanGestureRecognizer(target: self, action: #selector(handle(_:))),
                       NSMagnificationGestureRecognizer(target: self, action: #selector(handle(_:))),
                       NSRotationGestureRecognizer(target: self, action: #selector(handle(_:)))]
        for recognizer in recognizers {
            recognizer.delegate = self
            recognizer.delaysPrimaryMouseButtonEvents = false
            recognizer.delaysMagnificationEvents = false; recognizer.delaysRotationEvents = false
            view.addGestureRecognizer(recognizer)
        }
#else
        recognizers = [UIPanGestureRecognizer(target: self, action: #selector(handle(_:))),
                       UIPinchGestureRecognizer(target: self, action: #selector(handle(_:))),
                       UIRotationGestureRecognizer(target: self, action: #selector(handle(_:)))]
        for recognizer in recognizers {
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false; recognizer.delaysTouchesEnded = false
            view.addGestureRecognizer(recognizer)
        }
#endif
        windowChanged()
    }

    func windowChanged() {
        cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        guard let window = view?.window else { return }
#if os(macOS)
        observe(NSWindow.didResignKeyNotification, object: window)
        observe(NSWindow.willCloseNotification, object: window)
        observe(NSApplication.willResignActiveNotification, object: nil)
#else
        observe(UIApplication.willResignActiveNotification, object: nil)
        observe(UIApplication.didEnterBackgroundNotification, object: nil)
        observe(UIWindow.didResignKeyNotification, object: window)
#endif
    }

    private func observe(_ name: Notification.Name, object: AnyObject?) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.host?.cancelInputs() }
        })
    }

    func detach() {
        cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        for recognizer in recognizers { recognizer.view?.removeGestureRecognizer(recognizer) }
        recognizers.removeAll(); view = nil
    }
}

#if os(macOS)
extension GameManipulationInput: NSGestureRecognizerDelegate {
    private func channel(for recognizer: NSGestureRecognizer) -> Channel {
        if recognizer is NSPanGestureRecognizer { return .pan }
        return recognizer is NSRotationGestureRecognizer ? .rotation : .scale
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        guard let view, event.window === view.window, !view.isHiddenOrHasHiddenAncestor else { return false }
        let channel = channel(for: gestureRecognizer)
        if channel == .pan, event.type != .leftMouseDown { return false }
        // Failed recognizers do not send an action. Drop their admission records
        // at the next native stream, so a miss cannot poison the next target.
        if activeChannels.isEmpty, admissionEventTime != event.timestamp {
            contacts.removeAll(); channelContacts.removeAll()
        }
        admissionEventTime = event.timestamp
        if let old = channelContacts.removeValue(forKey: channel) { for id in old { releaseContact(id) } }
        var point = view.convert(event.locationInWindow, from: nil)
        if !view.isFlipped { point.y = view.bounds.height - point.y }
        nextContact &+= 1
        let id = nextContact
        guard admitContact(id, at: point) else { return false }
        channelContacts[channel] = [id]
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        let channel = channel(for: gestureRecognizer)
        return begin(channel, contacts: channelContacts[channel] ?? [])
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool {
        // Never prevent unrelated targeted SwiftUI gestures/ancestor gestures.
        true
    }

    @objc private func handle(_ recognizer: NSGestureRecognizer) {
        let channel = channel(for: recognizer)
        switch recognizer.state {
        case .began, .changed, .ended:
            if let pan = recognizer as? NSPanGestureRecognizer, let view {
                var delta = pan.translation(in: view)
                if !view.isFlipped { delta.y = -delta.y }
                change(.pan, translation: delta)
            } else if let rotation = recognizer as? NSRotationGestureRecognizer {
                change(.rotation, rotation: Float(rotation.rotation))
            } else if let magnify = recognizer as? NSMagnificationGestureRecognizer {
                change(.scale, scale: Float(1 + magnify.magnification))
            }
            if recognizer.state == .ended {
                if let ids = channelContacts.removeValue(forKey: channel) { for id in ids { releaseContact(id) } }
                finish(channel)
            }
        case .cancelled, .failed: finish(channel, cancelled: true)
        default: break
        }
    }
}
#else
extension GameManipulationInput: UIGestureRecognizerDelegate {
    private func channel(for recognizer: UIGestureRecognizer) -> Channel {
        if recognizer is UIPanGestureRecognizer { return .pan }
        return recognizer is UIRotationGestureRecognizer ? .rotation : .scale
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view, !view.isHidden, view.window != nil,
              touch.view === view || touch.view?.isDescendant(of: view) == true else { return false }
        let key = ObjectIdentifier(touch)
        let id: UInt64
        if let existing = touchIDs[key] { id = existing }
        else { nextContact &+= 1; id = nextContact }
        guard admitContact(id, at: touch.location(in: view)) else { return false }
        touchIDs[key] = id
        channelContacts[channel(for: gestureRecognizer), default: []].insert(id)
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let channel = channel(for: gestureRecognizer)
        return begin(channel, contacts: channelContacts[channel] ?? [])
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    /// The existing passive window observer supplies contact release, including
    /// cancellation by the system. It never recognizes or consumes input itself.
    func releaseTouch(_ touch: UITouch, cancelled: Bool) {
        guard let id = touchIDs.removeValue(forKey: ObjectIdentifier(touch)) else { return }
        for channel in Array(channelContacts.keys) { channelContacts[channel]?.remove(id) }
        releaseContact(id, cancelled: cancelled)
    }

    @objc private func handle(_ recognizer: UIGestureRecognizer) {
        let channel = channel(for: recognizer)
        switch recognizer.state {
        case .began, .changed, .ended:
            if let pan = recognizer as? UIPanGestureRecognizer, let view {
                change(.pan, translation: pan.translation(in: view))
            } else if let rotation = recognizer as? UIRotationGestureRecognizer {
                // UIKit is clockwise-positive in its downward-y coordinates.
                change(.rotation, rotation: -Float(rotation.rotation))
            } else if let pinch = recognizer as? UIPinchGestureRecognizer {
                change(.scale, scale: Float(pinch.scale))
            }
            if recognizer.state == .ended { channelContacts[channel] = nil; finish(channel) }
        case .cancelled, .failed: finish(channel, cancelled: true)
        default: break
        }
    }
}
#endif
