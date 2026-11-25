@_spi(Backend) import ECSCore
import Foundation
import SwiftUI

public extension View {
    /// Routes keyboard, pointer buttons and gamepads to a view-scoped action
    /// controller. Use one controller per host and `isActive` for menu scopes.
    /// Pointer buttons are observed without consuming gestures or button clicks.
    /// Gamepads are sampled at 60 Hz; controls held on activation must go neutral.
    /// Pass `hinge` to opt in to calibrated `.hinge` samples. Raw hinge telemetry
    /// remains available through GameViewContent even without action routing.
    /// Native hinge samples require supported physical hinge hardware; the
    /// configuration does not enable hinge input on devices without that sensor.
    func gameInput(_ input: InputController, isActive: Bool = true, hinge: HingeInputConfiguration? = nil) -> some View {
        modifier(GameInputModifier(input: input, hub: nil, isActive: isActive, hinge: hinge))
    }

    /// Routes native input to explicitly assigned player sessions. A hub can be
    /// attached to one host at a time; player assignment remains game policy.
    /// An opted-in hinge is discovered as `.hinge` and stays unassigned until the
    /// game assigns it. Reconnection and cancellation require physical neutral.
    /// Discovery requires a physical hinge with an OS-supported sensor.
    func gameInput(_ hub: PlayerInputHub, isActive: Bool = true, hinge: HingeInputConfiguration? = nil) -> some View {
        modifier(GameInputModifier(input: nil, hub: hub, isActive: isActive, hinge: hinge))
    }
}

@MainActor
struct GameInputAvailability {
    var visible = false
    var focused = false
    var sceneActive = false
    var scopeActive = true
    var windowActive = false
    var acceptsInput: Bool { visible && focused && sceneActive && scopeActive && windowActive }
}

/// Testable routing shared by SwiftUI and the native passive observers.
@MainActor
final class GameInputRouter {
    private(set) var input: InputController?
    private(set) var hub: PlayerInputHub?
    let backendOwner = UUID()
    private(set) var hasBackendLease = false
    private var active = false
    private var devices: Set<InputDevice> = []
    private var heldKeys: Set<String> = []
    private var heldButtons: Set<Int> = []
    private var activityRevision: UInt64 = 0
    private var configurationRevision: UInt64 = 0
    var isActive: Bool {
        active && (hub.map { hasBackendLease && $0.isEnabled } ?? (input?.isEnabled == true))
    }
    var routingIdentity: ObjectIdentifier? {
        if let hub { return ObjectIdentifier(hub) }
        return input.map(ObjectIdentifier.init)
    }

    func configure(_ hub: PlayerInputHub, feedback: any InputFeedbackProvider) {
        if self.hub === hub {
            if !hasBackendLease {
                hasBackendLease = hub.attachBackend(owner: backendOwner, feedbackProvider: feedback)
            }
            return
        }
        configurationRevision &+= 1
        let revision = configurationRevision
        let activity = activityRevision
        let wasActive = active
        active = false
        cancelAll()
        guard revision == configurationRevision else { return }
        detachBackend()
        guard revision == configurationRevision else { return }
        self.input = nil
        self.hub = hub
        heldKeys.removeAll(); heldButtons.removeAll(); devices.removeAll()
        hasBackendLease = hub.attachBackend(owner: backendOwner, feedbackProvider: feedback)
        if activityRevision == activity { active = wasActive && hasBackendLease }
        else { active = active && hasBackendLease }
    }

    func detachBackend() {
        guard let hub, hasBackendLease else { return }
        hasBackendLease = false
        hub.detachBackend(owner: backendOwner)
    }

    func cancelAll() {
        if let hub {
            if hasBackendLease { hub.cancelAll() }
        } else { input?.cancelAll() }
    }

    func cancelForCoordinateSpaceChange() {
        if let hub {
            if hasBackendLease { hub.cancelForCoordinateSpaceChange() }
        } else { input?.cancelForCoordinateSpaceChange() }
    }

    func handles(_ control: InputControl, device: InputDevice) -> Bool {
        if let hub { return hasBackendLease && hub.owner(of: device)?.input.handles(control: control) == true }
        return input?.handles(control: control) == true
    }

    private func submit(_ values: [(InputControl, InputValue)], device: InputDevice) {
        if let hub {
            if hasBackendLease { hub.submit(values, device: device) }
        } else { input?.setValues(values, device: device) }
    }

