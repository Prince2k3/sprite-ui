import Foundation
@_spi(Backend) @testable import ECSCore
import Testing

@MainActor @Suite struct LevelInputSuppressionTests {
    private let fire = InputAction("fire")
    private let move = InputAction("move", kind: .axis2D)
    private var map: InputActionMap {
        .init(name: "play", bindings: [
            .init(fire, control: .key("space")),
            .init(fire, control: .pointerButton(0)),
            .init(fire, control: .gamepadButton(.south)),
            .init(fire, control: .gamepadAxis(.rightTrigger)),
            .init(fire, control: .virtual("fire")),
            .init(move, control: .gamepadAxis(.leftStick), deadZone: 0.2)
        ])
    }

    @Test(arguments: [InputControl.key("space"), .pointerButton(0), .gamepadButton(.south), .virtual("fire")])
    func controllerCancelsHeldInputAndRequiresNeutralOnResume(control: InputControl) {
        let input = InputController(contexts: [map])
        let device = device(for: control)
        let owner = UUID()
        var phases: [InputActionPhase] = []
        let token = input.observe(action: fire) { phases.append($0.phase) }
        input.setValue(.button(true), for: control, device: device)

        input.setInputSuppressed(true, owner: owner)
        #expect(input.isEnabled)
        #expect(input.contexts == [map])
        #expect(input.state(for: fire).phase == .cancelled)
        input.setValue(.button(false), for: control, device: device)
        input.setValue(.button(true), for: control, device: device)
        #expect(!input.value(for: fire).isPressed)

        input.setInputSuppressed(false, owner: owner)
        input.setValue(.button(true), for: control, device: device)
        #expect(!input.value(for: fire).isPressed)
        #expect(phases == [.pressed, .cancelled])
        input.setValue(.button(false), for: control, device: device)
        input.setValue(.button(true), for: control, device: device)
        #expect(phases == [.pressed, .cancelled, .pressed])
        token.cancel()
    }

    @Test func controllerBlocksControlsFirstSampledDuringSuppression() {
        let input = InputController(contexts: [map])
        let owner = UUID()
        input.setInputSuppressed(true, owner: owner)
        input.setValue(.button(true), for: .virtual("fire"), device: .virtual("overlay"))
        input.setInputSuppressed(false, owner: owner)
        input.setValue(.button(true), for: .virtual("fire"), device: .virtual("overlay"))
        #expect(!input.value(for: fire).isPressed)
        input.setValue(.button(false), for: .virtual("fire"), device: .virtual("overlay"))
        input.setValue(.button(true), for: .virtual("fire"), device: .virtual("overlay"))
        #expect(input.value(for: fire).isPressed)
    }

    @Test func controllerLeasesComposeAndUnknownReleasesDoNotCancelInput() {
        let input = InputController(contexts: [map])
        let first = UUID(), second = UUID()
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        input.setInputSuppressed(false, owner: first)
        #expect(input.value(for: fire).isPressed)
        input.setInputSuppressed(true, owner: first)
        input.setInputSuppressed(true, owner: first)
        input.setInputSuppressed(true, owner: second)
        input.setInputSuppressed(false, owner: first)
        input.setValue(.button(false), for: .key("space"), device: .keyboard)
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        #expect(!input.value(for: fire).isPressed)
        input.setInputSuppressed(false, owner: second)
        input.setValue(.button(false), for: .key("space"), device: .keyboard)
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        #expect(input.value(for: fire).isPressed)
        input.setInputSuppressed(false, owner: first)
        #expect(input.value(for: fire).isPressed)
    }

    @Test(arguments: [false, true])
    func suppressionPreservesEnabledPreference(enabled: Bool) {
        let input = InputController(contexts: [map])
        let owner = UUID()
        input.isEnabled = enabled
        input.setInputSuppressed(true, owner: owner)
        #expect(input.isEnabled == enabled)
        input.setInputSuppressed(false, owner: owner)
        #expect(input.isEnabled == enabled)
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        #expect(input.value(for: fire).isPressed == enabled)
    }

    @Test func enablingDuringSuppressionDoesNotBypassTheLease() {
        let input = InputController(contexts: [map])
        let owner = UUID()
        input.isEnabled = false
        input.setInputSuppressed(true, owner: owner)
        input.isEnabled = true
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        #expect(!input.value(for: fire).isPressed)
        input.setInputSuppressed(false, owner: owner)
        #expect(input.isEnabled)
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        #expect(!input.value(for: fire).isPressed)
    }

