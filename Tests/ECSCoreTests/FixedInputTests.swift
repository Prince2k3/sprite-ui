import Foundation
@_spi(Backend) @testable import ECSCore
import Testing

@MainActor @Suite struct FixedInputTests {
    private let fire = InputAction("fire")
    private let throttle = InputAction("throttle", kind: .axis)
    private let move = InputAction("move", kind: .axis2D)

    private var map: InputActionMap {
        .init(name: "play", bindings: [
            .init(fire, control: .key("space")),
            .init(fire, control: .gamepadButton(.south)),
            .init(throttle, control: .virtual("throttle")),
            .init(move, control: .virtual("stick"))
        ])
    }

    private func setFire(_ pressed: Bool, input: InputController) {
        input.setValue(.button(pressed), for: .key("space"), device: .keyboard)
    }

    @Test func deferredPressAndReleaseArePreservedOnceInOrder() {
        let input = InputController(contexts: [map])
        let buffer = FixedInputBuffer(input: input)
        setFire(true, input: input)
        setFire(false, input: input)

        let sample = buffer.consume()
        #expect(sample.events.map(\.phase) == [.pressed, .released])
        #expect(sample.events.map(\.action) == [fire, fire])
        #expect(sample.events.map(\.value) == [.button(true), .button(false)])
        #expect(sample.wasPressed(fire) && sample.wasReleased(fire))
        #expect(sample.value(for: fire) == .button(false))
        #expect(!sample.didOverflow)
        for _ in 0..<3 {
            let catchUp = buffer.consume()
            #expect(catchUp.events.isEmpty)
            #expect(!catchUp.wasPressed(fire) && !catchUp.wasReleased(fire))
            #expect(catchUp.value(for: fire) == .button(false))
        }
        #expect(sample.wasPressed(fire) && sample.wasReleased(fire))
    }

    @Test func heldValuesPersistWithoutPollingPhasesOrRepeatingEdges() {
        let input = InputController(contexts: [map])
        let buffer = FixedInputBuffer(input: input)
        setFire(true, input: input)
        setFire(true, input: input)
        let pressed = buffer.consume()
        #expect(pressed.events.map(\.phase) == [.pressed])
        for _ in 0..<3 {
            let held = buffer.consume()
            #expect(held.value(for: fire) == .button(true))
            #expect(held.events.isEmpty)
            #expect(!held.wasPressed(fire) && !held.wasReleased(fire))
        }
        setFire(false, input: input)
        #expect(buffer.consume().events.map(\.phase) == [.released])
        #expect(pressed.value(for: fire) == .button(true))
    }

    @Test func creatingBufferDuringHoldDoesNotInventAPress() {
        let input = InputController(contexts: [map])
        setFire(true, input: input)
        let buffer = FixedInputBuffer(input: input)
        let sample = buffer.consume()
        #expect(sample.events.isEmpty)
        #expect(sample.value(for: fire) == .button(true))
    }

    @Test func latestAxisValuesAreAuthoritativeAndSamplesStayImmutable() {
        let input = InputController(contexts: [map])
        let buffer = FixedInputBuffer(input: input)
        let device = InputDevice.virtual("overlay")
        for value in [Float(0.25), 0.5, -1] {
            input.setValue(.axis(value), for: .virtual("throttle"), device: device)
        }
        input.setValue(.axis2D([1, 0]), for: .virtual("stick"), device: device)
        input.setValue(.axis2D([0, 1]), for: .virtual("stick"), device: device)
        let sample = buffer.consume()
        #expect(sample.events.map(\.phase) == [.pressed, .changed, .changed, .pressed, .changed])
        #expect(sample.value(for: throttle) == .axis(-1))
        #expect(sample.value(for: move) == .axis2D([0, 1]))
        let held = buffer.consume()
        #expect(held.events.isEmpty)
        #expect(held.value(for: throttle) == .axis(-1))
        #expect(held.value(for: move) == .axis2D([0, 1]))
        input.setValue(.axis(0), for: .virtual("throttle"), device: device)
        #expect(buffer.consume().value(for: throttle) == .axis(0))
        #expect(sample.value(for: throttle) == .axis(-1))
    }