    func configure(_ input: InputController) {
        guard self.input !== input || hub != nil else { return }
        configurationRevision &+= 1
        let configuration = configurationRevision
        let activity = activityRevision
        let wasActive = active
        active = false
        cancelAll()
        guard configurationRevision == configuration else { return }
        cancelOwnedDevices()
        guard configurationRevision == configuration else { return }
        heldKeys.removeAll(); heldButtons.removeAll()
        detachBackend()
        guard configurationRevision == configuration else { return }
        hub = nil
        self.input = input
        if activityRevision == activity { active = wasActive && input.isEnabled }
        else { active = active && input.isEnabled }
    }

    func setActive(_ active: Bool) {
        activityRevision &+= 1
        let next = active && (hub.map { hasBackendLease && $0.isEnabled } ?? (input?.isEnabled == true))
        let wasActive = self.active
        self.active = next
        if wasActive && !next {
            devices.removeAll()
            cancelAll()
        }
    }

    func send(_ values: [(InputControl, InputValue)], device: InputDevice) {
        guard isActive else { return }
        devices.insert(device)
        submit(values, device: device)
    }

    func cancel(device: InputDevice) {
        guard devices.remove(device) != nil else { return }
        if let hub {
            if hasBackendLease, let player = hub.owner(of: device) {
                player.input.cancel(device: device)
                player.stopFeedback()
            }
        } else { input?.cancel(device: device) }
    }

    func forgetTrackedDevices(_ devices: [InputDevice]) { self.devices.subtract(devices) }

    private func cancelOwnedDevices() {
        let owned = devices
        devices.removeAll()
        for device in owned {
            if hub == nil { input?.cancel(device: device) }
        }
    }

    @discardableResult
    func key(_ name: String, pressed: Bool, isRepeat: Bool = false, shortcut: Bool = false) -> Bool {
        let control = InputControl.key(name)
        let bound = handles(control, device: .keyboard)
        if !pressed {
            // Context changes may remove a binding while its source is gated.
            // Forward its release even when unfocused, disabled or unbound.
            guard heldKeys.remove(name) != nil else { return false }
            submit([(control, .button(false))], device: .keyboard)
            return isActive && bound
        }
        guard isActive, bound, !shortcut, !isRepeat || heldKeys.contains(name) else { return false }
        heldKeys.insert(name)
        send([(control, .button(true))], device: .keyboard)
        return true
    }

    func releaseKeys() {
        for key in Array(heldKeys) { self.key(key, pressed: false) }
    }

    func pointer(_ button: Int, pressed: Bool) {
        guard button >= 0 else { return }
        let control = InputControl.pointerButton(button)
        if pressed {
            guard isActive, handles(control, device: .pointer) else { return }
            heldButtons.insert(button)
            send([(control, .button(true))], device: .pointer)
        } else if heldButtons.remove(button) != nil {
            submit([(control, .button(false))], device: .pointer)
        }
    }

    /// A release may happen outside this app while its local monitor is inactive.
    func reconcilePointerButtons(pressed: Set<Int>) {
        for button in heldButtons.subtracting(pressed) { pointer(button, pressed: false) }
    }

    static func canonicalKey(_ key: KeyEquivalent) -> String {
        switch key {
        case .upArrow: "up"
        case .downArrow: "down"
        case .leftArrow: "left"
        case .rightArrow: "right"
        case .space: "space"
        case .escape: "escape"
        case .return: "return"
        case .tab: "tab"
        default: String(key.character).lowercased()
        }
    }
}

@MainActor
final class GameInputSession {
    let router = GameInputRouter()
    lazy var hinge = GameHingeInput(router: router)
    private let feedback: NativeControllerFeedback
    lazy var controllers = GameControllerInput(router: router, feedback: feedback)
    var availability = GameInputAvailability()
    weak var host: GameHost?
    var requestFocus: (() -> Void)?
    private var lifecycleRevision: UInt64 = 0
    private var hingeRoutingActive = false

    init(feedback: NativeControllerFeedback = NativeControllerFeedback()) { self.feedback = feedback }

    func bind(_ references: [GameHostReference]) {
        let next = references.count == 1 ? references.first?.host : nil
        if host !== next {
            lifecycleRevision &+= 1
            let revision = lifecycleRevision
            hinge.stop()
            guard lifecycleRevision == revision else { return }
            hingeRoutingActive = false
            if host?.actionInput === router.input { host?.actionInput = nil }
            if host?.nativeInputSession === self { host?.nativeInputSession = nil }
        }
        host = next
        if let host, host.nativeInputSession == nil || host.nativeInputSession === self {
            host.nativeInputSession = self
            if host.actionInput == nil || host.actionInput === router.input { host.actionInput = router.input }
            host.levelPresentation.synchronizeInputSuppression()
        }
        refresh()
    }

