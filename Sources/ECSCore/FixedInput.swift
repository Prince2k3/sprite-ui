import Foundation

/// An immutable snapshot for one caller-driven simulation step. Transitions are
/// delivered once; held values remain available in subsequent samples.
public struct FixedInputSample: Codable, Equatable, Sendable {
    /// Ordered transitions, including cancellations and repeated actions.
    public let events: [InputActionEvent]
    /// Whether the source buffer dropped any transitions before this sample.
    public let didOverflow: Bool
    /// Resolved held values, copied independently of subsequent input changes.
    public let values: [InputAction: InputValue]

    /// Creates a sample without normalization. Decoding and recording validate
    /// action kinds and finite normalized values; recording also rejects overflow.
    public init(values: [InputAction: InputValue] = [:], events: [InputActionEvent] = [], didOverflow: Bool = false) {
        self.events = events
        self.didOverflow = didOverflow
        self.values = values
    }

    private enum CodingKeys: String, CodingKey { case values, events, didOverflow }
    private struct Entry: Codable {
        let action: InputAction
        let value: InputValue
    }

    /// Decodes unique action entries and validates held and transition values.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try container.decode([Entry].self, forKey: .values)
        var values: [InputAction: InputValue] = [:]
        for entry in entries {
            guard values.updateValue(entry.value, forKey: entry.action) == nil else {
                throw InputRecordingError.invalidFrame
            }
        }
        self.init(values: values,
                  events: try container.decode([InputActionEvent].self, forKey: .events),
                  didOverflow: try container.decode(Bool.self, forKey: .didOverflow))
        try validate()
    }

    /// Encodes held values as a sorted array, preserving transition order.
    public func encode(to encoder: any Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        let entries = values.map { Entry(action: $0.key, value: $0.value) }.sorted {
            if $0.action.name != $1.action.name { return $0.action.name < $1.action.name }
            if $0.action.kind != $1.action.kind { return $0.action.kind.rawValue < $1.action.kind.rawValue }
            return $0.action.pressThreshold < $1.action.pressThreshold
        }
        try container.encode(entries, forKey: .values)
        try container.encode(events, forKey: .events)
        try container.encode(didOverflow, forKey: .didOverflow)
    }

    func validate() throws {
        for (action, value) in values { try Self.validate(value, for: action) }
        for event in events { try Self.validate(event.value, for: event.action) }
    }

    private static func validate(_ value: InputValue, for action: InputAction) throws {
        let valid: Bool
        switch (action.kind, value) {
        case (.button, .button): valid = true
        case (.axis, .axis(let scalar)):
            valid = scalar.isFinite && (-1...1).contains(scalar)
        case (.axis2D, .axis2D(let vector)):
            // Normalizing a Float vector can round its squared length just above one.
            valid = vector.x.isFinite && vector.y.isFinite
                && (-1...1).contains(vector.x) && (-1...1).contains(vector.y)
                && vector.x * vector.x + vector.y * vector.y <= 1 + 4 * Float.ulpOfOne
        default: valid = false
        }
        guard valid else { throw InputRecordingError.invalidFrame }
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
        let sample = FixedInputSample(values: values, events: events, didOverflow: didOverflow)
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
        guard input.currentDispatchCancellationRevision == cancellationRevision else { return }
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