    @Test func currentContextsIncludeShadowedAndNeutralActionsWithTypedZeroFallbacks() {
        let menu = InputAction("menu")
        let input = InputController(contexts: [map, .init(name: "menu", bindings: [
            .init(menu, control: .key("space"))
        ])])
        let buffer = FixedInputBuffer(input: input)
        setFire(true, input: input)
        let sample = buffer.consume()
        #expect(sample.events.map(\.action) == [menu])
        #expect(sample.value(for: menu) == .button(true))
        #expect(sample.value(for: fire) == .button(false))
        #expect(sample.value(for: throttle) == .axis(0))
        #expect(sample.value(for: move) == .axis2D(.zero))
        #expect(sample.value(for: InputAction("unknown")) == .button(false))
        #expect(sample.value(for: InputAction("unknown", kind: .axis)) == .axis(0))
        #expect(sample.value(for: InputAction("unknown", kind: .axis2D)) == .axis2D(.zero))
        input.setContexts([])
        let removed = buffer.consume()
        #expect(removed.value(for: menu) == .button(false))
        #expect(sample.value(for: menu) == .button(true))
    }

    @Test func overflowDropsOldestAndPreservesLatestResolvedValues() {
        let input = InputController(contexts: [map])
        let buffer = FixedInputBuffer(input: input, capacity: 2)
        input.setValue(.axis(0.5), for: .virtual("throttle"), device: .virtual("overlay"))
        setFire(true, input: input)
        setFire(false, input: input)
        setFire(true, input: input)
        let sample = buffer.consume()
        #expect(sample.events.map(\.phase) == [.released, .pressed])
        #expect(sample.didOverflow)
        #expect(sample.value(for: fire) == .button(true))
        #expect(sample.value(for: throttle) == .axis(0.5))
        let next = buffer.consume()
        #expect(next.events.isEmpty && !next.didOverflow)
        #expect(next.value(for: fire) == .button(true))
    }

    @Test(arguments: [Int.min, -1, 0, 1, 4096, 4097, Int.max])
    func capacityIsSanitizedAndQueueStaysBounded(capacity: Int) {
        let input = InputController(contexts: [map])
        let buffer = FixedInputBuffer(input: input, capacity: capacity)
        for index in 0..<4101 { setFire(index.isMultiple(of: 2), input: input) }
        let sample = buffer.consume()
        #expect(sample.events.count == min(max(capacity, 1), 4096))
        #expect(sample.didOverflow)
        #expect(sample.events.last?.phase == .pressed)
        #expect(sample.value(for: fire) == .button(true))
    }

    @Test func defaultCapacityIs256() {
        let input = InputController(contexts: [map])
        let buffer = FixedInputBuffer(input: input)
        for index in 0..<257 { setFire(index.isMultiple(of: 2), input: input) }
        let sample = buffer.consume()
        #expect(sample.events.count == 256)
        #expect(sample.didOverflow)
    }

    enum Cancellation: CaseIterable, Sendable {
        case all, contexts, device, coordinateSpace, disable, suppression, deviceRemoval

        @MainActor func apply(to input: InputController) {
            switch self {
            case .all: input.cancelAll()
            case .contexts: input.setContexts([])
            case .device: input.cancel(device: .keyboard)
            case .coordinateSpace: input.cancelForCoordinateSpaceChange()
            case .disable: input.isEnabled = false
            case .suppression: input.setInputSuppressed(true, owner: UUID())
            case .deviceRemoval: input.removeDevice(.keyboard)
            }
        }
    }

    @Test(arguments: Cancellation.allCases, [false, true])
    func cancellationClearsPendingEdgesEvenIfAlreadyReleased(cancellation: Cancellation, released: Bool) {
        let input = InputController(contexts: [map])
        let buffer = FixedInputBuffer(input: input)
        setFire(true, input: input)
        if released { setFire(false, input: input) }
        cancellation.apply(to: input)
        let sample = buffer.consume()
        #expect(!sample.wasPressed(fire) && !sample.wasReleased(fire))
        #expect(sample.events.map(\.phase) == (released ? [] : [.cancelled]))
        #expect(sample.value(for: fire) == .button(false))
        #expect(!sample.didOverflow)
        #expect(buffer.consume().events.isEmpty)
    }

    @Test func cancellationIsCheckedBeforeAppendingTheNextTransition() {
        let input = InputController(contexts: [map])
        let buffer = FixedInputBuffer(input: input)
        setFire(true, input: input)
        setFire(false, input: input)
        input.cancelAll()
        input.setValue(.axis(1), for: .virtual("throttle"), device: .virtual("overlay"))
        let sample = buffer.consume()
        #expect(sample.events.map(\.action) == [throttle])
        #expect(sample.wasPressed(throttle))
        #expect(!sample.wasPressed(fire) && !sample.wasReleased(fire))
    }

