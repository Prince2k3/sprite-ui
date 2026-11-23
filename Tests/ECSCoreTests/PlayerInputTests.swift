import Foundation
@_spi(Backend) @testable import ECSCore
import Testing

@MainActor @Suite struct PlayerInputTests {
    private let move = InputAction("move", kind: .axis2D)
    private let fire = InputAction("fire")
    private var map: InputActionMap {
        .init(name: "play", bindings: [
            .init(move, control: .key("w"), scale: [0, 1]),
            .init(fire, control: .key("space")),
            .init(fire, control: .gamepadButton(.south)),
            .init(move, control: .gamepadAxis(.leftStick), deadZone: 0.2),
            .init(move, control: .virtual("move"))
        ])
    }
    private func pad(_ hub: PlayerInputHub, player: PlayerInputSession) throws -> InputDevice {
        let id = InputDevice.controller(UUID())
        hub.connect(.init(id: id, name: "Pad", supportsHaptics: true))
        try hub.assign(id, to: player)
        hub.submit([(.gamepadButton(.south), .button(false)), (.gamepadAxis(.leftStick), .axis2D(.zero))], device: id)
        return id
    }

    @Test func independentPlayersAndExclusiveOwnership() throws {
        let hub = PlayerInputHub()
        let a = hub.addPlayer(named: "One", contexts: [map])
        let b = hub.addPlayer(named: "Two", contexts: [map])
        try hub.assign(.keyboard, to: a)
        let controller = try pad(hub, player: b)
        hub.submit([(.key("W"), .button(true))], device: .keyboard)
        hub.submit([(.gamepadButton(.south), .button(true))], device: controller)
        #expect(a.input.value(for: move).vector == [0, 1])
        #expect(!a.input.value(for: fire).isPressed)
        #expect(b.input.value(for: fire).isPressed)
        #expect(b.input.value(for: move).vector == .zero)
        #expect(a.devices.map(\.id) == [.keyboard])
        #expect(hub.owner(of: controller) === b)
    }

    @Test func transferCancelsOnlyOldDeviceAndRequiresNeutral() throws {
        let hub = PlayerInputHub()
        let a = hub.addPlayer(named: "A", contexts: [map])
        let b = hub.addPlayer(named: "B", contexts: [map])
        let controller = try pad(hub, player: a)
        try hub.assign(.keyboard, to: a)
        hub.submit([(.key("w"), .button(true))], device: .keyboard)
        hub.submit([(.gamepadButton(.south), .button(true))], device: controller)
        try hub.assign(controller, to: b)
        #expect(a.input.state(for: fire).phase == .cancelled)
        #expect(a.input.value(for: move).vector == [0, 1])
        hub.submit([(.gamepadButton(.south), .button(true))], device: controller)
        #expect(!b.input.value(for: fire).isPressed)
        hub.submit([(.gamepadButton(.south), .button(false))], device: controller)
        hub.submit([(.gamepadButton(.south), .button(true))], device: controller)
        #expect(b.input.value(for: fire).isPressed)
        try hub.assign(controller, to: a)
        hub.submit([(.gamepadButton(.south), .button(false))], device: controller)
        #expect(!a.input.value(for: fire).isPressed)
    }

    @Test func firstControllerSnapshotAndUnassignedHeldControlsAreGated() throws {
        let hub = PlayerInputHub()
        let a = hub.addPlayer(named: "A", contexts: [map])
        let id = InputDevice.controller(UUID())
        hub.connect(.init(id: id, name: "Pad"))
        hub.submit([(.gamepadButton(.south), .button(true))], device: id)
        try hub.assign(id, to: a)
        hub.submit([(.gamepadButton(.south), .button(true))], device: id)
        #expect(!a.input.value(for: fire).isPressed)
        hub.submit([(.gamepadButton(.south), .button(false))], device: id)
        hub.submit([(.gamepadButton(.south), .button(true))], device: id)
        #expect(a.input.value(for: fire).isPressed)
    }

