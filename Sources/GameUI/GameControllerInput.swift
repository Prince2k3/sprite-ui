@_spi(Backend) import ECSCore
import Foundation
import GameController

private final class GameControllerObservations {
    var tokens: [NSObjectProtocol] = []
    func removeAll() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
    }
    deinit { removeAll() }
}

/// Polling never replaces a controller's handlers, handlerQueue, or player index.
/// Each modifier owns its timer, device identities and notification tokens.
@MainActor
final class GameControllerInput {
    let router: GameInputRouter
    let feedback: NativeControllerFeedback
    private var timer: Timer?
    private let observations = GameControllerObservations()
    private var identities: [ObjectIdentifier: UUID] = [:]
    private var gates: [UUID: Set<InputControl>] = [:]
    private var inputIdentity: ObjectIdentifier?
    private var wasActive = false
    private var lifecycleRevision: UInt64 = 0

    init(router: GameInputRouter, feedback: NativeControllerFeedback = NativeControllerFeedback()) {
        self.router = router
        self.feedback = feedback
    }

    func start(refresh: @escaping @MainActor () -> Void) {
        guard timer == nil else { return }
        lifecycleRevision &+= 1
        let revision = lifecycleRevision
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observations.tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let key = (note.object as? GCController).map(ObjectIdentifier.init)
                let disconnected = note.name == .GCControllerDidDisconnect
                MainActor.assumeIsolated {
                    guard let self, self.lifecycleRevision == revision, self.timer != nil, let key else { return }
                    if disconnected {
                        if let id = self.identities.removeValue(forKey: key) { self.disconnect(id: id) }
                    } else {
                        refresh()
                        guard self.lifecycleRevision == revision else { return }
                        self.poll()
                    }
                }
            })
        }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated {
                guard self.lifecycleRevision == revision else { return }
                refresh()
                guard self.lifecycleRevision == revision else { return }
                // A release can occur after SwiftUI has lost keyboard focus.
                // Only infer neutral when the entire physical keyboard is up;
                // this remains safe across keyboard layouts.
                if GCKeyboard.coalesced?.keyboardInput?.isAnyKeyPressed == false {
                    self.router.releaseKeys()
                }
                self.poll()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
        if lifecycleRevision == revision { poll() }
    }

    func stop() {
        lifecycleRevision &+= 1
        // Disconnect callbacks may synchronously configure and start a new hub.
        // Complete this teardown against its original destination and identities.
        let originalHub = router.hasBackendLease ? router.hub : nil
        let originalInput = router.input
        let originalFeedback = feedback
        let devices = Array(identities.values)
        timer?.invalidate(); timer = nil
        observations.removeAll()
        identities.removeAll(); gates.removeAll(); inputIdentity = nil; wasActive = false
        router.forgetTrackedDevices(devices.map(InputDevice.controller))
        originalFeedback.setActive(false)
        for id in devices {
            let device = InputDevice.controller(id)
            originalFeedback.unregister(device)
            if let originalHub { originalHub.disconnect(device) }
            else { originalInput?.cancel(device: device) }
        }
    }

    func suspend() {
        gates.removeAll()
        feedback.setActive(false)
        wasActive = false
    }

    func poll(controllers: [GCController] = GCController.controllers()) {
        let revision = lifecycleRevision
        let routingIdentity = router.routingIdentity
        func isCurrent() -> Bool {
            revision == lifecycleRevision && routingIdentity == router.routingIdentity
        }
        let connected = Set(controllers.map(ObjectIdentifier.init))
        for key in Array(identities.keys) where !connected.contains(key) {
            if let id = identities.removeValue(forKey: key) { disconnect(id: id) }
            guard isCurrent() else { return }
        }
        if let hub = router.hub {
            guard router.hasBackendLease else { return }
            // Discovery remains live while inactive; only sampling is suspended.
            for controller in controllers {
                let key = ObjectIdentifier(controller)
                let id = identities[key] ?? UUID()
                identities[key] = id
                let device = InputDevice.controller(id)
                feedback.register(controller, device: device)
                hub.connect(Self.deviceInfo(from: controller, id: id))
                guard isCurrent(), router.hasBackendLease else { return }
            }
        }
        if !router.isActive {
            feedback.setActive(false)
            if wasActive {
                for id in identities.values { router.cancel(device: .controller(id)) }
            }
            gates.removeAll(); wasActive = false
            return
        }
        feedback.setActive(true)
        for controller in controllers {
            let key = ObjectIdentifier(controller)
            let id = identities[key] ?? UUID()
            identities[key] = id
            route(Self.values(from: controller), id: id)
            guard isCurrent() else { return }
        }
        wasActive = true
    }

    /// The first snapshot after activation gates controls already held. Neutral
    /// is still forwarded, clearing the core's cancellation gate on resumption.
    func route(_ values: [(InputControl, InputValue)], id: UUID) {
        guard router.isActive else { gates.removeValue(forKey: id); return }
        if router.hub != nil {
            // The hub records unassigned baselines and gates attach/reassignment.
            router.send(values, device: .controller(id))
            return
        }
        let identity = router.routingIdentity
        if inputIdentity != identity {
            gates.removeAll()
            inputIdentity = identity
        }
        func isNeutral(_ value: InputValue, for control: InputControl) -> Bool {
            router.input?.isNeutral(value, for: control) ?? !value.isPressed
        }
        var blocked = gates[id] ?? Set(values.filter { !isNeutral($0.1, for: $0.0) }.map(\.0))
        let filtered = values.map { control, value -> (InputControl, InputValue) in
            if isNeutral(value, for: control) { blocked.remove(control) }
            guard blocked.contains(control) else { return (control, value) }
            switch value {
            case .button: return (control, .button(false))
            case .axis: return (control, .axis(0))
            case .axis2D: return (control, .axis2D(.zero))
            }
        }
        gates[id] = blocked
        router.send(filtered, device: .controller(id))
    }

    func disconnect(id: UUID) {
        gates.removeValue(forKey: id)
        let device = InputDevice.controller(id)
        feedback.unregister(device)
        if let hub = router.hub {
            if router.hasBackendLease { hub.disconnect(device) }
        } else { router.cancel(device: device) }
    }

    static func deviceInfo(from controller: GCController, id: UUID) -> InputDeviceInfo {
        let presentations = Dictionary(uniqueKeysWithValues: elements(from: controller).map { control, element in
            (control, InputControlPresentation(label: element.localizedName ?? fallbackLabel(for: control),
                                               symbolName: element.sfSymbolsName))
        })
        return InputDeviceInfo(id: .controller(id), name: controller.vendorName ?? controller.productCategory,
                               presentations: presentations, supportsHaptics: controller.haptics != nil,
                               hasRemappedElements: controller.physicalInputProfile.hasRemappedElements)
    }

    private static func fallbackLabel(for control: InputControl) -> String {
        switch control {
        case .gamepadButton(let button): return button.rawValue
        case .gamepadAxis(let axis): return axis.rawValue
        default: return String(describing: control)
        }
    }

    /// Live elements supply OS-remapped display names and symbols. Samples use
    /// capture() separately; neither path installs or replaces app callbacks.
    static func elements(from controller: GCController) -> [(InputControl, GCControllerElement)] {
        if let pad = controller.extendedGamepad {
            var elements: [(InputControl, GCControllerElement)] = [
                (.gamepadButton(.south), pad.buttonA), (.gamepadButton(.east), pad.buttonB),
                (.gamepadButton(.west), pad.buttonX), (.gamepadButton(.north), pad.buttonY),
                (.gamepadButton(.leftShoulder), pad.leftShoulder),
                (.gamepadButton(.rightShoulder), pad.rightShoulder),
                (.gamepadButton(.menu), pad.buttonMenu),
                (.gamepadAxis(.leftStick), pad.leftThumbstick),
                (.gamepadAxis(.rightStick), pad.rightThumbstick),
                (.gamepadAxis(.dpad), pad.dpad),
                (.gamepadAxis(.leftTrigger), pad.leftTrigger),
                (.gamepadAxis(.rightTrigger), pad.rightTrigger)
            ]
            if let button = pad.buttonOptions { elements.append((.gamepadButton(.options), button)) }
            if let button = pad.leftThumbstickButton { elements.append((.gamepadButton(.leftStick), button)) }
            if let button = pad.rightThumbstickButton { elements.append((.gamepadButton(.rightStick), button)) }
            return elements
        }
        if let pad = controller.microGamepad {
            return [(.gamepadButton(.south), pad.buttonA), (.gamepadButton(.west), pad.buttonX),
                    (.gamepadButton(.menu), pad.buttonMenu), (.gamepadAxis(.dpad), pad.dpad)]
        }
        return []
    }

    static func values(from controller: GCController) -> [(InputControl, InputValue)] {
        // capture() gives a consistent snapshot even if the app uses another
        // queue for its own controller callbacks.
        let snapshot = controller.capture()
        var buttons: [GamepadButton: Bool] = [:]
        var axes: [GamepadAxis: InputValue] = [:]
        func vector(_ pad: GCControllerDirectionPad) -> InputValue {
            .axis2D([pad.xAxis.value, pad.yAxis.value])
        }
        if let pad = snapshot.extendedGamepad {
            buttons = [.south: pad.buttonA.isPressed, .east: pad.buttonB.isPressed,
                       .west: pad.buttonX.isPressed, .north: pad.buttonY.isPressed,
                       .leftShoulder: pad.leftShoulder.isPressed, .rightShoulder: pad.rightShoulder.isPressed,
                       .menu: pad.buttonMenu.isPressed, .options: pad.buttonOptions?.isPressed ?? false,
                       .leftStick: pad.leftThumbstickButton?.isPressed ?? false,
                       .rightStick: pad.rightThumbstickButton?.isPressed ?? false]
            axes = [.leftStick: vector(pad.leftThumbstick), .rightStick: vector(pad.rightThumbstick),
                    .dpad: vector(pad.dpad), .leftTrigger: .axis(pad.leftTrigger.value),
                    .rightTrigger: .axis(pad.rightTrigger.value)]
        } else if let pad = snapshot.microGamepad {
            buttons = [.south: pad.buttonA.isPressed, .west: pad.buttonX.isPressed, .menu: pad.buttonMenu.isPressed]
            axes = [.dpad: vector(pad.dpad)]
        }
        // Include absent elements as neutral so profile changes cannot leave a
        // previously present control held.
        return GamepadButton.allCases.map { (.gamepadButton($0), .button(buttons[$0] ?? false)) }
            + GamepadAxis.allCases.map {
                (.gamepadAxis($0), axes[$0] ?? ($0 == .leftTrigger || $0 == .rightTrigger ? .axis(0) : .axis2D(.zero)))
            }
    }
}
