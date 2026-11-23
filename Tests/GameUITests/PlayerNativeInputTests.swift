@_spi(Backend) import ECSCore
import Foundation
import GameController
@testable import GameUI
import SwiftUI
import Testing

@MainActor @Suite struct PlayerNativeInputTests {
    let fire = InputAction("fire")
    let move = InputAction("move", kind: .axis2D)

    func player(in hub: PlayerInputHub, name: String = "Player") -> PlayerInputSession {
        hub.addPlayer(named: name, contexts: [.init(name: "play", bindings: [
            .init(fire, control: .key("space")), .init(fire, control: .pointerButton(0)),
            .init(fire, control: .gamepadButton(.south)),
            .init(move, control: .gamepadAxis(.leftStick), deadZone: 0.2)
        ])])
    }

    func session(for hub: PlayerInputHub) -> GameInputSession {
        let session = GameInputSession()
        session.configure(nil, hub: hub)
        session.availability = .init(visible: true, focused: true, sceneActive: true,
                                     scopeActive: true, windowActive: true)
        session.refresh()
        return session
    }

    @Test func modifierSupportsHubAndLegacyScopes() {
        _ = Color.clear.gameInput(PlayerInputHub())
        _ = Color.clear.gameInput(PlayerInputHub(), isActive: false)
        _ = Color.clear.gameInput(InputController())
    }

    @Test func discoveryLeavesDevicesUnassignedAndRetainsTheirHeldBaseline() throws {
        let hub = PlayerInputHub(), session = session(for: hub)
        defer { session.stop() }
        let player = player(in: hub)
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        pad.buttonA.setValue(1)
        session.controllers.poll(controllers: [controller])
        let device = try #require(hub.devices.first { if case .controller = $0.id { true } else { false } })
        #expect(hub.owner(of: device.id) == nil)
        try hub.assign(device.id, to: player)
        session.controllers.poll(controllers: [controller])
        #expect(!player.input.value(for: fire).isPressed)
        pad.buttonA.setValue(0)
        session.controllers.poll(controllers: [controller])
        pad.buttonA.setValue(1)
        session.controllers.poll(controllers: [controller])
        #expect(player.input.value(for: fire).isPressed)
        #expect(player.activeDevice?.id == device.id)
    }

    @Test func controllerRoutesToItsAssignedPlayerAndReassignmentRequiresNeutral() throws {
        let hub = PlayerInputHub(), session = session(for: hub)
        defer { session.stop() }
        let first = player(in: hub), second = player(in: hub, name: "Second")
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        session.controllers.poll(controllers: [controller])
        let device = try #require(hub.devices.first { if case .controller = $0.id { true } else { false } })
        try hub.assign(device.id, to: first)
        pad.buttonA.setValue(1)
        session.controllers.poll(controllers: [controller])
        #expect(first.input.value(for: fire).isPressed)
        #expect(!second.input.value(for: fire).isPressed)
        try hub.assign(device.id, to: second)
        session.controllers.poll(controllers: [controller])
        #expect(!first.input.value(for: fire).isPressed && !second.input.value(for: fire).isPressed)
        pad.buttonA.setValue(0)
        session.controllers.poll(controllers: [controller])
        pad.buttonA.setValue(1)
        session.controllers.poll(controllers: [controller])
        #expect(second.input.value(for: fire).isPressed)
    }

    @Test func keyboardAndPointerUseTheirIndependentOwnersAndFocusCancelsBoth() throws {
        let hub = PlayerInputHub(), session = session(for: hub)
        defer { session.stop() }
        let first = player(in: hub), second = player(in: hub, name: "Second")
        try hub.assign(.keyboard, to: first)
        try hub.assign(.pointer, to: second)
        #expect(session.router.key("space", pressed: true))
        session.router.pointer(0, pressed: true)
        #expect(first.input.value(for: fire).isPressed && second.input.value(for: fire).isPressed)
        session.availability.focused = false
        session.refresh()
        #expect(first.input.state(for: fire).phase == .cancelled)
        #expect(second.input.state(for: fire).phase == .cancelled)
        #expect(hub.owner(of: .keyboard) === first && hub.owner(of: .pointer) === second)
        session.router.releaseKeys()
        session.router.reconcilePointerButtons(pressed: [])
        session.availability.focused = true
        session.refresh()
        #expect(session.router.key("space", pressed: true))
        session.router.pointer(0, pressed: true)
        #expect(first.input.value(for: fire).isPressed && second.input.value(for: fire).isPressed)
    }