    @Test func transferTestsOldAndNewDeadZones() throws {
        let hub = PlayerInputHub()
        let a = hub.addPlayer(named: "A", contexts: [map])
        let b = hub.addPlayer(named: "B", contexts: [.init(name: "strict", bindings: [.init(move, control: .gamepadAxis(.leftStick), deadZone: 0.05)])])
        let id = try pad(hub, player: a)
        hub.submit([(.gamepadAxis(.leftStick), .axis2D([0.8, 0]))], device: id)
        try hub.assign(id, to: b)
        hub.submit([(.gamepadAxis(.leftStick), .axis2D([0.1, 0]))], device: id)
        #expect(b.input.value(for: move).vector == .zero)
        hub.submit([(.gamepadAxis(.leftStick), .axis2D([0.01, 0]))], device: id)
        hub.submit([(.gamepadAxis(.leftStick), .axis2D([0.5, 0]))], device: id)
        #expect(b.input.value(for: move).isPressed)
    }

    @Test func previouslyNeutralDriftCannotActivateStricterNewOwner() throws {
        let hub = PlayerInputHub()
        let a = hub.addPlayer(named: "A", contexts: [map])
        let b = hub.addPlayer(named: "B", contexts: [.init(name: "strict", bindings: [.init(move, control: .gamepadAxis(.leftStick), deadZone: 0.05)])])
        let id = try pad(hub, player: a)
        hub.submit([(.gamepadAxis(.leftStick), .axis2D([0.1, 0]))], device: id)
        try hub.assign(id, to: b)
        hub.submit([(.gamepadAxis(.leftStick), .axis2D([0.1, 0]))], device: id)
        #expect(!b.input.value(for: move).isPressed)
        hub.submit([(.gamepadAxis(.leftStick), .axis2D([0.01, 0]))], device: id)
        hub.submit([(.gamepadAxis(.leftStick), .axis2D([0.6, 0]))], device: id)
        #expect(b.input.value(for: move).isPressed)
    }

    @Test func inactiveControllerRequiresFreshBaselineButNotPerfectRawZero() throws {
        let hub = PlayerInputHub()
        let a = hub.addPlayer(named: "A", contexts: [map])
        let id = try pad(hub, player: a)
        hub.cancelAll()
        hub.submit([(.gamepadButton(.south), .button(true))], device: id)
        #expect(!a.input.value(for: fire).isPressed)
        hub.submit([(.gamepadButton(.south), .button(false))], device: id)
        hub.submit([(.gamepadButton(.south), .button(true))], device: id)
        #expect(a.input.value(for: fire).isPressed)
        let unassigned = InputDevice.controller(UUID())
        hub.connect(.init(id: unassigned, name: "Drifting pad"))
        hub.submit([(.gamepadAxis(.leftStick), .axis2D([0.01, 0]))], device: unassigned)
        try hub.assign(unassigned, to: a)
        hub.submit([(.gamepadAxis(.leftStick), .axis2D([0.5, 0]))], device: unassigned)
        #expect(a.input.value(for: move).isPressed)
    }

    @Test func activeDeviceIgnoresDriftReleasesRepeatsAndUnboundControls() throws {
        let hub = PlayerInputHub()
        let a = hub.addPlayer(named: "A", contexts: [map])
        try hub.assign(.keyboard, to: a)
        let id = try pad(hub, player: a)
        hub.submit([(.key("space"), .button(true))], device: .keyboard)
        #expect(a.activeDevice?.id == .keyboard)
        hub.submit([(.gamepadAxis(.leftStick), .axis2D([0.1, 0])), (.gamepadButton(.north), .button(true))], device: id)
        #expect(a.activeDevice?.id == .keyboard)
        hub.submit([(.gamepadButton(.south), .button(true))], device: id)
        #expect(a.activeDevice?.id == id)
        hub.submit([(.key("space"), .button(true))], device: .keyboard)
        hub.submit([(.key("space"), .button(false))], device: .keyboard)
        #expect(a.activeDevice?.id == id)
        hub.disconnect(id)
        #expect(a.activeDevice?.id == .keyboard)
    }

