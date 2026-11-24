import Foundation
@_spi(Backend) @testable import ECSCore
import Testing

@MainActor @Suite struct InputReentrancyRegressionTests {
    private let fire = InputAction("fire")
    private let move = InputAction("move", kind: .axis2D)
    private let fold = InputAction("fold", kind: .axis)

    private var map: InputActionMap {
        .init(name: "play", bindings: [
            .init(fire, control: .key("space")),
            .init(move, control: .key("w"), scale: [0, 1]),
            .init(fold, control: .hinge)
        ])
    }

    @Test func releaseCancellationByObserverBeforeBufferDiscardsTheInFlightRelease() {
        let input = InputController(contexts: [map])
        let token = input.observe(action: fire) { event in
            if event.phase == .released { input.cancelAll() }
        }
        defer { token.cancel() }
        let buffer = FixedInputBuffer(input: input, capacity: 1)

        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        input.setValue(.button(false), for: .key("space"), device: .keyboard)

        let sample = buffer.consume()
        #expect(sample.events.isEmpty)
        #expect(!sample.wasPressed(fire) && !sample.wasReleased(fire))
        #expect(sample.value(for: fire) == .button(false))
        #expect(!sample.didOverflow)
        #expect(buffer.consume().events.isEmpty)

        input.setValue(.button(false), for: .key("space"), device: .keyboard)
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        #expect(buffer.consume().wasPressed(fire))
    }

    @Test func coordinateCancellationByObserverBeforeBufferDiscardsHingeEdgeButPreservesHold() {
        let input = InputController(contexts: [map])
        let token = input.observe(action: fold) { event in
            if event.phase == .pressed { input.cancelForCoordinateSpaceChange() }
        }
        defer { token.cancel() }
        var observed: [InputActionPhase] = []
        let later = input.observe(action: fold) { observed.append($0.phase) }
        defer { later.cancel() }
        let buffer = FixedInputBuffer(input: input)

        input.setValue(.axis(0.5), for: .hinge, device: .hinge)

        let sample = buffer.consume()
        #expect(sample.events.isEmpty)
        #expect(sample.value(for: fold) == .axis(0.5))
        #expect(observed == [.pressed])
        #expect(buffer.consume().events.isEmpty)

        input.setValue(.axis(0.75), for: .hinge, device: .hinge)
        let changed = buffer.consume()
        #expect(changed.events.map(\.phase) == [.changed])
        #expect(changed.value(for: fold) == .axis(0.75))
        #expect(sample.value(for: fold) == .axis(0.5))
    }

    @Test func unrelatedDeviceCancellationPreservesObserverDeliveryButDiscardsBufferedEdge() {
        let input = InputController(contexts: [map])
        let token = input.observe(action: fire) { event in
            if event.phase == .pressed { input.cancel(device: .pointer) }
        }
        defer { token.cancel() }
        var observed: [InputActionPhase] = []
        let later = input.observe(action: fire) { observed.append($0.phase) }
        defer { later.cancel() }
        let buffer = FixedInputBuffer(input: input)

        input.setValue(.button(true), for: .key("space"), device: .keyboard)

        let sample = buffer.consume()
        #expect(observed == [.pressed])
        #expect(input.value(for: fire) == .button(true))
        #expect(sample.value(for: fire) == .button(true))
        #expect(sample.events.isEmpty)

        input.setValue(.button(false), for: .key("space"), device: .keyboard)
        #expect(buffer.consume().events.map(\.phase) == [.released])
        #expect(observed == [.pressed, .released])
    }

    @Test func activeDeviceObserverPartialSubmissionPreservesUnrelatedPendingControl() throws {
        let hub = PlayerInputHub()
        let player = hub.addPlayer(named: "One", contexts: [map])
        try hub.assign(.keyboard, to: player)
        let buffer = FixedInputBuffer(input: player.input)
        let token = hub.observe { event in
            if case .activeDeviceChanged = event {
                hub.submit([(.key("w"), .button(true))], device: .keyboard)
            }
        }
        defer { token.cancel() }

        hub.submit([(.key("space"), .button(true))], device: .keyboard)

        let sample = buffer.consume()
        #expect(sample.value(for: fire) == .button(true))
        #expect(sample.value(for: move).vector == [0, 1])
        #expect(sample.events.filter { $0.action == fire }.map(\.phase) == [.pressed])
        #expect(sample.events.filter { $0.action == move }.map(\.phase) == [.pressed])
        #expect(buffer.consume().events.isEmpty)

        hub.submit([(.key("space"), .button(false))], device: .keyboard)
        let released = buffer.consume()
        #expect(released.events.map(\.action) == [fire])
        #expect(released.events.map(\.phase) == [.released])
        #expect(released.value(for: move).vector == [0, 1])
    }