    @Test func resumeRequiresNeutralEvenWhenTheLastActiveSampleWasNeutral() throws {
        let hub = PlayerInputHub(), session = session(for: hub)
        defer { session.stop() }
        let player = player(in: hub)
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        session.controllers.poll(controllers: [controller])
        let device = try #require(hub.devices.first { if case .controller = $0.id { true } else { false } })
        try hub.assign(device.id, to: player)
        session.availability.focused = false
        session.refresh()
        pad.buttonA.setValue(1)
        pad.leftThumbstick.setValueForXAxis(0.8, yAxis: 0)
        session.controllers.poll(controllers: [controller])
        session.availability.focused = true
        session.refresh()
        session.controllers.poll(controllers: [controller])
        #expect(!player.input.value(for: fire).isPressed)
        #expect(!player.input.value(for: move).isPressed)
        #expect(hub.owner(of: device.id) === player)
        pad.buttonA.setValue(0)
        pad.leftThumbstick.setValueForXAxis(0.1, yAxis: 0)
        session.controllers.poll(controllers: [controller])
        pad.buttonA.setValue(1)
        pad.leftThumbstick.setValueForXAxis(0.8, yAxis: 0)
        session.controllers.poll(controllers: [controller])
        #expect(player.input.value(for: fire).isPressed)
        #expect(player.input.value(for: move).vector.x > 0.7)
    }

    @Test func rejectedBackendCannotRouteCancelOrDisconnectTheCurrentHost() throws {
        let hub = PlayerInputHub(), first = session(for: hub)
        defer { first.stop() }
        let player = player(in: hub)
        try hub.assign(.keyboard, to: player)
        first.router.key("space", pressed: true)
        let second = session(for: hub)
        #expect(!second.router.hasBackendLease && !second.router.isActive)
        second.controllers.poll(controllers: [GCController.withExtendedGamepad()])
        second.stop()
        #expect(player.input.value(for: fire).isPressed)
        #expect(hub.devices.count == 2)
        #expect(first.router.isActive)
    }

    @Test func stoppedSessionCanReattachItsBackend() throws {
        let hub = PlayerInputHub(), session = session(for: hub)
        let player = player(in: hub)
        try hub.assign(.keyboard, to: player)
        session.stop()
        session.configure(nil, hub: hub)
        session.availability.visible = true
        session.refresh()
        defer { session.stop() }
        #expect(session.router.hasBackendLease)
        #expect(session.router.key("space", pressed: true))
        #expect(player.input.value(for: fire).isPressed)
    }

    @Test func hostCancellationClearsContactsBeforePlayerCallbacks() throws {
        let hub = PlayerInputHub(), session = session(for: hub), host = GameHost()
        defer { session.stop() }
        let player = player(in: hub)
        try hub.assign(.keyboard, to: player)
        session.bind([.init(id: host.inputHostID, host: host)])
        host.beginInput(at: .zero)
        var cleared = false
        let token = player.input.observe { event in
            if event.phase == .cancelled {
                cleared = host.inputContacts.isEmpty
                host.cancelInputs()
            }
        }
        session.router.key("space", pressed: true)
        host.cancelInputs()
        #expect(cleared)
        #expect(player.input.state(for: fire).phase == .cancelled)
        #expect(hub.owner(of: .keyboard) === player)
        token.cancel()
    }

    @Test func discoveryPublishesRemappedPresentationsAndRefreshesThemWithoutChangingIdentity() throws {
        let hub = PlayerInputHub(), session = session(for: hub)
        defer { session.stop() }
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        pad.buttonA.unmappedLocalizedName = "Original South"
        pad.buttonA.unmappedSfSymbolsName = "a.circle"
        pad.buttonA.localizedName = "Remapped East"
        pad.buttonA.sfSymbolsName = "b.circle"
        session.controllers.poll(controllers: [controller])
        let before = try #require(hub.devices.first { if case .controller = $0.id { true } else { false } })
        #expect(before.presentations[.gamepadButton(.south)] == .init(label: "Remapped East", symbolName: "b.circle"))
        #expect(before.supportsHaptics == (controller.haptics != nil))
        #expect(before.hasRemappedElements == controller.physicalInputProfile.hasRemappedElements)
        pad.buttonA.localizedName = "Updated Label"
        session.controllers.poll(controllers: [controller])
        let after = try #require(hub.devices.first { $0.id == before.id })
        #expect(after.presentations[.gamepadButton(.south)]?.label == "Updated Label")
    }