    @Test func promptsUseEffectiveBindingsAndLiveRemappedMetadata() throws {
        let hub = PlayerInputHub()
        let a = hub.addPlayer(named: "A", contexts: [map])
        try hub.assign(.keyboard, to: a)
        #expect(a.prompt(for: fire)?.label == "Space")
        let id = try pad(hub, player: a)
        hub.connect(.init(id: id, name: "Pad", presentations: [.gamepadButton(.south): .init(label: "Cross", symbolName: "xmark.circle")], hasRemappedElements: true))
        hub.submit([(.gamepadButton(.south), .button(true))], device: id)
        #expect(a.prompt(for: fire)?.label == "Cross")
        #expect(a.prompt(for: fire)?.symbolName == "xmark.circle")
        a.input.setContexts([map, .init(name: "menu", bindings: [.init(fire, control: .key("return"))])])
        #expect(a.prompt(for: fire)?.label == "Return")
        #expect(a.input.bindings(for: fire).map(\.control) == [.key("return")])
        hub.submit([(.gamepadButton(.south), .button(false))], device: id)
        hub.submit([(.gamepadButton(.south), .button(true))], device: id)
        #expect(a.activeDevice?.id == id) // remains last meaningful device, not a new event
    }

    @Test func disabledAndCancelledSessionsStayNeutralUntilRelease() throws {
        let hub = PlayerInputHub()
        let a = hub.addPlayer(named: "A", contexts: [map])
        try hub.assign(.keyboard, to: a)
        hub.submit([(.key("space"), .button(true))], device: .keyboard)
        hub.cancelAll()
        hub.submit([(.key("space"), .button(true))], device: .keyboard)
        #expect(!a.input.value(for: fire).isPressed)
        hub.submit([(.key("space"), .button(false))], device: .keyboard)
        hub.submit([(.key("space"), .button(true))], device: .keyboard)
        #expect(a.input.value(for: fire).isPressed)
        a.isEnabled = false
        hub.submit([(.key("space"), .button(true))], device: .keyboard)
        a.isEnabled = true
        hub.submit([(.key("space"), .button(true))], device: .keyboard)
        #expect(!a.input.value(for: fire).isPressed)
    }

    @Test func lifecycleTokensAndMetadataUpdates() throws {
        let hub = PlayerInputHub()
        var names: [String] = []
        let token = hub.observe { event in
            switch event { case .connected(let info): names.append("+" + info.name)
            case .updated(let info): names.append("=" + info.name)
            case .disconnected(let info): names.append("-" + info.name)
            default: break }
        }
        let id = InputDevice.virtual("stick")
        hub.connect(.init(id: id, name: "Stick"))
        hub.connect(.init(id: id, name: "New"))
        hub.disconnect(id)
        #expect(names == ["+Stick", "=New", "-New"])
        token.cancel()
        hub.connect(.init(id: id, name: "Ignored"))
        #expect(names.count == 3)
    }

    @Test func reentrantHandoffDoesNotDeliverToStaleOwner() throws {
        let hub = PlayerInputHub()
        let a = hub.addPlayer(named: "A", contexts: [map])
        let b = hub.addPlayer(named: "B", contexts: [map])
        let c = hub.addPlayer(named: "C", contexts: [map])
        let id = try pad(hub, player: a)
        try hub.assign(.keyboard, to: a)
        hub.submit([(.key("w"), .button(true))], device: .keyboard)
        hub.submit([(.gamepadButton(.south), .button(true))], device: id)
        let token = a.input.observe { event in
            if event.phase == .cancelled { try? hub.assign(id, to: c) }
        }
        try hub.assign(id, to: b)
        #expect(hub.owner(of: id) === c)
        #expect(a.activeDevice?.id == .keyboard)
        hub.submit([(.gamepadButton(.south), .button(true))], device: id)
        #expect(!b.input.value(for: fire).isPressed)
        #expect(!c.input.value(for: fire).isPressed)
        token.cancel()
    }