    func refresh() {
        // Stop and reject feedback before cancellation callbacks can request it.
        let acceptsInput = availability.acceptsInput && host?.levelInputBlocked != true
        if !acceptsInput { controllers.suspend() }
        router.setActive(acceptsInput)
        if !router.isActive { controllers.suspend() }
        if hingeRoutingActive != router.isActive {
            hingeRoutingActive = router.isActive
            host?.invalidateHingeSample()
            if hingeRoutingActive { host?.nativeView?.refreshHingeObservation() }
        }
        if let host, host.hingeStore.hasCurrentSample {
            hinge.poll(host.hingeStore.state, at: ProcessInfo.processInfo.systemUptime)
        } else { hinge.suspend() }
    }
    func cancelFromHost(preservingHinge: Bool = false) {
        if !preservingHinge { hinge.suspend() }
        controllers.suspend()
        if preservingHinge { router.cancelForCoordinateSpaceChange() }
        else { router.cancelAll() }
    }

    func configure(_ input: InputController?, hub: PlayerInputHub?) {
        lifecycleRevision &+= 1
        let revision = lifecycleRevision
        controllers.stop()
        guard lifecycleRevision == revision else { return }
        hinge.stop()
        guard lifecycleRevision == revision else { return }
        if let hub { router.configure(hub, feedback: controllers.feedback) }
        else if let input { router.configure(input) }
        host?.levelPresentation.synchronizeInputSuppression()
        refresh()
    }

    func start() {
        lifecycleRevision &+= 1
        controllers.start { [weak self] in self?.refresh() }
    }
    func stop() {
        lifecycleRevision &+= 1
        let revision = lifecycleRevision
        availability.visible = false; refresh()
        guard lifecycleRevision == revision else { return }
        router.cancelAll()
        guard lifecycleRevision == revision else { return }
        controllers.stop()
        guard lifecycleRevision == revision else { return }
        hinge.stop()
        guard lifecycleRevision == revision else { return }
        router.detachBackend()
        guard lifecycleRevision == revision else { return }
        if host?.nativeInputSession === self { host?.nativeInputSession = nil }
        if host?.actionInput === router.input { host?.actionInput = nil }
        requestFocus = nil
    }

    func pointer(_ button: Int, pressed: Bool) {
        if pressed { focusForInteraction() }
        refresh(); router.pointer(button, pressed: pressed)
    }

    func focusForInteraction() {
        guard availability.visible, availability.scopeActive, availability.sceneActive, availability.windowActive else { return }
        requestFocus?()
    }
}

@MainActor
private struct GameInputModifier: ViewModifier {
    let input: InputController?
    let hub: PlayerInputHub?
    let isActive: Bool
    let hinge: HingeInputConfiguration?
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focused: Bool
    @State private var session = GameInputSession()

    func body(content: Content) -> some View {
        content
            .focusable(isActive)
            .focused($focused)
            .onKeyPress(phases: .all) { press in
                session.refresh()
                let shortcut = !press.modifiers.intersection([.command, .control, .option]).isEmpty
                return session.router.key(GameInputRouter.canonicalKey(press.key),
                    pressed: press.phase != .up, isRepeat: press.phase == .repeat, shortcut: shortcut) ? .handled : .ignored
            }
            .background { GameInputObserver(session: session) }
            .onPreferenceChange(GameHostPreferenceKey.self) { references in
                MainActor.assumeIsolated { session.bind(references) }
            }
            .onAppear {
                session.configure(input, hub: hub)
                session.hinge.configure(hinge)
                session.availability.visible = true
                session.availability.scopeActive = isActive
                session.availability.sceneActive = scenePhase == .active
                session.requestFocus = { focused = true }
                if isActive { focused = true }
                session.start()
                session.bind(session.host.map { [GameHostReference(id: $0.inputHostID, host: $0)] } ?? [])
            }
            .onDisappear { session.stop() }
            .onChange(of: hub.map(ObjectIdentifier.init) ?? input.map(ObjectIdentifier.init)) { _, _ in
                guard session.availability.visible else { return }
                if session.host?.actionInput === session.router.input { session.host?.actionInput = nil }
                session.configure(input, hub: hub)
                session.hinge.configure(hinge)
                session.start()
                session.bind(session.host.map { [GameHostReference(id: $0.inputHostID, host: $0)] } ?? [])
            }
            .onChange(of: focused, initial: true) { _, value in session.availability.focused = value; session.refresh() }
            .onChange(of: scenePhase, initial: true) { _, value in session.availability.sceneActive = value == .active; session.refresh() }
            .onChange(of: isActive, initial: true) { _, value in
                session.availability.scopeActive = value
                if value && session.availability.visible { focused = true }
                session.refresh()
            }
            .onChange(of: hub?.isEnabled ?? input?.isEnabled ?? false) { _, _ in session.refresh() }
            .onChange(of: hinge) { _, configuration in
                session.hinge.configure(configuration)
                session.refresh()
            }
    }
}