    @Test func analogControlsResumeAtBindingNeutralRatherThanExactZero() {
        let input = InputController(contexts: [map])
        let owner = UUID(), pad = InputDevice.controller(UUID())
        input.setInputSuppressed(true, owner: owner)
        input.setValues([(.gamepadAxis(.leftStick), .axis2D([0.8, 0])),
                         (.gamepadAxis(.rightTrigger), .axis(1))], device: pad)
        input.setInputSuppressed(false, owner: owner)
        input.setValues([(.gamepadAxis(.leftStick), .axis2D([0.7, 0])),
                         (.gamepadAxis(.rightTrigger), .axis(0.9))], device: pad)
        #expect(!input.value(for: move).isPressed && !input.value(for: fire).isPressed)
        input.setValues([(.gamepadAxis(.leftStick), .axis2D([0.03, 0.02])),
                         (.gamepadAxis(.rightTrigger), .axis(0.1))], device: pad)
        input.setValues([(.gamepadAxis(.leftStick), .axis2D([0.8, 0])),
                         (.gamepadAxis(.rightTrigger), .axis(1))], device: pad)
        #expect(input.value(for: move).isPressed && input.value(for: fire).isPressed)
    }

    @Test func suppressionFromAnObserverInvalidatesPendingPressDelivery() {
        let input = InputController(contexts: [map])
        let owner = UUID()
        let first = input.observe { event in
            if event.phase == .pressed { input.setInputSuppressed(true, owner: owner) }
        }
        var phases: [InputActionPhase] = []
        let second = input.observe { phases.append($0.phase) }
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        #expect(phases == [.cancelled])
        #expect(!input.value(for: fire).isPressed)
        first.cancel(); second.cancel()
    }

    @Test(arguments: [InputControl.key("space"), .pointerButton(0), .gamepadButton(.south), .virtual("fire")])
    func hubGatesNewSamplesWithoutChangingDevicesOrAssignments(control: InputControl) throws {
        let hub = PlayerInputHub()
        let player = hub.addPlayer(named: "One", contexts: [map])
        let device = device(for: control), owner = UUID()
        if !hub.devices.contains(where: { $0.id == device }) {
            hub.connect(.init(id: device, name: "Test device"))
        }
        try hub.assign(device, to: player)
        hub.submit([(control, .button(false))], device: device)
        let devices = hub.devices
        hub.setInputSuppressed(true, owner: owner)
        hub.submit([(control, .button(true))], device: device)
        #expect(!player.input.value(for: fire).isPressed)
        #expect(player.activeDevice == nil)
        hub.setInputSuppressed(false, owner: owner)
        hub.submit([(control, .button(true))], device: device)
        #expect(!player.input.value(for: fire).isPressed)
        hub.submit([(control, .button(false))], device: device)
        hub.submit([(control, .button(true))], device: device)
        #expect(player.input.value(for: fire).isPressed)
        #expect(hub.owner(of: device) === player)
        #expect(hub.devices == devices)
        #expect(hub.players.count == 1 && hub.players[0] === player)
        #expect(hub.isEnabled && player.isEnabled)
    }

    @Test func hubLeasesReachExistingAndNewPlayersAndComposeWithDirectLeases() {
        let hub = PlayerInputHub()
        let existing = hub.addPlayer(named: "Existing", contexts: [map])
        let disabled = hub.addPlayer(named: "Disabled", contexts: [map])
        disabled.isEnabled = false
        let first = UUID(), second = UUID(), direct = UUID()
        hub.setInputSuppressed(true, owner: first)
        hub.setInputSuppressed(true, owner: second)
        let newcomer = hub.addPlayer(named: "New", contexts: [map])
        existing.input.setInputSuppressed(true, owner: direct)
        hub.setInputSuppressed(false, owner: first)
        for player in [existing, newcomer] {
            player.input.setValue(.button(true), for: .key("space"), device: .keyboard)
            #expect(!player.input.value(for: fire).isPressed)
        }
        hub.setInputSuppressed(false, owner: second)
        for player in [existing, newcomer] {
            player.input.setValue(.button(false), for: .key("space"), device: .keyboard)
            player.input.setValue(.button(true), for: .key("space"), device: .keyboard)
        }
        #expect(!existing.input.value(for: fire).isPressed)
        #expect(newcomer.input.value(for: fire).isPressed)
        #expect(!disabled.isEnabled)
        existing.input.setInputSuppressed(false, owner: direct)
        existing.input.setValue(.button(false), for: .key("space"), device: .keyboard)
        existing.input.setValue(.button(true), for: .key("space"), device: .keyboard)
        #expect(existing.input.value(for: fire).isPressed)
    }

