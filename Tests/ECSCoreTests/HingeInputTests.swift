import Foundation
@_spi(Backend) @testable import ECSCore
import Testing

@Suite struct HingeInputTests {
    @Test func stateClampsFiniteAnglesAndNormalizesOpenness() throws {
        let closed = try #require(GameHingeState(angle: -100, status: .closed))
        let partial = try #require(GameHingeState(angle: .pi / 2, status: .partiallyOpen))
        let open = try #require(GameHingeState(angle: .greatestFiniteMagnitude, status: .fullyOpen))
        #expect(closed.angle == 0 && closed.openness == 0)
        #expect(partial.angle == .pi / 2 && partial.openness == 0.5)
        #expect(open.angle == .pi && open.openness == 1)
        #expect(Set([closed, closed, partial, open]).count == 3)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func stateRejectsNonfiniteAngles(angle: Double) {
        #expect(GameHingeState(angle: angle, status: .closed) == nil)
    }

    @Test(arguments: [GameHingeState.Status.unknown, .closed, .partiallyOpen, .fullyOpen])
    func statusIsPreservedRatherThanInferred(status: GameHingeState.Status) throws {
        let state = try #require(GameHingeState(angle: .pi, status: status))
        #expect(state.status == status)
        let decoded = try JSONDecoder().decode(GameHingeState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
    }

    @Test func configurationDefaultsAndSanitization() {
        let defaults = HingeInputConfiguration()
        #expect(defaults.neutralAngle == .pi)
        #expect(defaults.activationAngle == .pi / 2)
        #expect(defaults.deadZone == 0.05)
        #expect(defaults.smoothing == 0.08)

        let clamped = HingeInputConfiguration(neutralAngle: -1, activationAngle: 100, deadZone: 2, smoothing: 0)
        #expect(clamped.neutralAngle == 0 && clamped.activationAngle == .pi)
        #expect(clamped.deadZone == 0.99 && clamped.smoothing == 0)
        #expect(HingeInputConfiguration(deadZone: -1).deadZone == 0)
        #expect(HingeInputConfiguration(smoothing: 2).smoothing == 2)
        #expect(HingeInputConfiguration(smoothing: -1).smoothing == 0.08)

        let invalid = HingeInputConfiguration(neutralAngle: .nan, activationAngle: -.infinity,
                                             deadZone: .infinity, smoothing: .infinity)
        #expect(invalid == defaults)
        #expect(HingeInputConfiguration(neutralAngle: .infinity, activationAngle: .nan,
                                       deadZone: .nan, smoothing: .nan) == defaults)
        #expect(HingeInputConfiguration(smoothing: -.infinity).smoothing == 0.08)
    }

    @Test func defaultMappingActivatesFoldingAndClampsBeyondActivation() {
        let configuration = HingeInputConfiguration()
        #expect(configuration.value(for: GameHingeState(angle: .pi, status: .fullyOpen)) == 0)
        #expect(configuration.value(for: GameHingeState(angle: .pi / 2, status: .partiallyOpen)) == 1)
        #expect(configuration.value(for: GameHingeState(angle: 0, status: .closed)) == 1)
    }

    @Test func missingUnknownAndEqualEndpointsAreNeutral() {
        let configuration = HingeInputConfiguration()
        #expect(configuration.value(for: nil) == 0)
        #expect(configuration.value(for: GameHingeState(angle: 0, status: .unknown)) == 0)
        let equal = HingeInputConfiguration(neutralAngle: 1, activationAngle: 1)
        #expect(equal.value(for: GameHingeState(angle: 0, status: .closed)) == 0)
        #expect(equal.value(for: GameHingeState(angle: .pi, status: .fullyOpen)) == 0)
        let clampedEqual = HingeInputConfiguration(neutralAngle: -1, activationAngle: -2)
        #expect(clampedEqual.value(for: GameHingeState(angle: 1, status: .partiallyOpen)) == 0)
    }

    @Test func signedMappingRescalesDeadZoneAndClampsBothDirections() {
        let configuration = HingeInputConfiguration(neutralAngle: 1, activationAngle: 2, deadZone: 0.25)
        func value(_ angle: Double) -> Float {
            configuration.value(for: GameHingeState(angle: angle, status: .partiallyOpen))
        }
        #expect(value(1) == 0)
        #expect(value(1.125) == 0 && value(0.875) == 0)
        #expect(value(1.25) == 0 && value(0.75) == 0)
        #expect(value(1.625) == 0.5 && value(0.375) == -0.5)
        #expect(value(2) == 1 && value(0) == -1)
        #expect(value(.pi) == 1)

        let reversed = HingeInputConfiguration(neutralAngle: 2, activationAngle: 1, deadZone: 0)
        #expect(reversed.value(for: GameHingeState(angle: 1.5, status: .partiallyOpen)) == 0.5)
        #expect(reversed.value(for: GameHingeState(angle: 2.5, status: .partiallyOpen)) == -0.5)
        #expect(reversed.value(for: GameHingeState(angle: .pi, status: .fullyOpen)) == -1)
    }

    @Test func configurationCodableRoundTripAndDecodedSanitization() throws {
        let configuration = HingeInputConfiguration(neutralAngle: 1.25, activationAngle: 0.5,
                                                    deadZone: 0.2, smoothing: 0.12)
        let data = try JSONEncoder().encode(configuration)
        #expect(try JSONDecoder().decode(HingeInputConfiguration.self, from: data) == configuration)
        let clamped = Data(#"{"neutralAngle":-2,"activationAngle":9,"deadZone":4,"smoothing":-1}"#.utf8)
        let decoded = try JSONDecoder().decode(HingeInputConfiguration.self, from: clamped)
        #expect(decoded == HingeInputConfiguration(neutralAngle: 0, activationAngle: .pi,
                                                  deadZone: 0.99, smoothing: 0.08))
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        let nonfinite = Data(#"{"neutralAngle":"NaN","activationAngle":"Infinity","deadZone":"-Infinity","smoothing":"NaN"}"#.utf8)
        #expect(try decoder.decode(HingeInputConfiguration.self, from: nonfinite) == HingeInputConfiguration())
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(HingeInputConfiguration.self, from: Data(#"{"deadZone":"bad"}"#.utf8))
        }
    }

    @Test(arguments: ["NaN", "Infinity", "-Infinity"])
    func stateDecodingRejectsNonfiniteAngles(angle: String) {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        let data = Data("{\"angle\":\"\(angle)\",\"status\":\"closed\"}".utf8)
        #expect(throws: DecodingError.self) { try decoder.decode(GameHingeState.self, from: data) }
    }

    @Test func stateDecodingClampsFiniteAnglesAndRejectsCorruption() throws {
        let low = try JSONDecoder().decode(GameHingeState.self, from: Data(#"{"angle":-1,"status":"fullyOpen"}"#.utf8))
        let high = try JSONDecoder().decode(GameHingeState.self, from: Data(#"{"angle":100,"status":"closed"}"#.utf8))
        #expect(low.angle == 0 && low.status == .fullyOpen)
        #expect(high.angle == .pi && high.status == .closed)
        for json in [#"{"angle":null,"status":"closed"}"#,
                     #"{"angle":1,"status":"invalid"}"#,
                     #"{"angle":1}"#,
                     #"{"status":"closed"}"#] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(GameHingeState.self, from: Data(json.utf8))
            }
        }
    }

    @Test func hingeBindingsAndDevicesSerializeAsTypedCases() throws {
        let action = InputAction("fold", kind: .axis)
        let map = InputActionMap(name: "play", bindings: [.init(action, control: .hinge)])
        #expect(try JSONDecoder().decode(InputActionMap.self, from: JSONEncoder().encode(map)) == map)
        #expect(try JSONDecoder().decode(InputControl.self, from: Data(#"{"hinge":{}}"#.utf8)) == .hinge)
        #expect(try JSONDecoder().decode(InputDevice.self, from: Data(#"{"hinge":{}}"#.utf8)) == .hinge)
        #expect(try JSONDecoder().decode(InputDevice.self, from: JSONEncoder().encode(InputDevice.hinge)) == .hinge)
        #expect(InputDevice.virtual("last").sortKey < InputDevice.hinge.sortKey)
        #expect(InputDevice.virtual("last").sortKey == "3last")
        #expect(InputDevice.hinge.sortKey == "4")
    }

    @MainActor @Test func hingePromptsRequireAssignmentAndFallBackAcrossOwnedBindings() throws {
        let hub = PlayerInputHub()
        let action = InputAction("fold", kind: .axis)
        let hingeOnly = InputAction("hinge-only", kind: .axis)
        let map = InputActionMap(name: "play", bindings: [
            .init(action, control: .hinge), .init(action, control: .key("space")),
            .init(hingeOnly, control: .hinge)
        ])
        let player = hub.addPlayer(named: "One", contexts: [map])
        hub.connect(.init(id: .hinge, name: "Hinge"))
        #expect(player.prompt(for: action) == nil)
        hub.submit([(.hinge, .axis(0.5))], device: .hinge)
        #expect(player.input.value(for: action) == .axis(0))
        hub.submit([(.hinge, .axis(0))], device: .hinge)
        try hub.assign(.hinge, to: player)
        #expect(player.prompt(for: action)?.device == .hinge)
        #expect(player.prompt(for: action)?.control == .hinge)
        #expect(player.prompt(for: action)?.label == "Fold")
        #expect(player.prompt(for: action)?.symbolName == "rectangle.split.2x1")
        try hub.assign(.keyboard, to: player)
        #expect(player.devices.map(\.id) == [.keyboard, .hinge])
        #expect(player.prompt(for: action)?.device == .keyboard)
        hub.submit([(.hinge, .axis(0.5))], device: .hinge)
        #expect(player.activeDevice?.id == .hinge)
        #expect(player.input.value(for: action) == .axis(0.5))
        #expect(player.prompt(for: action)?.device == .hinge)
        hub.submit([(.key("space"), .button(true))], device: .keyboard)
        #expect(player.activeDevice?.id == .keyboard)
        #expect(player.prompt(for: action)?.label == "Space")
        #expect(player.prompt(for: hingeOnly)?.label == "Fold")
        hub.submit([(.key("space"), .button(false))], device: .keyboard)
        #expect(player.input.value(for: action) == .axis(0.5))
        hub.disconnect(.hinge)
        #expect(hub.owner(of: .hinge) == nil)
        #expect(player.input.value(for: action) == .axis(0))
        #expect(player.prompt(for: action)?.device == .keyboard)
        #expect(player.prompt(for: hingeOnly) == nil)
    }

    @MainActor @Test func hingePromptUsesMetadataAndDoesNotMatchOtherDevices() throws {
        let hub = PlayerInputHub()
        let action = InputAction("fold", kind: .axis)
        let player = hub.addPlayer(named: "One", contexts: [
            .init(name: "play", bindings: [.init(action, control: .hinge)])
        ])
        try hub.assign(.keyboard, to: player)
        try hub.assign(.pointer, to: player)
        #expect(player.prompt(for: action) == nil)
        hub.connect(.init(id: .hinge, name: "Hinge", presentations: [
            .hinge: .init(label: "Bend", symbolName: "custom.hinge")
        ]))
        try hub.assign(.hinge, to: player)
        #expect(player.prompt(for: action)?.label == "Bend")
        #expect(player.prompt(for: action)?.symbolName == "custom.hinge")
        hub.unassign(.hinge)
        #expect(player.prompt(for: action) == nil)
    }

    @MainActor @Test func hingeFeedbackIsUnsupportedEvenWithControllerAvailable() throws {
        let hub = PlayerInputHub()
        let action = InputAction("fold", kind: .axis)
        let player = hub.addPlayer(named: "One", contexts: [
            .init(name: "play", bindings: [.init(action, control: .hinge)])
        ])
        let provider = HingeRecordingFeedback()
        #expect(hub.attachBackend(owner: UUID(), feedbackProvider: provider))
        let controller = InputDevice.controller(UUID())
        hub.connect(.init(id: controller, name: "Pad", supportsHaptics: true))
        try hub.assign(controller, to: player)
        hub.connect(.init(id: .hinge, name: "Hinge", supportsHaptics: true))
        try hub.assign(.hinge, to: player)
        hub.submit([(.hinge, .axis(0))], device: .hinge)
        hub.submit([(.hinge, .axis(0.75))], device: .hinge)
        #expect(player.activeDevice?.id == .hinge)
        #expect(player.playFeedback(.impact) == .unsupported)
        #expect(player.playFeedback(.impact, on: .hinge) == .unsupported)
        #expect(provider.played.isEmpty)
        #expect(player.playFeedback(.impact, on: controller) == .accepted)
        #expect(provider.played == [controller])
    }

    @MainActor @Test func firstHeldHingeSnapshotRequiresNeutralWithZeroSmoothing() throws {
        let hub = PlayerInputHub()
        let action = InputAction("fold", kind: .axis)
        let player = hub.addPlayer(named: "One", contexts: [
            .init(name: "play", bindings: [.init(action, control: .hinge)])
        ])
        let configuration = HingeInputConfiguration(deadZone: 0, smoothing: 0)
        let held = configuration.value(for: GameHingeState(angle: .pi / 2, status: .partiallyOpen))
        hub.connect(.init(id: .hinge, name: "Hinge"))
        try hub.assign(.hinge, to: player)
        hub.submit([(.hinge, .axis(held))], device: .hinge)
        hub.submit([(.hinge, .axis(held))], device: .hinge)
        #expect(player.input.value(for: action) == .axis(0))
        #expect(player.activeDevice == nil)
        hub.submit([(.hinge, .axis(0))], device: .hinge)
        hub.submit([(.hinge, .axis(held))], device: .hinge)
        #expect(player.input.value(for: action) == .axis(1))
        #expect(player.activeDevice?.id == .hinge)
    }

    @MainActor @Test(arguments: [true, false])
    func hingeCancellationRequiresFreshNeutralBaseline(cancelHub: Bool) throws {
        let hub = PlayerInputHub()
        let action = InputAction("fold", kind: .axis)
        let player = hub.addPlayer(named: "One", contexts: [
            .init(name: "play", bindings: [.init(action, control: .hinge)])
        ])
        hub.connect(.init(id: .hinge, name: "Hinge"))
        try hub.assign(.hinge, to: player)
        hub.submit([(.hinge, .axis(0))], device: .hinge)
        if cancelHub { hub.cancelAll() } else { player.input.cancelAll() }
        hub.submit([(.hinge, .axis(0.8))], device: .hinge)
        #expect(player.input.value(for: action) == .axis(0))
        hub.submit([(.hinge, .axis(0))], device: .hinge)
        hub.submit([(.hinge, .axis(0.8))], device: .hinge)
        #expect(player.input.value(for: action) == .axis(0.8))
    }

    @MainActor @Test func unassignedHeldHingeAndTransferRespectBothOwnersDeadZones() throws {
        let hub = PlayerInputHub()
        let action = InputAction("fold", kind: .axis)
        let first = hub.addPlayer(named: "One", contexts: [
            .init(name: "loose", bindings: [.init(action, control: .hinge, deadZone: 0.2)])
        ])
        let second = hub.addPlayer(named: "Two", contexts: [
            .init(name: "strict", bindings: [.init(action, control: .hinge, deadZone: 0.05)])
        ])
        hub.connect(.init(id: .hinge, name: "Hinge"))
        hub.submit([(.hinge, .axis(0.8))], device: .hinge)
        try hub.assign(.hinge, to: first)
        hub.submit([(.hinge, .axis(0.8))], device: .hinge)
        #expect(!first.input.value(for: action).isPressed)
        hub.submit([(.hinge, .axis(0))], device: .hinge)
        hub.submit([(.hinge, .axis(0.8))], device: .hinge)
        #expect(first.input.value(for: action).isPressed)
        try hub.assign(.hinge, to: second)
        #expect(hub.owner(of: .hinge) === second)
        #expect(first.input.state(for: action).phase == .cancelled)
        hub.submit([(.hinge, .axis(0.1))], device: .hinge)
        #expect(!second.input.value(for: action).isPressed)
        hub.submit([(.hinge, .axis(0.01))], device: .hinge)
        hub.submit([(.hinge, .axis(0.8))], device: .hinge)
        #expect(second.input.value(for: action).isPressed)
        hub.unassign(.hinge)
        try hub.assign(.hinge, to: first)
        hub.submit([(.hinge, .axis(0.8))], device: .hinge)
        #expect(!first.input.value(for: action).isPressed)
        hub.submit([(.hinge, .axis(0))], device: .hinge)
        hub.submit([(.hinge, .axis(0.8))], device: .hinge)
        #expect(first.input.value(for: action).isPressed)
    }

    @MainActor @Test func controllerCoordinateChangeCancelsOtherProducersAtomically() {
        let fold = InputAction("fold", kind: .axis)
        let hingeOnly = InputAction("hinge-only", kind: .axis)
        let key = InputAction("key")
        let touch = InputAction("touch")
        let input = InputController(contexts: [.init(name: "play", bindings: [
            .init(fold, control: .hinge), .init(fold, control: .key("space")),
            .init(fold, control: .virtual("fold")), .init(hingeOnly, control: .hinge),
            .init(key, control: .key("k")), .init(touch, control: .virtual("fire"))
        ])])
        input.setValue(.axis(0.75), for: .hinge, device: .hinge)
        input.setValues([(.key("space"), .button(true)), (.key("k"), .button(true))], device: .keyboard)
        input.setValues([(.virtual("fold"), .axis(0.9)), (.virtual("fire"), .button(true))], device: .virtual("overlay"))
        var globalCancellations = 0
        var cancelledDevices: [InputDevice] = []
        input.onCancellation = { globalCancellations += 1 }
        input.onDeviceCancellation = { cancelledDevices.append($0) }
        var events: [InputActionEvent] = []
        let token = input.observe { event in
            events.append(event)
            #expect(input.value(for: fold) == .axis(0.75))
            #expect(input.value(for: hingeOnly) == .axis(0.75))
            #expect(!input.value(for: key).isPressed && !input.value(for: touch).isPressed)
        }
        input.cancelForCoordinateSpaceChange()
        token.cancel()
        #expect(globalCancellations == 0)
        #expect(cancelledDevices == [.keyboard, .virtual("overlay")])
        #expect(events.filter { $0.action == fold }.map(\.phase) == [.changed])
        #expect(events.filter { $0.action == hingeOnly }.isEmpty)
        #expect(events.filter { $0.action == key || $0.action == touch }.map(\.phase) == [.cancelled, .cancelled])
        input.setValue(.button(true), for: .key("k"), device: .keyboard)
        input.setValue(.button(true), for: .virtual("fire"), device: .virtual("overlay"))
        #expect(!input.value(for: key).isPressed && !input.value(for: touch).isPressed)
        input.setValue(.axis(0.8), for: .hinge, device: .hinge)
        #expect(input.value(for: fold) == .axis(0.8))
        input.cancelAll()
        input.setValue(.axis(0.9), for: .hinge, device: .hinge)
        #expect(input.value(for: fold) == .axis(0))
        input.setValue(.axis(0), for: .hinge, device: .hinge)
        input.setValue(.axis(0.9), for: .hinge, device: .hinge)
        #expect(input.value(for: fold) == .axis(0.9))
    }

    @MainActor @Test func controllerCoordinateCancellationGatesReentrantSamples() {
        let fold = InputAction("fold", kind: .axis)
        let fire = InputAction("fire")
        let input = InputController(contexts: [.init(name: "play", bindings: [
            .init(fold, control: .hinge), .init(fire, control: .key("space")),
            .init(fire, control: .virtual("fire"))
        ])])
        input.setValue(.axis(0.5), for: .hinge, device: .hinge)
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        var events: [InputActionEvent] = []
        let token = input.observe { events.append($0) }
        input.onDeviceCancellation = { _ in
            input.cancelForCoordinateSpaceChange()
            input.setValue(.button(true), for: .virtual("fire"), device: .virtual("overlay"))
            input.setValue(.axis(0.75), for: .hinge, device: .hinge)
        }
        input.cancelForCoordinateSpaceChange()
        #expect(input.value(for: fold) == .axis(0.75))
        #expect(!input.value(for: fire).isPressed)
        #expect(events.filter { $0.action == fire }.map(\.phase) == [.cancelled])
        #expect(events.filter { $0.action == fold }.map(\.phase) == [.changed])
        token.cancel()
    }

    @MainActor @Test func hubCoordinateChangesPreserveHingeWhileGatingKeyboardAndVirtual() throws {
        let hub = PlayerInputHub()
        let fold = InputAction("fold", kind: .axis)
        let key = InputAction("key")
        let touch = InputAction("touch")
        let player = hub.addPlayer(named: "One", contexts: [.init(name: "play", bindings: [
            .init(fold, control: .hinge), .init(key, control: .key("space")),
            .init(touch, control: .virtual("fire"))
        ])])
        let provider = HingeRecordingFeedback()
        #expect(hub.attachBackend(owner: UUID(), feedbackProvider: provider))
        hub.connect(.init(id: .hinge, name: "Hinge"))
        hub.connect(.init(id: .virtual("overlay"), name: "Overlay"))
        for device in [InputDevice.hinge, .keyboard, .virtual("overlay")] {
            try hub.assign(device, to: player)
        }
        hub.submit([(.hinge, .axis(0))], device: .hinge)
        hub.submit([(.hinge, .axis(0.5))], device: .hinge)
        hub.submit([(.key("space"), .button(true))], device: .keyboard)
        hub.submit([(.virtual("fire"), .button(true))], device: .virtual("overlay"))
        provider.stopped.removeAll()
        hub.cancelForCoordinateSpaceChange()
        #expect(hub.owner(of: .hinge) === player)
        #expect(player.input.value(for: fold) == .axis(0.5))
        #expect(player.input.state(for: key).phase == .cancelled)
        #expect(player.input.state(for: touch).phase == .cancelled)
        #expect(!provider.stopped.contains(.hinge))
        #expect(provider.stopped.contains(.keyboard) && provider.stopped.contains(.virtual("overlay")))
        for value in [Float(0.6), 0.7, 0.8] {
            hub.cancelForCoordinateSpaceChange()
            hub.submit([(.hinge, .axis(value))], device: .hinge)
            #expect(player.input.value(for: fold) == .axis(value))
        }
        hub.submit([(.key("space"), .button(true))], device: .keyboard)
        hub.submit([(.virtual("fire"), .button(true))], device: .virtual("overlay"))
        #expect(!player.input.value(for: key).isPressed && !player.input.value(for: touch).isPressed)
        hub.submit([(.key("space"), .button(false))], device: .keyboard)
        hub.submit([(.key("space"), .button(true))], device: .keyboard)
        #expect(player.input.value(for: key).isPressed)
        hub.cancelAll()
        hub.submit([(.hinge, .axis(0.9))], device: .hinge)
        #expect(player.input.value(for: fold) == .axis(0))
        hub.cancelForCoordinateSpaceChange()
        hub.submit([(.hinge, .axis(0.8))], device: .hinge)
        #expect(player.input.value(for: fold) == .axis(0))
        hub.submit([(.hinge, .axis(0))], device: .hinge)
        hub.submit([(.hinge, .axis(0.8))], device: .hinge)
        #expect(player.input.value(for: fold) == .axis(0.8))
    }

    @MainActor @Test func hubCoordinateCancellationAllowsReentrantHingeUpdates() throws {
        let hub = PlayerInputHub()
        let fold = InputAction("fold", kind: .axis)
        let fire = InputAction("fire")
        let player = hub.addPlayer(named: "One", contexts: [.init(name: "play", bindings: [
            .init(fold, control: .hinge), .init(fire, control: .key("space"))
        ])])
        hub.connect(.init(id: .hinge, name: "Hinge"))
        try hub.assign(.hinge, to: player)
        try hub.assign(.keyboard, to: player)
        hub.submit([(.hinge, .axis(0))], device: .hinge)
        hub.submit([(.hinge, .axis(0.5))], device: .hinge)
        hub.submit([(.key("space"), .button(true))], device: .keyboard)
        let token = player.input.observe(action: fire) { event in
            guard event.phase == .cancelled else { return }
            hub.cancelForCoordinateSpaceChange()
            hub.submit([(.hinge, .axis(0.8))], device: .hinge)
        }
        hub.cancelForCoordinateSpaceChange()
        #expect(player.input.value(for: fold) == .axis(0.8))
        hub.submit([(.hinge, .axis(0.9))], device: .hinge)
        #expect(player.input.value(for: fold) == .axis(0.9))
        token.cancel()
    }

    @MainActor @Test func reentrantFullCancellationOverridesCoordinatePreservation() throws {
        let hub = PlayerInputHub()
        let fold = InputAction("fold", kind: .axis)
        let fire = InputAction("fire")
        let player = hub.addPlayer(named: "One", contexts: [.init(name: "play", bindings: [
            .init(fold, control: .hinge), .init(fire, control: .key("space"))
        ])])
        hub.connect(.init(id: .hinge, name: "Hinge"))
        try hub.assign(.hinge, to: player)
        try hub.assign(.keyboard, to: player)
        hub.submit([(.hinge, .axis(0))], device: .hinge)
        hub.submit([(.hinge, .axis(0.5))], device: .hinge)
        hub.submit([(.key("space"), .button(true))], device: .keyboard)
        let token = player.input.observe(action: fire) { event in
            guard event.phase == .cancelled else { return }
            hub.cancelAll()
            hub.submit([(.hinge, .axis(0.9))], device: .hinge)
        }
        hub.cancelForCoordinateSpaceChange()
        #expect(hub.owner(of: .hinge) === player)
        #expect(player.input.value(for: fold) == .axis(0))
        #expect(player.input.state(for: fold).phase == .cancelled)
        hub.submit([(.hinge, .axis(0.8))], device: .hinge)
        #expect(player.input.value(for: fold) == .axis(0))
        hub.submit([(.hinge, .axis(0))], device: .hinge)
        hub.submit([(.hinge, .axis(0.8))], device: .hinge)
        #expect(player.input.value(for: fold) == .axis(0.8))
        token.cancel()
    }

    @MainActor @Test func hingeEventsPreserveSamplesAndAvailability() throws {
        let world = World()
        let sample = try #require(GameHingeState(angle: 1, status: .partiallyOpen))
        let appeared = GameHingeEvents.DidChange(scene: world, previous: nil, state: sample)
        #expect(appeared.scene === world)
        #expect(appeared.previous == nil && appeared.state == sample)
        let disappeared = GameHingeEvents.DidChange(scene: world, previous: sample, state: nil)
        #expect(disappeared.previous == sample && disappeared.state == nil)
    }
}

@MainActor private final class HingeRecordingFeedback: InputFeedbackProvider {
    var played: [InputDevice] = []
    var stopped: [InputDevice] = []
    func play(_ feedback: ControllerFeedback, on device: InputDevice) -> InputFeedbackResult {
        played.append(device)
        return .accepted
    }
    func stop(for device: InputDevice) { stopped.append(device) }
}
