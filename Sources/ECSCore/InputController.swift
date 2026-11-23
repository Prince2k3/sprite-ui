import Foundation
import Observation

/// Resolves device samples into observable game actions. This runtime object is
/// view/session scoped; save action maps, rather than held device state.
@MainActor @Observable
public final class InputController {
    public private(set) var contexts: [InputActionMap] = []
    /// Disabling cancels held actions. Re-enabling requires held controls to return
    /// to neutral before they can activate again.
    public var isEnabled = true {
        didSet { if oldValue != isEnabled { cancelAll() } }
    }
    private var states: [InputAction: InputActionState] = [:]
    @ObservationIgnored private var samples: [Source: InputValue] = [:]
    @ObservationIgnored private var blocked: [Source: [InputBinding]] = [:]
    @ObservationIgnored private var handlers: [Handler] = []
    @ObservationIgnored private var queuedEvents: [(event: InputActionEvent, revision: UInt64)] = []
    @ObservationIgnored private var revisions: [InputAction: UInt64] = [:]
    @ObservationIgnored private var isDelivering = false
    @ObservationIgnored var onCancellation: (@MainActor () -> Void)?
    @ObservationIgnored var onDeviceCancellation: (@MainActor (InputDevice) -> Void)?

    private struct Source: Hashable {
        let device: InputDevice
        let control: InputControl
        var sortKey: String { device.sortKey + String(describing: control) }
    }
    private struct Handler {
        weak var token: InputSubscription?
        let action: InputAction?
        let call: @MainActor (InputActionEvent) -> Void
    }

    public init(contexts: [InputActionMap] = []) { self.contexts = Self.normalized(contexts) }

    /// Replaces the context stack or its bindings, cancelling active actions and
    /// gating held controls. Assigning identical maps leaves input undisturbed.
    public func setContexts(_ maps: [InputActionMap]) {
        let maps = Self.normalized(maps)
        guard maps != contexts else { return }
        let events = cancelState()
        contexts = maps
        deliver(events)
    }

    /// Whether any installed context binds this control. Used by host adapters to
    /// leave unrelated shortcuts to their surrounding interface.
    public func handles(control: InputControl) -> Bool {
        contexts.contains { $0.bindings.contains { $0.control.canonical == control.canonical } }
    }

    /// Bindings currently able to contribute to this action, after context
    /// shadowing and consumption. Use these when presenting control prompts.
    public func bindings(for action: InputAction) -> [InputBinding] {
        effectiveBindings().filter { $0.action == action }
    }

    func hasEffectiveBinding(for control: InputControl) -> Bool {
        effectiveBindings().contains { $0.control == control.canonical }
    }

    /// Permanent device handoff removes both samples and their neutral gates.
    /// Cancellation alone deliberately retains those gates for focus recovery.
    func removeDevice(_ device: InputDevice) {
        samples = samples.filter { $0.key.device != device }
        blocked = blocked.filter { $0.key.device != device }
        resolve(cancelling: true)
    }

    /// Whether a device sample is inactive under the effective bindings for a
    /// control, including dead zones and button thresholds. Unbound controls
    /// are neutral only when their sample is zero.
    public func isNeutral(_ value: InputValue, for control: InputControl) -> Bool {
        neutral(sanitized(value), bindings: bindings(for: control.canonical))
    }

    /// Current state. Its phase describes the last transition, not the current frame.
    public func state(for action: InputAction) -> InputActionState {
        states[action] ?? .init(value: .zero(for: action.kind), phase: .idle)
    }
    public func value(for action: InputAction) -> InputValue { state(for: action).value }

    /// Supplies a sample. Identical values are ignored, including key repeats.
    public func setValue(_ value: InputValue, for control: InputControl, device: InputDevice) {
        setValues([(control, value)], device: device)
    }

