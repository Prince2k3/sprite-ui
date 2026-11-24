/// An immutable snapshot for one caller-driven simulation step. Transitions are
/// delivered once; held values remain available in subsequent samples.
public struct FixedInputSample: Sendable {
    public let events: [InputActionEvent]
    public let didOverflow: Bool
    private let values: [InputAction: InputValue]

    fileprivate init(events: [InputActionEvent], didOverflow: Bool, values: [InputAction: InputValue]) {
        self.events = events
        self.didOverflow = didOverflow
        self.values = values
    }

    /// The controller's resolved value when consumed, or a kind-appropriate zero
    /// for actions outside the current context stack.
    public func value(for action: InputAction) -> InputValue {
        values[action] ?? .zero(for: action.kind)
    }

    /// Whether a press transition survived in this sample's event queue.
    public func wasPressed(_ action: InputAction) -> Bool {
        events.contains { $0.action == action && $0.phase == .pressed }
    }

    /// Whether a release transition survived in this sample's event queue.
    /// Cancellation does not count as a release.
    public func wasReleased(_ action: InputAction) -> Bool {
        events.contains { $0.action == action && $0.phase == .released }
    }
}

/// Buffers resolved input transitions until the caller consumes a simulation
/// step. Call `consume()` once per step: a brief press and release between steps
/// are both preserved, while catch-up steps receive no repeated transitions.
/// This buffer does not drive a world or own a clock.
///
/// On world pause, the caller must call `input.cancelAll()` or `buffer.reset()`
/// to discard pending transitions. Native focus loss already cancels input.
/// Controller cancellation clears pending transitions globally, including device
/// and coordinate-space cancellation; other devices' resolved held values remain
/// authoritative. Overflow drops the oldest event and flags the next sample.
@MainActor
public final class FixedInputBuffer {
    private let input: InputController
    private let capacity: Int
    private var subscription: InputSubscription?
    private var cancellationRevision: UInt64
    private var events: [InputActionEvent] = []
    private var didOverflow = false

    /// Capacity is clamped to 1...4096 events. Each buffer drains independently.
    public init(input: InputController, capacity: Int = 256) {
        self.input = input
        self.capacity = min(max(capacity, 1), 4096)
        self.cancellationRevision = input.cancellationRevision
        self.subscription = input.observe { [weak self] event in
            self?.append(event)
        }
    }

    /// Drains queued transitions once and snapshots all actions bound by the
    /// controller's current contexts, including neutral and shadowed actions.
    /// Values always come from the controller, even when events overflowed.
    public func consume() -> FixedInputSample {
        discardCancelledEvents()
        let actions = Set(input.contexts.flatMap { $0.bindings.map(\.action) })
        let values = Dictionary(uniqueKeysWithValues: actions.map { ($0, input.value(for: $0)) })
        let sample = FixedInputSample(events: events, didOverflow: didOverflow, values: values)
        reset()
        return sample
    }

    /// Discards pending transitions and the overflow flag without cancelling
    /// input or changing held values and neutral gates.
    public func reset() {
        events.removeAll(keepingCapacity: true)
        didOverflow = false
        cancellationRevision = input.cancellationRevision
    }

    private func append(_ event: InputActionEvent) {
        discardCancelledEvents()
        if events.count == capacity {
            events.removeFirst()
            didOverflow = true
        }
        events.append(event)
    }

    private func discardCancelledEvents() {
        if cancellationRevision != input.cancellationRevision { reset() }
    }
}
