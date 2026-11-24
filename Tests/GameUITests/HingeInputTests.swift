@_spi(Backend) import ECSCore
@_spi(Backend) @testable import SpriteBackend
@testable import GameUI
import Foundation
import SwiftUI
import Testing

@MainActor @Suite struct RuntimeHingeInputTests {
    private let fold = InputAction("fold", kind: .axis)
    private let fallback = InputAction("fallback", kind: .axis)
    private let key = InputAction("key")
    private let touch = InputAction("touch")
    private let pointer = InputAction("pointer")
    private var neutral: GameHingeState? { GameHingeState(angle: .pi, status: .fullyOpen) }
    private var held: GameHingeState? { GameHingeState(angle: .pi / 2, status: .partiallyOpen) }
    private var maps: [InputActionMap] {
        [.init(name: "play", bindings: [
            .init(fold, control: .hinge), .init(fallback, control: .hinge),
            .init(fallback, control: .key("space")), .init(fallback, control: .virtual("fallback")),
            .init(key, control: .key("k")), .init(touch, control: .virtual("touch")),
            .init(pointer, control: .pointerButton(0))
        ])]
    }

    private func fixture(smoothing: TimeInterval = 0) -> (InputController, GameInputRouter, GameHingeInput) {
        let input = InputController(contexts: maps), router = GameInputRouter()
        router.configure(input); router.setActive(true)
        let bridge = GameHingeInput(router: router)
        bridge.configure(.init(smoothing: smoothing))
        return (input, router, bridge)
    }

    private func session(_ host: GameHost, input: InputController) -> GameInputSession {
        let initialSample = host.hingeStore.state
        let session = GameInputSession()
        session.configure(input, hub: nil)
        session.hinge.configure(.init(smoothing: 0))
        session.availability = .init(visible: true, focused: true, sceneActive: true,
                                     scopeActive: true, windowActive: true)
        session.bind([.init(id: host.inputHostID, host: host)])
        // Headless hosts replay the current OS sample after routing activates.
        host.updateHingeState(initialSample)
        return session
    }

    @Test(arguments: [0.0, 0.08, 1_000.0])
    func initialHeldNeedsRawNeutralRegardlessOfSmoothing(smoothing: TimeInterval) {
        let (input, _, bridge) = fixture(smoothing: smoothing)
        defer { bridge.stop() }
        bridge.poll(held, at: 0)
        bridge.poll(held, at: 100)
        #expect(input.value(for: fold) == .axis(0))
        bridge.poll(neutral, at: 101)
        bridge.poll(held, at: 102)
        #expect(input.value(for: fold).scalar > 0)
        bridge.poll(neutral, at: 103)
        #expect(input.value(for: fold) == .axis(0))
        #expect(input.state(for: fold).phase == .released)
    }

    @Test func zeroSmoothingUsesMapperImmediatelyButStillHonorsCoreCancellationGate() {
        let (input, _, bridge) = fixture()
        defer { bridge.stop() }
        bridge.poll(neutral, at: 0)
        bridge.poll(held, at: 0)
        #expect(input.value(for: fold).scalar == HingeInputConfiguration(smoothing: 0).value(for: held))
        input.cancelAll()
        bridge.poll(held, at: 1)
        #expect(input.value(for: fold) == .axis(0))
        bridge.poll(neutral, at: 2)
        bridge.poll(held, at: 2)
        #expect(input.value(for: fold) == .axis(1))
    }

    @Test(arguments: [false, true])
    func unavailableOrUnknownReleasesOnlyHingeAndReconnectNeedsRawNeutral(unknown: Bool) {
        let (input, router, bridge) = fixture()
        defer { bridge.stop() }
        bridge.poll(neutral, at: 0); bridge.poll(held, at: 1)
        router.key("space", pressed: true)
        input.setValue(.axis(0.75), for: .virtual("fallback"), device: .virtual("hud"))
        bridge.poll(unknown ? GameHingeState(angle: .pi, status: .unknown) : nil, at: 2)
        #expect(input.state(for: fold).phase == .cancelled)
        #expect(input.value(for: fallback) == .axis(1))
        router.key("space", pressed: false)
        #expect(input.value(for: fallback) == .axis(0.75))
        bridge.poll(held, at: 3)
        #expect(input.value(for: fold) == .axis(0))
        bridge.poll(neutral, at: 4); bridge.poll(held, at: 5)
        #expect(input.value(for: fold) == .axis(1))
    }