    @Test func disconnectAndReconnectUseANewIdentityAndPreserveAppCallbacks() throws {
        let hub = PlayerInputHub(), session = session(for: hub)
        defer { session.stop() }
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        controller.handlerQueue = .main
        controller.playerIndex = .index2
        pad.valueChangedHandler = { _, _ in }
        pad.buttonA.pressedChangedHandler = { _, _, _ in }
        controller.physicalInputProfile.valueDidChangeHandler = { _, _ in }
        session.controllers.poll(controllers: [controller])
        let before = try #require(hub.devices.first { if case .controller = $0.id { true } else { false } })
        session.controllers.poll(controllers: [])
        #expect(!hub.devices.contains { $0.id == before.id })
        session.controllers.poll(controllers: [controller])
        let after = try #require(hub.devices.first { if case .controller = $0.id { true } else { false } })
        #expect(after.id != before.id)
        session.stop()
        #expect(pad.valueChangedHandler != nil && pad.buttonA.pressedChangedHandler != nil)
        #expect(controller.physicalInputProfile.valueDidChangeHandler != nil)
        #expect(controller.handlerQueue === DispatchQueue.main)
        #expect(controller.playerIndex == .index2)
    }

    @Test func pollingStopsIfDiscoveryReentrantlyStopsTheAdapter() {
        let hub = PlayerInputHub(), session = session(for: hub)
        let token = hub.observe { event in
            if case .connected = event { session.stop() }
        }
        session.controllers.poll(controllers: [GCController.withExtendedGamepad(), GCController.withExtendedGamepad()])
        #expect(!session.router.hasBackendLease)
        #expect(hub.devices.count == 2)
        token.cancel()
    }
}

@MainActor @Suite struct NativeControllerFeedbackTests {
    final class Playback: ControllerFeedbackPlayback {
        enum Failure: Error { case hardware }
        var plays: [ControllerFeedback] = []
        var stops = 0
        var fails = false
        func play(_ feedback: ControllerFeedback) throws {
            if fails { throw Failure.hardware }
            plays.append(feedback)
        }
        func stop() { stops += 1 }
    }

    @Test func feedbackReportsCapabilityAvailabilityAndPlaybackFailures() {
        let device = InputDevice.controller(UUID()), controller = GCController.withExtendedGamepad()
        let unsupported = NativeControllerFeedback(factory: { _ in nil })
        unsupported.setActive(true)
        #expect(unsupported.play(.impact, on: .keyboard) == .unsupported)
        #expect(unsupported.play(.impact, on: device) == .unavailable)
        unsupported.register(controller, device: device)
        #expect(unsupported.play(.impact, on: device) == .unsupported)
        let playback = Playback()
        let provider = NativeControllerFeedback(factory: { _ in playback })
        provider.register(controller, device: device)
        provider.setActive(true)
        #expect(provider.play(.selection, on: device) == .accepted)
        #expect(playback.plays == [.selection])
        playback.fails = true
        #expect(provider.play(.impact, on: device) == .failed)
        #expect(playback.stops == 2)
    }

    @Test func suspensionAndDisconnectionStopFeedbackAndRejectNewPlayback() {
        let device = InputDevice.controller(UUID()), playback = Playback()
        let provider = NativeControllerFeedback(factory: { _ in playback })
        provider.register(GCController.withExtendedGamepad(), device: device)
        provider.setActive(true)
        #expect(provider.play(.impact, on: device) == .accepted)
        provider.setActive(false)
        #expect(playback.stops == 1)
        #expect(provider.play(.impact, on: device) == .unavailable)
        provider.setActive(true)
        #expect(provider.play(.impact, on: device) == .accepted)
        provider.unregister(device)
        #expect(playback.stops == 2)
        #expect(provider.play(.impact, on: device) == .unavailable)
    }