    @Test func hubPreservesDisabledPreferenceAndCannotBeBypassedByReenable() throws {
        let hub = PlayerInputHub()
        let player = hub.addPlayer(named: "One", contexts: [map])
        try hub.assign(.keyboard, to: player)
        let owner = UUID()
        hub.isEnabled = false
        hub.setInputSuppressed(true, owner: owner)
        #expect(!hub.isEnabled && player.isEnabled)
        hub.isEnabled = true
        hub.submit([(.key("space"), .button(true))], device: .keyboard)
        #expect(!player.input.value(for: fire).isPressed)
        hub.isEnabled = false
        hub.setInputSuppressed(false, owner: owner)
        #expect(!hub.isEnabled && player.isEnabled)
    }

    @Test func hubSuppressionStopsFeedbackAndPreservesTheBackendLease() throws {
        let hub = PlayerInputHub()
        let player = hub.addPlayer(named: "One", contexts: [map])
        let pad = InputDevice.controller(UUID()), backend = UUID(), owner = UUID()
        hub.connect(.init(id: pad, name: "Pad", supportsHaptics: true))
        try hub.assign(pad, to: player)
        let provider = LevelSuppressionFeedback()
        #expect(hub.attachBackend(owner: backend, feedbackProvider: provider))
        hub.submit([(.gamepadButton(.south), .button(false))], device: pad)
        hub.submit([(.gamepadButton(.south), .button(true))], device: pad)
        #expect(player.playFeedback(.impact) == .accepted)
        hub.setInputSuppressed(true, owner: owner)
        #expect(player.input.state(for: fire).phase == .cancelled)
        #expect(provider.stopped.contains(pad))
        #expect(player.playFeedback(.impact) == .unavailable)
        #expect(!hub.attachBackend(owner: UUID(), feedbackProvider: provider))
        hub.setInputSuppressed(false, owner: owner)
        #expect(hub.owner(of: pad) === player)
        #expect(player.activeDevice?.id == pad)
        #expect(player.playFeedback(.impact) == .accepted)
        hub.detachBackend(owner: backend)
        #expect(player.playFeedback(.impact) == .unavailable)
    }

    @Test func directPlayerSuppressionAlsoBlocksHubRoutingAndFeedback() throws {
        let hub = PlayerInputHub()
        let player = hub.addPlayer(named: "One", contexts: [map])
        try hub.assign(.keyboard, to: player)
        let pad = InputDevice.controller(UUID()), owner = UUID()
        hub.connect(.init(id: pad, name: "Pad", supportsHaptics: true))
        try hub.assign(pad, to: player)
        let provider = LevelSuppressionFeedback()
        #expect(hub.attachBackend(owner: UUID(), feedbackProvider: provider))
        player.input.setInputSuppressed(true, owner: owner)
        hub.submit([(.key("space"), .button(true))], device: .keyboard)
        #expect(!player.input.value(for: fire).isPressed)
        #expect(player.activeDevice == nil)
        #expect(player.playFeedback(.impact, on: pad) == .unavailable)
    }

    @Test func reentrantLeaseReleaseDoesNotLeaveLaterPlayersSuppressed() throws {
        let hub = PlayerInputHub()
        let first = hub.addPlayer(named: "First", contexts: [map])
        let second = hub.addPlayer(named: "Second", contexts: [map])
        try hub.assign(.keyboard, to: first)
        hub.submit([(.key("space"), .button(true))], device: .keyboard)
        let owner = UUID()
        let token = first.input.observe { event in
            if event.phase == .cancelled { hub.setInputSuppressed(false, owner: owner) }
        }
        hub.setInputSuppressed(true, owner: owner)
        second.input.setValue(.button(true), for: .key("space"), device: .keyboard)
        #expect(second.input.value(for: fire).isPressed)
        token.cancel()
    }

    @Test func playersAddedDuringCancellationInheritTheActiveLease() throws {
        let hub = PlayerInputHub()
        let first = hub.addPlayer(named: "First", contexts: [map])
        try hub.assign(.keyboard, to: first)
        hub.submit([(.key("space"), .button(true))], device: .keyboard)
        var added: PlayerInputSession?
        let contexts = [map]
        let token = first.input.observe { event in
            if event.phase == .cancelled { added = hub.addPlayer(named: "Added", contexts: contexts) }
        }
        let owner = UUID()
        hub.setInputSuppressed(true, owner: owner)
        let newcomer = try #require(added)
        newcomer.input.setValue(.button(true), for: .key("space"), device: .keyboard)
        #expect(!newcomer.input.value(for: fire).isPressed)
        hub.setInputSuppressed(false, owner: owner)
        newcomer.input.setValue(.button(false), for: .key("space"), device: .keyboard)
        newcomer.input.setValue(.button(true), for: .key("space"), device: .keyboard)
        #expect(newcomer.input.value(for: fire).isPressed)
        token.cancel()
    }