    @Test func activeDeviceCallbackCanCancelBeforeActionDelivery() throws {
        let hub = PlayerInputHub()
        let a = hub.addPlayer(named: "A", contexts: [map])
        try hub.assign(.keyboard, to: a)
        let token = hub.observe { event in
            if case .activeDeviceChanged = event { hub.cancelAll() }
        }
        hub.submit([(.key("space"), .button(true))], device: .keyboard)
        #expect(!a.input.value(for: fire).isPressed)
        token.cancel()
    }

    @Test func sessionCancellationInActiveDeviceCallbackInvalidatesPendingPress() throws {
        let hub = PlayerInputHub()
        let a = hub.addPlayer(named: "A", contexts: [map])
        try hub.assign(.keyboard, to: a)
        let token = hub.observe { event in
            if case .activeDeviceChanged = event { a.input.cancelAll() }
        }
        hub.submit([(.key("space"), .button(true))], device: .keyboard)
        #expect(!a.input.value(for: fire).isPressed)
        token.cancel()
        hub.submit([(.key("space"), .button(true))], device: .keyboard)
        #expect(!a.input.value(for: fire).isPressed)
    }

    @Test func newerReentrantReleaseSupersedesPendingPress() throws {
        let hub = PlayerInputHub()
        let a = hub.addPlayer(named: "A", contexts: [map])
        try hub.assign(.keyboard, to: a)
        let token = hub.observe { event in
            if case .activeDeviceChanged = event {
                hub.submit([(.key("space"), .button(false))], device: .keyboard)
            }
        }
        hub.submit([(.key("space"), .button(true))], device: .keyboard)
        #expect(!a.input.value(for: fire).isPressed)
        token.cancel()
        hub.submit([(.key("space"), .button(true))], device: .keyboard)
        #expect(a.input.value(for: fire).isPressed)
    }

    @Test func playerReenableRebaselinesOnlyItsControllers() throws {
        let hub = PlayerInputHub()
        let a = hub.addPlayer(named: "A", contexts: [map])
        let b = hub.addPlayer(named: "B", contexts: [map])
        let id = try pad(hub, player: a)
        let other = try pad(hub, player: b)
        hub.submit([(.gamepadButton(.south), .button(true))], device: other)
        a.isEnabled = false; a.isEnabled = true
        hub.submit([(.gamepadButton(.south), .button(true))], device: id)
        #expect(!a.input.value(for: fire).isPressed)
        #expect(b.input.value(for: fire).isPressed)
        hub.submit([(.gamepadButton(.south), .button(false))], device: id)
        hub.submit([(.gamepadButton(.south), .button(true))], device: id)
        #expect(a.input.value(for: fire).isPressed)
    }

    @Test func removalAndForeignAssignmentAreSafe() throws {
        let hub = PlayerInputHub()
        let a = hub.addPlayer(named: "A", contexts: [map])
        try hub.assign(.keyboard, to: a)
        hub.submit([(.key("space"), .button(true))], device: .keyboard)
        hub.removePlayer(a)
        #expect(a.devices.isEmpty)
        #expect(!a.input.value(for: fire).isPressed)
        #expect(hub.owner(of: .keyboard) == nil)
        #expect(throws: PlayerInputError.foreignPlayer) { try hub.assign(.keyboard, to: a) }
        #expect(throws: PlayerInputError.unknownDevice) { try hub.assign(.virtual("unknown"), to: a) }
    }

    @Test func feedbackOwnershipCapabilityAndBackendLease() throws {
        let hub = PlayerInputHub()
        let a = hub.addPlayer(named: "A", contexts: [map])
        let b = hub.addPlayer(named: "B", contexts: [map])
        let id = try pad(hub, player: a)
        let provider = RecordingFeedback()
        let lease = UUID()
        #expect(hub.attachBackend(owner: lease, feedbackProvider: provider))
        #expect(!hub.attachBackend(owner: UUID(), feedbackProvider: provider))
        #expect(a.playFeedback(.impact) == .unavailable)
        var firstPressResult: InputFeedbackResult?
        let token = a.input.observe(action: fire) { event in
            if event.phase == .pressed { firstPressResult = a.playFeedback(.selection) }
        }
        hub.submit([(.gamepadButton(.south), .button(true))], device: id)
        #expect(firstPressResult == .accepted)
        #expect(b.playFeedback(.impact, on: id) == .unavailable)
        a.isEnabled = false
        #expect(provider.stopped.contains(id))
        #expect(a.playFeedback(.impact, on: id) == .unavailable)
        a.isEnabled = true
        hub.unassign(id)
        #expect(a.playFeedback(.impact, on: id) == .unavailable)
        hub.detachBackend(owner: lease)
        try hub.assign(id, to: b)
        #expect(b.playFeedback(.impact, on: id) == .unavailable)
        token.cancel()
    }