    /// Applies a device snapshot atomically before resolving actions. Unlisted
    /// controls retain their values. Nonfinite input is treated as neutral.
    public func setValues(_ values: [(InputControl, InputValue)], device: InputDevice) {
        for (control, raw) in values {
            let source = Source(device: device, control: control.canonical)
            let value = sanitized(raw)
            if !value.isPressed {
                samples.removeValue(forKey: source)
                blocked.removeValue(forKey: source)
            } else {
                samples[source] = value
                if let previous = blocked[source], neutral(value, bindings: previous + bindings(for: source.control)) {
                    blocked.removeValue(forKey: source)
                }
                if !isEnabled { block(source) }
            }
        }
        resolve()
    }

    /// Cancels every active action. Held controls stay blocked until neutral.
    public func cancelAll() { deliver(cancelState()) }

    /// Cancels one producer, preserving other devices' contributions. A disconnected
    /// controller must send neutral before reusing its identity.
    public func cancel(device: InputDevice) {
        onDeviceCancellation?(device)
        for source in samples.keys where source.device == device { block(source) }
        resolve(cancelling: true)
    }

    /// Observes all actions, or one selected action. Retain the returned token.
    public func observe(action: InputAction? = nil, _ handler: @escaping @MainActor (InputActionEvent) -> Void) -> InputSubscription {
        let token = InputSubscription()
        handlers.append(.init(token: token, action: action, call: handler))
        return token
    }

    private func cancelState() -> [InputActionEvent] {
        onCancellation?()
        for source in samples.keys { block(source) }
        var events: [InputActionEvent] = []
        for action in ordered(states.keys) where states[action]!.isPressed {
            let value = InputValue.zero(for: action.kind)
            states[action] = .init(value: value, phase: .cancelled)
            revisions[action, default: 0] &+= 1
            events.append(.init(action: action, value: value, phase: .cancelled))
        }
        return events
    }

    private func resolve(cancelling: Bool = false) {
        var values: [InputAction: InputValue] = [:]
        if isEnabled {
            let available = effectiveBindings()
            let sources = samples.keys.sorted(by: { $0.sortKey < $1.sortKey })
            for action in ordered(Set(available.map(\.action))) {
                let bindings = available.filter { $0.action == action }
                var devices: [InputDevice: SIMD2<Float>] = [:]
                for binding in bindings {
                    for source in sources where source.control == binding.control && blocked[source] == nil {
                        let vector = processed(samples[source]!, deadZone: binding.deadZone) * binding.scale
                        if action.kind == .button {
                            if max(abs(vector.x), abs(vector.y)) >= action.pressThreshold { devices[source.device] = [1, 0] }
                        } else {
                            devices[source.device, default: .zero] += vector
                        }
                    }
                }
                // Each device is normalized independently. Exact ties use a stable
                // device order so dictionary iteration never changes a winning source.
                var best = SIMD2<Float>.zero
                for device in devices.keys.sorted(by: { $0.sortKey < $1.sortKey }) {
                    var vector = devices[device]!
                    if action.kind == .axis2D { vector = unitClamped(vector) }
                    else { vector = [min(max(vector.x, -1), 1), 0] }
                    if lengthSquared(vector) > lengthSquared(best) { best = vector }
                }
                switch action.kind {
                case .button: values[action] = .button(best.x != 0)
                case .axis: values[action] = .axis(best.x)
                case .axis2D: values[action] = .axis2D(best)
                }
            }
        }
        var events: [InputActionEvent] = []
        for action in ordered(Set(states.keys).union(values.keys)) {
            let old = state(for: action).value
            let value = values[action] ?? .zero(for: action.kind)
            guard value != old else { continue }
            let phase: InputActionPhase = !value.isPressed ? (cancelling ? .cancelled : .released) : (!old.isPressed ? .pressed : .changed)
            states[action] = .init(value: value, phase: phase)
            revisions[action, default: 0] &+= 1
            events.append(.init(action: action, value: value, phase: phase))
        }
        deliver(events)
    }