    @Test func configurationChangeAndDisableRequireANewRawNeutral() {
        let (input, _, bridge) = fixture()
        defer { bridge.stop() }
        bridge.poll(neutral, at: 0); bridge.poll(held, at: 1)
        bridge.configure(.init(deadZone: 0.1, smoothing: 0))
        #expect(input.value(for: fold) == .axis(0))
        bridge.poll(held, at: 2)
        #expect(input.value(for: fold) == .axis(0))
        bridge.poll(neutral, at: 3); bridge.poll(held, at: 4)
        #expect(input.value(for: fold) == .axis(1))
        bridge.configure(nil)
        bridge.poll(neutral, at: 5); bridge.poll(held, at: 6)
        #expect(input.value(for: fold) == .axis(0))
        bridge.configure(.init(smoothing: 0))
        bridge.poll(held, at: 7)
        #expect(input.value(for: fold) == .axis(0))
        bridge.poll(neutral, at: 8); bridge.poll(held, at: 9)
        #expect(input.value(for: fold) == .axis(1))
    }

    @Test func smoothingIsIndependentOfTimeStepAndRepeatedTimeDoesNotAdvanceIt() {
        let (coarse, _, a) = fixture(smoothing: 0.5)
        let (fine, _, b) = fixture(smoothing: 0.5)
        defer { a.stop(); b.stop() }
        a.poll(neutral, at: 0); b.poll(neutral, at: 0)
        a.poll(held, at: 1)
        var previous: Float = 0
        for step in 1...10 {
            b.poll(held, at: Double(step) / 10)
            let value = fine.value(for: fold).scalar
            #expect(value.isFinite && value >= previous && value <= 1)
            previous = value
        }
        #expect(abs(coarse.value(for: fold).scalar - fine.value(for: fold).scalar) < 0.00001)
        #expect(abs(previous - Float(1 - exp(-2.0))) < 0.00001)
        b.poll(held, at: 1)
        #expect(fine.value(for: fold).scalar == previous)
        b.poll(neutral, at: 1)
        #expect(fine.value(for: fold) == .axis(0))
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity, -1.0])
    func invalidOrBackwardClockSuspendsAndRequiresNeutral(time: TimeInterval) {
        let (input, _, bridge) = fixture(smoothing: 0.5)
        defer { bridge.stop() }
        bridge.poll(neutral, at: 0); bridge.poll(held, at: 1)
        bridge.poll(held, at: time)
        #expect(input.value(for: fold) == .axis(0))
        bridge.poll(held, at: 2)
        #expect(input.value(for: fold) == .axis(0))
        bridge.poll(neutral, at: 3); bridge.poll(held, at: 4)
        #expect(input.value(for: fold).scalar.isFinite && input.value(for: fold).scalar > 0)
    }

    @Test func suspensionAndInactiveResumeCannotReuseEarlierNeutral() {
        let (input, router, bridge) = fixture()
        defer { bridge.stop() }
        bridge.poll(neutral, at: 0)
        router.setActive(false); bridge.poll(held, at: 1)
        router.setActive(true); bridge.poll(held, at: 2)
        #expect(input.value(for: fold) == .axis(0))
        bridge.poll(neutral, at: 3); bridge.poll(held, at: 4)
        bridge.suspend()
        #expect(input.state(for: fold).phase == .cancelled)
        bridge.poll(held, at: 5)
        #expect(input.value(for: fold) == .axis(0))
        bridge.poll(neutral, at: 6); bridge.poll(held, at: 7)
        #expect(input.value(for: fold) == .axis(1))
    }

    @Test func discoveryIsUnassignedAndReassignmentRequiresPhysicalNeutral() throws {
        let hub = PlayerInputHub(), router = GameInputRouter()
        router.configure(hub, feedback: NativeControllerFeedback()); router.setActive(true)
        let bridge = GameHingeInput(router: router)
        bridge.configure(.init(smoothing: 0))
        defer { bridge.stop(); router.detachBackend() }
        let first = hub.addPlayer(named: "First", contexts: maps)
        let second = hub.addPlayer(named: "Second", contexts: maps)
        bridge.poll(neutral, at: 0); bridge.poll(held, at: 1)
        #expect(hub.devices.contains { $0.id == .hinge })
        #expect(hub.owner(of: .hinge) == nil && first.prompt(for: fold) == nil)
        try hub.assign(.hinge, to: first)
        #expect(first.prompt(for: fold)?.label == "Fold")
        #expect(first.prompt(for: fold)?.symbolName == "rectangle.split.2x1")
        bridge.poll(held, at: 2)
        #expect(first.input.value(for: fold) == .axis(0))
        bridge.poll(neutral, at: 3); bridge.poll(held, at: 4)
        #expect(first.input.value(for: fold) == .axis(1))
        #expect(first.activeDevice?.id == .hinge)
        try hub.assign(.hinge, to: second)
        bridge.poll(held, at: 5)
        #expect(first.input.value(for: fold) == .axis(0))
        #expect(second.input.value(for: fold) == .axis(0))
        bridge.poll(neutral, at: 6); bridge.poll(held, at: 7)
        #expect(second.input.value(for: fold) == .axis(1))
        bridge.poll(nil, at: 8)
        #expect(hub.owner(of: .hinge) == nil && second.prompt(for: fold) == nil)
        #expect(!hub.devices.contains { $0.id == .hinge })
    }

    @Test func rejectedSecondBackendCannotDisconnectOrCancelFirstSensor() throws {
        let hub = PlayerInputHub(), first = GameInputRouter(), second = GameInputRouter()
        first.configure(hub, feedback: NativeControllerFeedback()); first.setActive(true)
        let a = GameHingeInput(router: first), b = GameHingeInput(router: second)
        a.configure(.init(smoothing: 0)); b.configure(.init(smoothing: 0))
        defer { b.stop(); a.stop(); second.detachBackend(); first.detachBackend() }
        a.poll(neutral, at: 0)
        let player = hub.addPlayer(named: "Player", contexts: maps)
        try hub.assign(.hinge, to: player)
        a.poll(neutral, at: 1); a.poll(held, at: 2)
        second.configure(hub, feedback: NativeControllerFeedback()); second.setActive(true)
        #expect(!second.hasBackendLease)
        b.poll(held, at: 3); b.poll(nil, at: 4); b.suspend(); b.stop()
        #expect(hub.owner(of: .hinge) === player)
        #expect(hub.devices.contains { $0.id == .hinge })
        #expect(player.input.value(for: fold) == .axis(1))
        #expect(first.hasBackendLease && first.isActive)
    }

    @Test func cancellationCallbackCanDisableBridgeWithoutResurrectingSamples() {
        let (input, _, bridge) = fixture()
        bridge.poll(neutral, at: 0); bridge.poll(held, at: 1)
        var callbacks = 0
        let token = input.observe(action: fold) { event in
            if event.phase == .cancelled { callbacks += 1; bridge.configure(nil) }
        }
        defer { token.cancel(); bridge.stop() }
        bridge.configure(.init(deadZone: 0.2, smoothing: 0))
        bridge.poll(neutral, at: 2); bridge.poll(held, at: 3)
        #expect(callbacks == 1 && bridge.configuration == nil)
        #expect(input.value(for: fold) == .axis(0))
    }

    @Test func discoveryCallbackChangingDestinationCannotRouteStaleSample() {
        let hub = PlayerInputHub(), router = GameInputRouter(), replacement = InputController(contexts: maps)
        router.configure(hub, feedback: NativeControllerFeedback()); router.setActive(true)
        let bridge = GameHingeInput(router: router)
        bridge.configure(.init(smoothing: 0))
        let token = hub.observe { event in
            if case .connected(let info) = event, info.id == .hinge {
                router.configure(replacement); router.setActive(true)
            }
        }
        defer { token.cancel(); bridge.stop(); router.detachBackend() }
        bridge.poll(neutral, at: 0)
        bridge.poll(held, at: 1)
        #expect(router.input === replacement)
        #expect(replacement.value(for: fold) == .axis(0))
        #expect(!hub.devices.contains { $0.id == .hinge })
        bridge.poll(neutral, at: 2); bridge.poll(held, at: 3)
        #expect(replacement.value(for: fold) == .axis(1))
    }

    @Test func stopDisconnectCallbackDefersReplacementSamplesUntilTeardownFinishes() throws {
        let hub = PlayerInputHub(), router = GameInputRouter(), replacement = InputController(contexts: maps)
        router.configure(hub, feedback: NativeControllerFeedback()); router.setActive(true)
        let bridge = GameHingeInput(router: router)
        bridge.configure(.init(smoothing: 0))
        bridge.poll(neutral, at: 0)
        let player = hub.addPlayer(named: "Old", contexts: maps)
        try hub.assign(.hinge, to: player)
        bridge.poll(neutral, at: 1); bridge.poll(held, at: 2)
        var replaced = false
        let token = hub.observe { event in
            if case .disconnected(let info) = event, info.id == .hinge, !replaced {
                replaced = true
                router.configure(replacement); router.setActive(true)
                bridge.poll(held, at: 3)
                #expect(replacement.value(for: fold) == .axis(0))
                bridge.poll(neutral, at: 4); bridge.poll(held, at: 5)
                #expect(replacement.value(for: fold) == .axis(0))
            }
        }
        defer { token.cancel(); bridge.stop(); router.detachBackend() }
        bridge.stop()
        #expect(replaced && router.input === replacement)
        #expect(player.input.value(for: fold) == .axis(0))
        #expect(replacement.value(for: fold) == .axis(0))
        // The neutral supplied during teardown must not arm the replacement.
        bridge.poll(held, at: 6)
        #expect(replacement.value(for: fold) == .axis(0))
        bridge.poll(neutral, at: 7); bridge.poll(held, at: 8)
        #expect(replacement.value(for: fold) == .axis(1))
    }

    @Test func sessionStopDisconnectObserverCannotReconnectHingeByRefreshing() throws {
        let host = GameHost(), hub = PlayerInputHub(), session = GameInputSession()
        session.configure(nil, hub: hub)
        session.hinge.configure(.init(smoothing: 0))
        session.availability = .init(visible: true, focused: true, sceneActive: true,
                                     scopeActive: true, windowActive: true)
        host.updateHingeState(neutral)
        session.bind([.init(id: host.inputHostID, host: host)])
        host.updateHingeState(neutral)
        let player = hub.addPlayer(named: "Player", contexts: maps)
        try hub.assign(.hinge, to: player)
        host.updateHingeState(neutral); host.updateHingeState(held)
        #expect(player.input.value(for: fold) == .axis(1))
        var disconnects = 0, reconnects = 0
        let token = hub.observe { event in
            switch event {
            case .disconnected(let info) where info.id == .hinge:
                disconnects += 1
                // Even a fresh sample during teardown must not reconnect the sensor.
                host.updateHingeState(self.neutral)
                session.refresh()
                #expect(!hub.devices.contains { $0.id == .hinge })
            case .connected(let info) where info.id == .hinge:
                reconnects += 1
            default: break
            }
        }
        defer { token.cancel(); session.stop() }
        session.stop()
        #expect(disconnects == 1 && reconnects == 0)
        #expect(!hub.devices.contains { $0.id == .hinge })
        #expect(hub.owner(of: .hinge) == nil && player.input.value(for: fold) == .axis(0))
        #expect(!session.router.hasBackendLease && !session.router.isActive)
        #expect(host.nativeInputSession == nil)
        session.refresh()
        #expect(!hub.devices.contains { $0.id == .hinge } && !session.router.hasBackendLease)
    }

    @Test func hostEventsPublishOptionalAndStatusChangesAndCoalesceReentrancy() {
        let host = GameHost(), content = host.content
        #expect(content.hingeState == nil && EnvironmentValues().gameHingeState == nil)
        var events: [GameHingeEvents.DidChange] = []
        let sameAngleNewStatus = GameHingeState(angle: .pi, status: .unknown)
        let token = host.world.subscribe(to: GameHingeEvents.DidChange.self) { event in
            #expect(event.scene === host.world)
            events.append(event)
            if events.count == 1 {
                host.updateHingeState(self.held)
                host.updateHingeState(sameAngleNewStatus)
            }
        }
        defer { token.cancel() }
        host.updateHingeState(neutral)
        #expect(events.count == 2)
        #expect(events.first?.previous == nil && events.first?.state == neutral)
        #expect(events.last?.previous == neutral && events.last?.state == sameAngleNewStatus)
        #expect(content.hingeState == sameAngleNewStatus)
        host.updateHingeState(sameAngleNewStatus)
        #expect(events.count == 2)
        host.updateHingeState(nil)
        #expect(events.count == 3 && events.last?.previous == sameAngleNewStatus)
        #expect(events.last?.state == nil && content.hingeState == nil)
    }

    @Test func hostInputCancellationCallbackSupersedesPendingRawEvent() {
        let host = GameHost(), input = InputController(contexts: maps)
        let session = session(host, input: input)
        defer { session.stop() }
        host.updateHingeState(neutral); host.updateHingeState(held)
        var events: [GameHingeEvents.DidChange] = []
        let eventToken = host.world.subscribe(to: GameHingeEvents.DidChange.self) { events.append($0) }
        let inputToken = input.observe(action: fold) { event in
            if event.phase == .cancelled { host.updateHingeState(self.neutral) }
        }
        defer { inputToken.cancel(); eventToken.cancel() }
        host.updateHingeState(nil)
        #expect(host.content.hingeState == neutral)
        #expect(events.count == 1 && events.first?.previous == held && events.first?.state == neutral)
        #expect(input.value(for: fold) == .axis(0))
        host.updateHingeState(held)
        #expect(input.value(for: fold) == .axis(1))
    }

    @Test func exactHostRebindingAndFocusResumeRequireNewNeutral() {
        let old = GameHost(), new = GameHost(), input = InputController(contexts: maps)
        old.updateHingeState(neutral); new.updateHingeState(held)
        let session = session(old, input: input)
        defer { session.stop() }
        old.updateHingeState(held)
        #expect(input.value(for: fold) == .axis(1))
        session.bind([.init(id: new.inputHostID, host: new)])
        #expect(old.nativeInputSession == nil && new.nativeInputSession === session)
        #expect(input.value(for: fold) == .axis(0))
        old.updateHingeState(neutral)
        session.refresh()
        #expect(input.value(for: fold) == .axis(0))
        new.updateHingeState(neutral); new.updateHingeState(held)
        #expect(input.value(for: fold) == .axis(1))
        session.availability.focused = false; session.refresh()
        session.availability.focused = true; session.refresh()
        #expect(input.value(for: fold) == .axis(0))
        new.updateHingeState(neutral); new.updateHingeState(held)
        #expect(input.value(for: fold) == .axis(1))
    }

    @Test func invalidatedCachedNeutralCannotArmOnResumeAndPreservesHubAssignment() throws {
        let host = GameHost(), hub = PlayerInputHub(), session = GameInputSession()
        session.configure(nil, hub: hub)
        session.hinge.configure(.init(smoothing: 0))
        session.availability = .init(visible: true, focused: true, sceneActive: true,
                                     scopeActive: true, windowActive: true)
        host.updateHingeState(neutral)
        session.bind([.init(id: host.inputHostID, host: host)])
        host.updateHingeState(neutral)
        defer { session.stop() }
        let player = hub.addPlayer(named: "Player", contexts: maps)
        try hub.assign(.hinge, to: player)
        host.updateHingeState(neutral)
        #expect(host.hingeStore.hasCurrentSample)
        host.invalidateHingeSample()
        #expect(!host.hingeStore.hasCurrentSample && host.content.hingeState == neutral)
        session.availability.focused = false; session.refresh()
        session.availability.focused = true; session.refresh(); session.refresh()
        #expect(hub.owner(of: .hinge) === player)
        #expect(hub.devices.contains { $0.id == .hinge })
        #expect(player.input.value(for: fold) == .axis(0))
        host.updateHingeState(held)
        #expect(host.hingeStore.hasCurrentSample)
        #expect(player.input.value(for: fold) == .axis(0))
        session.refresh()
        #expect(player.input.value(for: fold) == .axis(0))
        host.updateHingeState(neutral); host.updateHingeState(held)
        #expect(player.input.value(for: fold) == .axis(1))
    }

    @Test(arguments: [false, true])
    func focusOrScopeResumeDiscardsCachedNeutralUntilFreshPhysicalNeutral(scopeLoss: Bool) {
        let host = GameHost(), input = InputController(contexts: maps)
        host.updateHingeState(neutral)
        let session = session(host, input: input)
        defer { session.stop() }
        #expect(host.hingeStore.hasCurrentSample)
        if scopeLoss { session.availability.scopeActive = false }
        else { session.availability.focused = false }
        session.refresh()
        #expect(!session.router.isActive && !host.hingeStore.hasCurrentSample)
        #expect(host.content.hingeState == neutral)
        // A sample received while inactive must also be discarded on activation.
        host.updateHingeState(neutral)
        if scopeLoss { session.availability.scopeActive = true }
        else { session.availability.focused = true }
        session.refresh(); session.refresh()
        #expect(session.router.isActive && !host.hingeStore.hasCurrentSample)
        host.updateHingeState(held)
        session.refresh()
        #expect(input.value(for: fold) == .axis(0))
        host.updateHingeState(neutral); host.updateHingeState(held)
        #expect(input.value(for: fold) == .axis(1))
    }

    @Test func freshIdenticalNeutralAfterInvalidationArmsWithoutPublishingDuplicateEvent() {
        let host = GameHost(), input = InputController(contexts: maps)
        host.updateHingeState(neutral)
        let session = session(host, input: input)
        defer { session.stop() }
        var changes = 0
        let token = host.world.subscribe(to: GameHingeEvents.DidChange.self) { _ in changes += 1 }
        defer { token.cancel() }
        host.invalidateHingeSample()
        session.availability.focused = false; session.refresh()
        session.availability.focused = true; session.refresh()
        #expect(!host.hingeStore.hasCurrentSample)
        host.updateHingeState(neutral)
        #expect(host.hingeStore.hasCurrentSample && changes == 0)
        host.updateHingeState(held)
        #expect(input.value(for: fold) == .axis(1) && changes == 1)
    }

    @Test func coordinateSpaceChangesPreserveHingeButCancelOtherSourcesAndManualCancelRequiresNeutral() {
        let host = GameHost(), input = InputController(contexts: maps)
        host.updateSurfaceGeometry(.init(size: CGSize(width: 800, height: 600)))
        let session = session(host, input: input)
        defer { session.stop() }
        host.updateHingeState(neutral); host.updateHingeState(held)
        for change in 0..<3 {
            session.router.key("k", pressed: false)
            session.router.key("k", pressed: true)
            session.router.pointer(0, pressed: false)
            session.router.pointer(0, pressed: true)
            input.setValue(.button(false), for: .virtual("touch"), device: .virtual("hud"))
            input.setValue(.button(true), for: .virtual("touch"), device: .virtual("hud"))
            let id = host.beginInput(at: CGPoint(x: 50, y: 50))
            let contact = host.inputContacts[id]
            #expect(input.value(for: key).isPressed && input.value(for: touch).isPressed)
            #expect(input.value(for: pointer).isPressed)
            switch change {
            case 0: host.updateSurfaceGeometry(.init(size: CGSize(width: 900, height: 600)))
            case 1: host.updateSurfaceGeometry(.init(size: CGSize(width: 900, height: 600), reservedRegions: [
                .init(id: "fold", kind: .division, frame: CGRect(x: 440, y: 0, width: 20, height: 600))
            ]))
            default: host.configureViewports([.init(id: "game", region: .largestUsable)])
            }
            #expect(host.inputContacts.isEmpty && contact?.cancelled == true)
            #expect(input.state(for: key).phase == .cancelled)
            #expect(input.state(for: touch).phase == .cancelled)
            #expect(input.state(for: pointer).phase == .cancelled)
            #expect(input.value(for: fold) == .axis(1))
            session.refresh()
            #expect(input.value(for: fold) == .axis(1))
        }
        host.cancelInputs()
        #expect(input.state(for: fold).phase == .cancelled)
        session.refresh()
        #expect(input.value(for: fold) == .axis(0))
        host.updateHingeState(neutral); host.updateHingeState(held)
        #expect(input.value(for: fold) == .axis(1))
    }

    @Test func rawSamplesPreserveWorldCameraSurfaceAndPointerCapture() {
        let host = GameHost(), content = host.content
        let camera = Entity(components: CameraComponent())
        host.world.addEntity(camera)
        host.configureViewports([.init(id: "game", camera: camera.id, region: .largestUsable)])
        let geometry = GameSurfaceGeometry(size: CGSize(width: 800, height: 600), reservedRegions: [
            .init(id: "fold", kind: .division, frame: CGRect(x: 390, y: 0, width: 20, height: 600))
        ])
        host.updateSurfaceGeometry(geometry)
        let renderer = host.renderer, rect = renderer.viewportRect(id: "game"), position = camera.position
        let id = host.beginInput(at: CGPoint(x: 50, y: 50))
        var updates = 0, surfaces = 0
        let a = host.world.subscribe(to: WorldEvents.Update.self) { _ in updates += 1 }
        let b = host.world.subscribe(to: GameSurfaceEvents.DidChange.self) { _ in surfaces += 1 }
        defer { a.cancel(); b.cancel() }
        host.updateHingeState(neutral); host.updateHingeState(held); host.updateHingeState(nil)
        #expect(host.inputContacts[id]?.cancelled == false)
        #expect(content.surfaceGeometry == geometry && renderer.viewportRect(id: "game") == rect)
        #expect(host.renderer === renderer && host.world.entity(withID: camera.id) === camera)
        #expect(camera.position == position && updates == 0 && surfaces == 0)
    }

    @Test func publicModifiersAndDetachedNativeViewHaveNilFallback() throws {
        let configuration = HingeInputConfiguration(smoothing: 0)
        _ = Color.clear.gameInput(InputController(), hinge: configuration).onGameHingeChange { _ in }
        _ = Color.clear.gameInput(PlayerInputHub(), isActive: false, hinge: configuration)
            .onGameHingeChange { _ in }
        _ = Color.clear.gameInput(InputController(), hinge: nil)
        #expect(EnvironmentValues().gameHingeState == nil)
        let host = GameHost(), view = GameSKView()
        view.host = host
        view.startHingeObservation(); view.stopHingeObservation()
        #expect(host.content.hingeState == nil)
        // Decoded sensor payloads follow the same optional host path as native samples.
        let decoded = try JSONDecoder().decode(GameHingeState.self,
            from: Data(#"{"angle":3.141592653589793,"status":"fullyOpen"}"#.utf8))
        host.updateHingeState(decoded)
        #expect(host.content.hingeState == decoded)
        view.stopHingeObservation()
        #expect(host.content.hingeState == nil)
    }
}