    @Test func keyboardFeedbackDoesNotFallBackToUnusedPad() throws {
        let hub = PlayerInputHub()
        let a = hub.addPlayer(named: "A", contexts: [map])
        let id = try pad(hub, player: a)
        let provider = RecordingFeedback()
        #expect(hub.attachBackend(owner: UUID(), feedbackProvider: provider))
        try hub.assign(.keyboard, to: a)
        hub.submit([(.key("space"), .button(true))], device: .keyboard)
        #expect(a.playFeedback(.impact) == .unsupported)
        #expect(provider.played.isEmpty)
        #expect(a.playFeedback(.impact, on: id) == .accepted)
    }

    @Test func deviceCancellationStopsOnlyItsFeedback() throws {
        let hub = PlayerInputHub()
        let a = hub.addPlayer(named: "A", contexts: [map])
        let id = try pad(hub, player: a)
        let other = try pad(hub, player: a)
        let provider = RecordingFeedback()
        #expect(hub.attachBackend(owner: UUID(), feedbackProvider: provider))
        #expect(a.playFeedback(.impact, on: id) == .accepted)
        #expect(a.playFeedback(.impact, on: other) == .accepted)
        provider.stopped.removeAll()
        a.input.cancel(device: id)
        #expect(provider.stopped == [id])
    }

    @Test func cancellationCallbacksCannotRestartFeedback() throws {
        let hub = PlayerInputHub()
        let a = hub.addPlayer(named: "A", contexts: [map])
        let id = try pad(hub, player: a)
        let provider = RecordingFeedback()
        #expect(hub.attachBackend(owner: UUID(), feedbackProvider: provider))
        hub.submit([(.gamepadButton(.south), .button(true))], device: id)
        var result: InputFeedbackResult?
        let token = a.input.observe { event in
            if event.phase == .cancelled { result = a.playFeedback(.impact) }
        }
        hub.cancelAll()
        #expect(result == .unavailable)
        #expect(provider.played.isEmpty)
        #expect(provider.stopped.contains(id))
        token.cancel()
    }

    @Test func feedbackDecodingNormalizesAndPartialAtomicSnapshotsUseLastValue() throws {
        let feedback = ControllerFeedback(intensity: .nan, sharpness: 9, duration: .infinity)
        #expect(feedback.intensity == 0 && feedback.sharpness == 1 && feedback.duration == 0.1)
        let decoded = try JSONDecoder().decode(ControllerFeedback.self, from: Data(#"{"intensity":8,"sharpness":-2,"duration":99}"#.utf8))
        #expect(decoded.intensity == 1 && decoded.sharpness == 0 && decoded.duration == 2)
        let hub = PlayerInputHub()
        let a = hub.addPlayer(named: "A", contexts: [map])
        try hub.assign(.keyboard, to: a)
        hub.submit([(.key("space"), .button(true)), (.key("space"), .button(false))], device: .keyboard)
        #expect(a.activeDevice == nil)
        #expect(!a.input.value(for: fire).isPressed)
    }
}

@MainActor private final class RecordingFeedback: InputFeedbackProvider {
    var played: [InputDevice] = []
    var stopped: [InputDevice] = []
    func play(_ feedback: ControllerFeedback, on device: InputDevice) -> InputFeedbackResult {
        played.append(device); return .accepted
    }
    func stop(for device: InputDevice) { stopped.append(device) }
}