#if os(macOS)
import AppKit

@MainActor
private struct GameInputObserver: NSViewRepresentable {
    let session: GameInputSession
    func makeNSView(context: Context) -> GameInputObserverView {
        let view = GameInputObserverView(); view.session = session; return view
    }
    func updateNSView(_ view: GameInputObserverView, context: Context) { view.session = session }
    static func dismantleNSView(_ view: GameInputObserverView, coordinator: ()) { view.stop(); view.session?.stop() }
}

@MainActor
private final class GameInputObserverView: NSView {
    weak var session: GameInputSession?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); stop()
        session?.availability.windowActive = window?.isKeyWindow == true
        reconcilePointerButtons()
        session?.refresh()
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.session?.availability.windowActive = self.window?.isKeyWindow == true
                    self.reconcilePointerButtons()
                    self.session?.refresh()
                }
            })
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .keyUp]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let session = self.session else { return }
                if event.type == .keyUp {
                    if let characters = event.charactersIgnoringModifiers, let character = characters.first {
                        session.router.key(GameInputRouter.canonicalKey(KeyEquivalent(character)), pressed: false)
                    }
                    return
                }
                let down = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
                if down {
                    guard event.window === self.window, !self.isHiddenOrHasHiddenAncestor,
                          self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return }
                }
                session.pointer(event.buttonNumber, pressed: down)
            }
            return event
        }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
    private func reconcilePointerButtons() {
        let mask = NSEvent.pressedMouseButtons
        let pressed = Set((0..<(Int.bitWidth - 1)).filter { mask & (1 << $0) != 0 })
        session?.router.reconcilePointerButtons(pressed: pressed)
    }
}
#else
import UIKit

@MainActor
private struct GameInputObserver: UIViewRepresentable {
    let session: GameInputSession
    func makeUIView(context: Context) -> GameInputObserverView {
        let view = GameInputObserverView(); view.session = session; view.isUserInteractionEnabled = false; return view
    }
    func updateUIView(_ view: GameInputObserverView, context: Context) { view.session = session }
    static func dismantleUIView(_ view: GameInputObserverView, coordinator: ()) { view.stop(); view.session?.stop() }
}

@MainActor
private final class GameInputObserverView: UIView {
    weak var session: GameInputSession?
    private var observer: GamePointerObserver?
    override func didMoveToWindow() {
        super.didMoveToWindow(); stop()
        session?.availability.windowActive = window != nil
        session?.refresh()
        guard let window else { return }
        let observer = GamePointerObserver()
        observer.coordinateView = self
        observer.cancelsTouchesInView = false
        observer.delaysTouchesBegan = false; observer.delaysTouchesEnded = false
        observer.delegate = observer
        window.addGestureRecognizer(observer); self.observer = observer
    }
    func stop() {
        if let observer { observer.view?.removeGestureRecognizer(observer); self.observer = nil }
    }
}

/// Never recognizes, prevents another recognizer, or cancels a SwiftUI touch.
@MainActor
private final class GamePointerObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
    weak var coordinateView: GameInputObserverView?
    private var buttons: Set<Int> = []
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let view = coordinateView, touches.contains(where: { view.bounds.contains($0.location(in: view)) }) else { return }
        view.session?.focusForInteraction()
        guard touches.contains(where: { $0.type == .indirectPointer }) else { return }
        update(event)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { if !buttons.isEmpty { update(event) } }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if !buttons.isEmpty { update(event) }
        if event.allTouches?.allSatisfy({ $0.phase == .ended || $0.phase == .cancelled }) != false { state = .failed }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        coordinateView?.session?.router.cancel(device: .pointer)
        release(); state = .failed
    }
    override func reset() { release(); super.reset() }
    private func update(_ event: UIEvent) {
        let next = Set((0..<Int.bitWidth - 1).filter { event.buttonMask.rawValue & (1 << $0) != 0 })
        for button in next.subtracting(buttons) { coordinateView?.session?.pointer(button, pressed: true) }
        for button in buttons.subtracting(next) { coordinateView?.session?.pointer(button, pressed: false) }
        buttons = next
    }
    private func release() {
        for button in buttons { coordinateView?.session?.pointer(button, pressed: false) }
        buttons.removeAll()
    }
}
#endif
