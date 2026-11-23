import ECSCore
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
    private var timer: Timer?
    private let observations = GameControllerObservations()
    private var identities: [ObjectIdentifier: UUID] = [:]
    private var gates: [UUID: Set<InputControl>] = [:]
    private var inputIdentity: ObjectIdentifier?
    private var wasActive = false

    init(router: GameInputRouter) { self.router = router }

    func start(refresh: @escaping @MainActor () -> Void) {
        guard timer == nil else { return }
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observations.tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let key = (note.object as? GCController).map(ObjectIdentifier.init)
                let disconnected = note.name == .GCControllerDidDisconnect
                MainActor.assumeIsolated {
                    guard let self, self.timer != nil, let key else { return }
                    if disconnected {
                        if let id = self.identities.removeValue(forKey: key) { self.disconnect(id: id) }
                    } else { refresh(); self.poll() }
                }
            })
        }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated {
                refresh()
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
        refresh(); poll()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        observations.removeAll()
        let devices = Array(identities.values)
        identities.removeAll(); gates.removeAll(); inputIdentity = nil; wasActive = false
        for id in devices { router.cancel(device: .controller(id)) }
    }

    func suspend() {
        gates.removeAll()
        wasActive = false
    }

    func poll(controllers: [GCController] = GCController.controllers()) {
        let connected = Set(controllers.map(ObjectIdentifier.init))
        for key in Array(identities.keys) where !connected.contains(key) {
            if let id = identities.removeValue(forKey: key) { disconnect(id: id) }
        }
        if !router.isActive {
            if wasActive {
                for id in identities.values { router.cancel(device: .controller(id)) }
            }
            gates.removeAll(); wasActive = false
            return
        }
        for controller in controllers {
            let key = ObjectIdentifier(controller)
            let id = identities[key] ?? UUID()
            identities[key] = id
            route(Self.values(from: controller), id: id)
        }
        wasActive = true
    }

    /// The first snapshot after activation gates controls already held. Neutral
    /// is still forwarded, clearing the core's cancellation gate on resumption.
    func route(_ values: [(InputControl, InputValue)], id: UUID) {
        guard router.isActive else { gates.removeValue(forKey: id); return }
        let identity = router.input.map(ObjectIdentifier.init)
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
        router.cancel(device: .controller(id))
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