    @Test func activeDeviceCallbackSuppressionInvalidatesPendingHubPress() throws {
        let hub = PlayerInputHub()
        let player = hub.addPlayer(named: "One", contexts: [map])
        try hub.assign(.keyboard, to: player)
        let owner = UUID()
        let token = hub.observe { event in
            if case .activeDeviceChanged = event { hub.setInputSuppressed(true, owner: owner) }
        }
        hub.submit([(.key("space"), .button(true))], device: .keyboard)
        #expect(!player.input.value(for: fire).isPressed)
        token.cancel()
    }

    @Test func removingPlayerReleasesHubLeasesWithoutReleasingDirectLease() throws {
        let hub = PlayerInputHub()
        let player = hub.addPlayer(named: "Removed", contexts: [map])
        let first = UUID(), second = UUID(), direct = UUID()
        let pad = InputDevice.controller(UUID())
        hub.connect(.init(id: pad, name: "Pad", supportsHaptics: true))
        try hub.assign(pad, to: player)
        let provider = LevelSuppressionFeedback()
        #expect(hub.attachBackend(owner: UUID(), feedbackProvider: provider))
        hub.setInputSuppressed(true, owner: first)
        hub.setInputSuppressed(true, owner: second)
        player.input.setInputSuppressed(true, owner: direct)
        var reentered = false
        provider.onStop = { [weak hub, weak player] in
            guard !reentered, let hub, let player else { return }
            reentered = true
            hub.removePlayer(player)
            hub.setInputSuppressed(false, owner: first)
        }
        hub.removePlayer(player)
        provider.onStop = nil
        hub.setInputSuppressed(false, owner: second)
        #expect(reentered && hub.players.isEmpty)
        #expect(hub.owner(of: pad) == nil && player.devices.isEmpty)
        player.input.setValue(.button(false), for: .virtual("fire"), device: .virtual("overlay"))
        player.input.setValue(.button(true), for: .virtual("fire"), device: .virtual("overlay"))
        #expect(!player.input.value(for: fire).isPressed)
        player.input.setInputSuppressed(false, owner: direct)
        player.input.setValue(.button(true), for: .virtual("fire"), device: .virtual("overlay"))
        #expect(!player.input.value(for: fire).isPressed)
        player.input.setValue(.button(false), for: .virtual("fire"), device: .virtual("overlay"))
        player.input.setValue(.button(true), for: .virtual("fire"), device: .virtual("overlay"))
        #expect(player.input.value(for: fire).isPressed)
    }

    @Test func destroyingHubReleasesLeasesForRetainedSessions() throws {
        var hub: PlayerInputHub? = PlayerInputHub()
        weak let weakHub = hub
        let player = try #require(hub?.addPlayer(named: "Retained", contexts: [map]))
        let other = try #require(hub?.addPlayer(named: "Also retained", contexts: [map]))
        let direct = UUID()
        hub?.setInputSuppressed(true, owner: UUID())
        hub?.setInputSuppressed(true, owner: UUID())
        player.input.setInputSuppressed(true, owner: direct)
        for session in [player, other] {
            session.input.setValue(.button(true), for: .virtual("fire"), device: .virtual("overlay"))
        }
        hub = nil
        #expect(weakHub == nil && player.devices.isEmpty && other.devices.isEmpty)
        for session in [player, other] {
            session.input.setValue(.button(true), for: .virtual("fire"), device: .virtual("overlay"))
            #expect(!session.input.value(for: fire).isPressed)
            session.input.setValue(.button(false), for: .virtual("fire"), device: .virtual("overlay"))
            session.input.setValue(.button(true), for: .virtual("fire"), device: .virtual("overlay"))
        }
        #expect(!player.input.value(for: fire).isPressed)
        #expect(other.input.value(for: fire).isPressed)
        player.input.setInputSuppressed(false, owner: direct)
        player.input.setValue(.button(false), for: .virtual("fire"), device: .virtual("overlay"))
        player.input.setValue(.button(true), for: .virtual("fire"), device: .virtual("overlay"))
        #expect(player.input.value(for: fire).isPressed)
    }

    private func device(for control: InputControl) -> InputDevice {
        switch control {
        case .key: .keyboard
        case .pointerButton: .pointer
        case .gamepadButton, .gamepadAxis: .controller(UUID())
        case .virtual: .virtual("overlay")
        case .hinge: .hinge
        }
    }
}

@MainActor private final class LevelSuppressionFeedback: InputFeedbackProvider {
    var stopped: [InputDevice] = []
    var onStop: (() -> Void)?
    func play(_ feedback: ControllerFeedback, on device: InputDevice) -> InputFeedbackResult { .accepted }
    func stop(for device: InputDevice) { stopped.append(device); onStop?() }
}