    @Test func newerSameControlValueWinsWithoutDroppingOtherPendingControls() throws {
        let hub = PlayerInputHub()
        let player = hub.addPlayer(named: "One", contexts: [map])
        try hub.assign(.keyboard, to: player)
        let buffer = FixedInputBuffer(input: player.input)
        let token = hub.observe { event in
            if case .activeDeviceChanged = event {
                hub.submit([(.key("space"), .button(false))], device: .keyboard)
            }
        }
        defer { token.cancel() }

        hub.submit([(.key("space"), .button(true)), (.key("w"), .button(true))], device: .keyboard)

        let sample = buffer.consume()
        #expect(sample.value(for: fire) == .button(false))
        #expect(sample.events.filter { $0.action == fire }.isEmpty)
        #expect(sample.value(for: move).vector == [0, 1])
        #expect(sample.events.filter { $0.action == move }.map(\.phase) == [.pressed])
        #expect(buffer.consume().events.isEmpty)
    }

    @Test(arguments: [false, true])
    func reentrantCancellationInvalidatesAllPendingPartialControls(cancelHub: Bool) throws {
        let hub = PlayerInputHub()
        let player = hub.addPlayer(named: "One", contexts: [map])
        try hub.assign(.keyboard, to: player)
        let buffer = FixedInputBuffer(input: player.input)
        let token = hub.observe { event in
            if case .activeDeviceChanged = event {
                hub.submit([(.key("w"), .button(true))], device: .keyboard)
                if cancelHub { hub.cancelAll() } else { player.input.cancelAll() }
            }
        }

        hub.submit([(.key("space"), .button(true))], device: .keyboard)
        token.cancel()

        let cancelled = buffer.consume()
        #expect(!cancelled.wasPressed(fire) && !cancelled.wasPressed(move))
        #expect(cancelled.value(for: fire) == .button(false))
        #expect(cancelled.value(for: move).vector == .zero)
        hub.submit([(.key("space"), .button(true)), (.key("w"), .button(true))], device: .keyboard)
        let stillHeld = buffer.consume()
        #expect(stillHeld.events.isEmpty)
        #expect(stillHeld.value(for: fire) == .button(false))
        #expect(stillHeld.value(for: move).vector == .zero)

        hub.submit([(.key("space"), .button(false)), (.key("w"), .button(false))], device: .keyboard)
        hub.submit([(.key("space"), .button(true)), (.key("w"), .button(true))], device: .keyboard)
        let rearmed = buffer.consume()
        #expect(rearmed.wasPressed(fire) && rearmed.wasPressed(move))
    }

    @Test func reentrantOwnershipTransferDoesNotReplayPendingControlsToEitherPlayer() throws {
        let hub = PlayerInputHub()
        let first = hub.addPlayer(named: "First", contexts: [map])
        let second = hub.addPlayer(named: "Second", contexts: [map])
        try hub.assign(.keyboard, to: first)
        let firstBuffer = FixedInputBuffer(input: first.input)
        let secondBuffer = FixedInputBuffer(input: second.input)
        let token = hub.observe { event in
            if case .activeDeviceChanged(let player, let device) = event,
               player == first.id, device == .keyboard {
                hub.submit([(.key("w"), .button(true))], device: .keyboard)
                try? hub.assign(.keyboard, to: second)
            }
        }

        hub.submit([(.key("space"), .button(true))], device: .keyboard)
        token.cancel()

        #expect(hub.owner(of: .keyboard) === second)
        let oldOwner = firstBuffer.consume()
        #expect(!oldOwner.wasPressed(fire) && !oldOwner.wasPressed(move))
        #expect(oldOwner.value(for: fire) == .button(false))
        #expect(oldOwner.value(for: move).vector == .zero)
        hub.submit([(.key("space"), .button(true)), (.key("w"), .button(true))], device: .keyboard)
        let held = secondBuffer.consume()
        #expect(held.events.isEmpty)
        #expect(held.value(for: fire) == .button(false))
        #expect(held.value(for: move).vector == .zero)

        hub.submit([(.key("space"), .button(false)), (.key("w"), .button(false))], device: .keyboard)
        hub.submit([(.key("space"), .button(true)), (.key("w"), .button(true))], device: .keyboard)
        let rearmed = secondBuffer.consume()
        #expect(rearmed.wasPressed(fire) && rearmed.wasPressed(move))
        #expect(firstBuffer.consume().events.isEmpty)
    }
}