    @Test func cancellationClearsOverflowWithoutACancelledEvent() {
        let input = InputController(contexts: [map])
        let buffer = FixedInputBuffer(input: input, capacity: 1)
        setFire(true, input: input)
        setFire(false, input: input)
        input.cancelAll()
        let sample = buffer.consume()
        #expect(sample.events.isEmpty && !sample.didOverflow)
    }

    @Test func cancellationFromLaterObserverInvalidatesAnAlreadyBufferedPress() {
        let input = InputController(contexts: [map])
        let buffer = FixedInputBuffer(input: input)
        let token = input.observe { event in
            if event.phase == .pressed { input.cancelAll() }
        }
        setFire(true, input: input)
        let sample = buffer.consume()
        #expect(sample.events.map(\.phase) == [.cancelled])
        #expect(!sample.wasPressed(fire) && !sample.wasReleased(fire))
        #expect(sample.value(for: fire) == .button(false))
        token.cancel()
    }

    @Test func deviceCancellationPreservesOtherContributionsAndNeutralGates() {
        let input = InputController(contexts: [map])
        let buffer = FixedInputBuffer(input: input)
        let pad = InputDevice.controller(UUID())
        setFire(true, input: input)
        input.setValue(.button(true), for: .gamepadButton(.south), device: pad)
        input.cancel(device: .keyboard)
        let sample = buffer.consume()
        #expect(sample.events.isEmpty)
        #expect(sample.value(for: fire) == .button(true))
        input.setValue(.button(false), for: .gamepadButton(.south), device: pad)
        #expect(buffer.consume().events.map(\.phase) == [.released])
        setFire(true, input: input)
        #expect(buffer.consume().events.isEmpty)
        setFire(false, input: input)
        setFire(true, input: input)
        #expect(buffer.consume().wasPressed(fire))
    }

    @Test func coordinateCancellationPreservesHingeHeldValues() {
        let input = InputController(contexts: [.init(name: "hinge", bindings: [
            .init(throttle, control: .hinge)
        ])])
        let buffer = FixedInputBuffer(input: input)
        input.setValue(.axis(0.5), for: .hinge, device: .hinge)
        input.cancelForCoordinateSpaceChange()
        let sample = buffer.consume()
        #expect(sample.events.isEmpty)
        #expect(sample.value(for: throttle) == .axis(0.5))
    }

    @Test func independentBuffersDrainAtTheirOwnPace() {
        let input = InputController(contexts: [map])
        let first = FixedInputBuffer(input: input)
        let second = FixedInputBuffer(input: input)
        setFire(true, input: input)
        #expect(first.consume().events.map(\.phase) == [.pressed])
        #expect(first.consume().events.isEmpty)
        setFire(false, input: input)
        #expect(second.consume().events.map(\.phase) == [.pressed, .released])
        #expect(first.consume().events.map(\.phase) == [.released])
        #expect(first.consume().events.isEmpty && second.consume().events.isEmpty)
    }

    @Test func resetDiscardsEdgesAndOverflowWithoutCancellingHeldInput() {
        let input = InputController(contexts: [map])
        let buffer = FixedInputBuffer(input: input, capacity: 1)
        setFire(true, input: input)
        setFire(false, input: input)
        setFire(true, input: input)
        buffer.reset()
        let sample = buffer.consume()
        #expect(sample.events.isEmpty && !sample.didOverflow)
        #expect(sample.value(for: fire) == .button(true))
        #expect(input.state(for: fire).phase == .pressed)
        setFire(false, input: input)
        #expect(buffer.consume().events.map(\.phase) == [.released])
    }

    @Test func unchangedContextsDoNotDiscardPendingEdges() {
        let input = InputController(contexts: [map])
        let buffer = FixedInputBuffer(input: input)
        setFire(true, input: input)
        input.setContexts([map])
        #expect(buffer.consume().wasPressed(fire))
    }

    @Test func subscriptionDoesNotRetainTheBuffer() {
        let input = InputController(contexts: [map])
        var buffer: FixedInputBuffer? = FixedInputBuffer(input: input)
        weak var weakBuffer = buffer
        #expect(weakBuffer != nil)
        buffer = nil
        #expect(weakBuffer == nil)
        setFire(true, input: input)
        #expect(input.value(for: fire) == .button(true))
    }
}