    private func deliver(_ events: [InputActionEvent]) {
        queuedEvents.append(contentsOf: events.map { ($0, revisions[$0.action, default: 0]) })
        guard !isDelivering else { return }
        isDelivering = true
        defer { isDelivering = false }
        while !queuedEvents.isEmpty {
            let queued = queuedEvents.removeFirst()
            let event = queued.event
            guard revisions[event.action] == queued.revision else { continue }
            handlers.removeAll { $0.token == nil || $0.token!.isCancelled }
            let current = handlers
            for handler in current where handler.token?.isCancelled == false && (handler.action == nil || handler.action == event.action) {
                guard revisions[event.action] == queued.revision else { break }
                handler.call(event)
            }
        }
    }

    private func block(_ source: Source) {
        if blocked[source] == nil { blocked[source] = bindings(for: source.control) }
    }
    private func bindings(for control: InputControl) -> [InputBinding] {
        effectiveBindings().filter { $0.control == control }
    }
    private func neutral(_ value: InputValue, bindings: [InputBinding]) -> Bool {
        guard !bindings.isEmpty else { return !value.isPressed }
        return bindings.allSatisfy { binding in
            let vector = processed(value, deadZone: binding.deadZone) * binding.scale
            switch binding.action.kind {
            case .button: return max(abs(vector.x), abs(vector.y)) < binding.action.pressThreshold
            case .axis: return vector.x == 0
            case .axis2D: return vector == .zero
            }
        }
    }

    private func effectiveBindings() -> [InputBinding] {
        var claimed: Set<InputAction> = []
        var consumed: Set<InputControl> = []
        var result: [InputBinding] = []
        for map in contexts.reversed() {
            result += map.bindings.filter { !consumed.contains($0.control) && !claimed.contains($0.action) }
            claimed.formUnion(map.bindings.map(\.action))
            if map.consumesInput { consumed.formUnion(map.bindings.map(\.control)) }
        }
        return result
    }

    private static func normalized(_ maps: [InputActionMap]) -> [InputActionMap] {
        maps.map { map in
            var map = map
            map.bindings = map.bindings.map { binding in
                var binding = binding
                binding.control = binding.control.canonical
                binding.deadZone = binding.deadZone.isFinite ? min(max(binding.deadZone, 0), 0.999) : 0
                binding.scale = SIMD2<Float>(
                    binding.scale.x.isFinite ? min(max(binding.scale.x, -1), 1) : 0,
                    binding.scale.y.isFinite ? min(max(binding.scale.y, -1), 1) : 0)
                return binding
            }
            return map
        }
    }

    private func ordered(_ actions: some Sequence<InputAction>) -> [InputAction] {
        actions.sorted { ($0.name, $0.kind.rawValue, $0.pressThreshold.bitPattern) < ($1.name, $1.kind.rawValue, $1.pressThreshold.bitPattern) }
    }
    private func sanitized(_ value: InputValue) -> InputValue {
        switch value {
        case .button: value
        case .axis(let x): .axis(x.isFinite ? min(max(x, -1), 1) : 0)
        case .axis2D(let vector): .axis2D(unitClamped(finite(vector)))
        }
    }
    private func finite(_ vector: SIMD2<Float>) -> SIMD2<Float> {
        [vector.x.isFinite ? vector.x : 0, vector.y.isFinite ? vector.y : 0]
    }
    private func lengthSquared(_ v: SIMD2<Float>) -> Float { v.x * v.x + v.y * v.y }
    private func unitClamped(_ vector: SIMD2<Float>) -> SIMD2<Float> {
        let vector = finite(vector)
        let factor = max(max(abs(vector.x), abs(vector.y)), 1)
        let scaled = vector / factor
        let length = sqrt(lengthSquared(scaled))
        return factor > 1 || length > 1 ? scaled / max(length, .leastNormalMagnitude) : vector
    }
    private func processed(_ raw: InputValue, deadZone: Float) -> SIMD2<Float> {
        let vector = raw.vector
        let length = sqrt(lengthSquared(vector))
        let zone = deadZone.isFinite ? min(max(deadZone, 0), 0.999) : 0
        guard length > zone else { return .zero }
        let adjusted = vector / max(length, .leastNormalMagnitude) * min((length - zone) / (1 - zone), 1)
        switch raw {
        case .button, .axis: return [adjusted.x, adjusted.x]
        case .axis2D: return adjusted
        }
    }
}