    @Test func adapterSuspensionAndStopReachTheFeedbackProvider() throws {
        let hub = PlayerInputHub(), router = GameInputRouter(), playback = Playback()
        let provider = NativeControllerFeedback(factory: { _ in playback })
        let adapter = GameControllerInput(router: router, feedback: provider)
        router.configure(hub, feedback: provider)
        router.setActive(true)
        defer { adapter.stop(); router.detachBackend() }
        let controller = GCController.withExtendedGamepad()
        adapter.poll(controllers: [controller])
        let device = try #require(hub.devices.first { if case .controller = $0.id { true } else { false } })
        #expect(provider.play(.success, on: device.id) == .accepted)
        adapter.suspend()
        #expect(playback.stops == 1)
        #expect(provider.play(.success, on: device.id) == .unavailable)
        adapter.poll(controllers: [controller])
        #expect(provider.play(.success, on: device.id) == .accepted)
        adapter.stop()
        #expect(playback.stops == 2)
        #expect(provider.play(.success, on: device.id) == .unavailable)
    }

    @Test func adapterStopKeepsItsOriginalHubAndLeavesReplacementFeedbackActive() throws {
        let original = PlayerInputHub(), replacement = PlayerInputHub(), router = GameInputRouter()
        let playback = Playback(), provider = NativeControllerFeedback(factory: { _ in playback })
        let adapter = GameControllerInput(router: router, feedback: provider)
        router.configure(original, feedback: provider)
        router.setActive(true)
        adapter.poll(controllers: [GCController.withExtendedGamepad(), GCController.withExtendedGamepad()])
        let originalDevices = original.devices.filter { if case .controller = $0.id { true } else { false } }
        let fresh = GCController.withExtendedGamepad()
        var changed = false
        var replacementDevice: InputDevice?
        let token = original.observe { event in
            if case .disconnected = event, !changed {
                changed = true
                router.configure(replacement, feedback: provider)
                router.setActive(true)
                adapter.poll(controllers: [fresh])
                replacementDevice = replacement.devices.first { if case .controller = $0.id { true } else { false } }?.id
                if let replacementDevice { #expect(provider.play(.impact, on: replacementDevice) == .accepted) }
            }
        }
        defer { token.cancel(); adapter.stop(); router.detachBackend() }
        adapter.stop()
        let device = try #require(replacementDevice)
        #expect(original.devices.count == 2)
        #expect(router.hub === replacement && router.hasBackendLease && router.isActive)
        #expect(replacement.devices.contains { $0.id == device })
        #expect(playback.stops == 0)
        #expect(provider.play(.success, on: device) == .accepted)
        for old in originalDevices { #expect(provider.play(.impact, on: old.id) == .unavailable) }
    }

    @Test func sessionStopPreservesAReplacementStartedByCancellationCallback() throws {
        let original = PlayerInputHub(), replacement = PlayerInputHub()
        let playback = Playback(), provider = NativeControllerFeedback(factory: { _ in playback })
        let session = GameInputSession(feedback: provider)
        session.configure(nil, hub: original)
        session.availability = .init(visible: true, focused: true, sceneActive: true,
                                     scopeActive: true, windowActive: true)
        session.refresh()
        session.controllers.poll(controllers: [GCController.withExtendedGamepad(), GCController.withExtendedGamepad()])
        let fire = InputAction("fire")
        let player = original.addPlayer(named: "Original", contexts: [.init(name: "play", bindings: [.init(fire, control: .key("space"))])])
        try original.assign(.keyboard, to: player)
        session.router.key("space", pressed: true)
        let fresh = GCController.withExtendedGamepad()
        var replacementDevice: InputDevice?
        let token = player.input.observe { event in
            if event.phase == .cancelled {
                session.configure(nil, hub: replacement)
                session.availability.visible = true
                session.start()
                session.controllers.poll(controllers: [fresh])
                replacementDevice = replacement.devices.first { if case .controller = $0.id { true } else { false } }?.id
                if let replacementDevice { #expect(provider.play(.impact, on: replacementDevice) == .accepted) }
            }
        }
        defer { token.cancel(); session.stop() }
        session.stop()
        let device = try #require(replacementDevice)
        #expect(original.devices.count == 2)
        #expect(session.router.hub === replacement && session.router.hasBackendLease && session.router.isActive)
        #expect(session.availability.visible)
        #expect(replacement.devices.contains { $0.id == device })
        #expect(playback.stops == 0)
        #expect(provider.play(.success, on: device) == .accepted)
    }

    @Test func sessionConfigureKeepsTheNewerReplacementFromADisconnectCallback() throws {
        let original = PlayerInputHub(), superseded = PlayerInputHub(), replacement = PlayerInputHub()
        let playback = Playback(), provider = NativeControllerFeedback(factory: { _ in playback })
        let session = GameInputSession(feedback: provider)
        session.configure(nil, hub: original)
        session.availability = .init(visible: true, focused: true, sceneActive: true,
                                     scopeActive: true, windowActive: true)
        session.refresh()
        session.controllers.poll(controllers: [GCController.withExtendedGamepad(), GCController.withExtendedGamepad()])
        let fresh = GCController.withExtendedGamepad()
        var changed = false
        var replacementDevice: InputDevice?
        let token = original.observe { event in
            if case .disconnected = event, !changed {
                changed = true
                session.configure(nil, hub: replacement)
                session.start()
                session.controllers.poll(controllers: [fresh])
                replacementDevice = replacement.devices.first { if case .controller = $0.id { true } else { false } }?.id
                if let replacementDevice { #expect(provider.play(.impact, on: replacementDevice) == .accepted) }
            }
        }
        defer { token.cancel(); session.stop() }
        session.configure(nil, hub: superseded)
        let device = try #require(replacementDevice)
        #expect(original.devices.count == 2)
        #expect(session.router.hub === replacement && session.router.hasBackendLease && session.router.isActive)
        #expect(replacement.devices.contains { $0.id == device })
        #expect(playback.stops == 0)
        #expect(provider.play(.success, on: device) == .accepted)
    }

    @Test func firstPressFeedbackUsesItsControllerAndStopsOnOwnershipAndEnableChanges() throws {
        let hub = PlayerInputHub(), router = GameInputRouter(), playback = Playback()
        let provider = NativeControllerFeedback(factory: { _ in playback })
        let adapter = GameControllerInput(router: router, feedback: provider)
        router.configure(hub, feedback: provider)
        router.setActive(true)
        defer { adapter.stop(); router.detachBackend() }
        adapter.poll(controllers: [GCController.withExtendedGamepad()])
        var info = try #require(hub.devices.first { if case .controller = $0.id { true } else { false } })
        info.supportsHaptics = true // Injectable playback supplies synthetic hardware capability.
        hub.connect(info)
        guard case .controller(let id) = info.id else { Issue.record("Expected controller"); return }
        let action = InputAction("fire"), control = InputControl.gamepadButton(.south)
        let player = hub.addPlayer(named: "Player", contexts: [.init(name: "play", bindings: [.init(action, control: control)])])
        try hub.assign(info.id, to: player)
        var result: InputFeedbackResult?
        let token = player.input.observe { event in
            if event.phase == .pressed { result = player.playFeedback(.impact) }
        }
        adapter.route([(control, .button(false))], id: id)
        adapter.route([(control, .button(true))], id: id)
        #expect(result == .accepted && playback.plays.count == 1)
        hub.unassign(info.id)
        #expect(playback.stops == 1)
        try hub.assign(info.id, to: player)
        adapter.route([(control, .button(false))], id: id)
        adapter.route([(control, .button(true))], id: id)
        player.isEnabled = false
        #expect(playback.stops == 2)
        token.cancel()
    }

    @Test func hostCancellationStopsFeedbackBeforePlayerCancellationCallbacks() throws {
        let playback = Playback(), hub = PlayerInputHub(), host = GameHost()
        let provider = NativeControllerFeedback(factory: { _ in playback })
        let session = GameInputSession(feedback: provider)
        session.configure(nil, hub: hub)
        session.availability = .init(visible: true, focused: true, sceneActive: true,
                                     scopeActive: true, windowActive: true)
        session.refresh()
        session.bind([.init(id: host.inputHostID, host: host)])
        defer { session.stop() }
        session.controllers.poll(controllers: [GCController.withExtendedGamepad()])
        var info = try #require(hub.devices.first { if case .controller = $0.id { true } else { false } })
        info.supportsHaptics = true
        hub.connect(info)
        let action = InputAction("fire"), control = InputControl.key("space")
        let player = hub.addPlayer(named: "Player", contexts: [.init(name: "play", bindings: [.init(action, control: control)])])
        try hub.assign(.keyboard, to: player)
        try hub.assign(info.id, to: player)
        session.router.key("space", pressed: true)
        #expect(player.playFeedback(.impact, on: info.id) == .accepted)
        var reentrantResult: InputFeedbackResult?
        let token = player.input.observe { event in
            if event.phase == .cancelled { reentrantResult = player.playFeedback(.impact, on: info.id) }
        }
        host.cancelInputs()
        #expect(playback.stops == 1)
        #expect(reentrantResult == .unavailable)
        #expect(hub.owner(of: info.id) === player)
        token.cancel()
    }
}
