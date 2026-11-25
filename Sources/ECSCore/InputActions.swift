import Foundation

/// The shape of a game action's resolved value.
public enum InputActionKind: String, Codable, Hashable, Sendable {
    case button, axis, axis2D
}

/// A stable game-defined action, independent of its physical bindings.
public struct InputAction: Hashable, Codable, Sendable {
    public var name: String
    public var kind: InputActionKind
    /// The magnitude required to press a button action, normalized to 0.001...1.
    public let pressThreshold: Float

    public init(_ name: String, kind: InputActionKind = .button, pressThreshold: Float = 0.5) {
        self.name = name; self.kind = kind
        self.pressThreshold = pressThreshold.isFinite ? min(max(pressThreshold, 0.001), 1) : 0.5
    }
    private enum CodingKeys: String, CodingKey { case name, kind, pressThreshold }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try values.decode(String.self, forKey: .name),
                  kind: try values.decode(InputActionKind.self, forKey: .kind),
                  pressThreshold: try values.decodeIfPresent(Float.self, forKey: .pressThreshold) ?? 0.5)
    }
}

/// A button, signed scalar, or vector. Axis values use positive y upward.
public enum InputValue: Hashable, Codable, Sendable {
    case button(Bool)
    case axis(Float)
    case axis2D(SIMD2<Float>)

    /// A scalar projection; vectors use their x component.
    public var scalar: Float { vector.x }
    /// The value projected onto two axes; buttons and scalars use the x axis.
    public var vector: SIMD2<Float> {
        switch self {
        case .button(let pressed): [pressed ? 1 : 0, 0]
        case .axis(let value): [value, 0]
        case .axis2D(let value): value
        }
    }
    /// Whether this value is nonzero. Button thresholds are applied by the action map.
    public var isPressed: Bool { vector != .zero }

    static func zero(for kind: InputActionKind) -> Self {
        switch kind { case .button: .button(false); case .axis: .axis(0); case .axis2D: .axis2D(.zero) }
    }
}

/// Controller buttons use positional names, independent of vendor labels.
public enum GamepadButton: String, CaseIterable, Codable, Hashable, Sendable {
    case south, east, west, north, leftShoulder, rightShoulder, menu, options, leftStick, rightStick
}

/// Analog controller controls supported by the input adapter.
public enum GamepadAxis: String, CaseIterable, Codable, Hashable, Sendable {
    case leftStick, rightStick, dpad, leftTrigger, rightTrigger
}

/// A physical or application-provided control. Keys use lowercase characters or
/// `up`, `down`, `left`, `right`, `space`, `escape`, `return`, and `tab`.
public enum InputControl: Hashable, Codable, Sendable {
    case key(String)
    /// Zero is the primary mouse button; one is the secondary mouse button.
    case pointerButton(Int)
    case gamepadButton(GamepadButton)
    case gamepadAxis(GamepadAxis)
    case virtual(String)
    /// Normalized scalar input from supported physical hinge hardware.
    case hinge

    var canonical: Self {
        guard case .key(let key) = self else { return self }
        return .key(key == " " ? "space" : key.lowercased())
    }
}

/// An independent input producer. Give each on-screen control its own virtual device.
public enum InputDevice: Hashable, Codable, Sendable {
    case keyboard, pointer, controller(UUID), virtual(String)
    /// The device's physical hinge, when its sensor is supported by the OS and host.
    case hinge

    var sortKey: String {
        switch self {
        case .keyboard: "0"
        case .pointer: "1"
        case .controller(let id): "2" + id.uuidString
        case .virtual(let name): "3" + name
        case .hinge: "4"
        }
    }
}

/// Maps one control into an action. Digital axis directions use `scale`, such as
/// `[0, 1]` for up. Scale components are clamped to -1...1. Analog dead zones
/// are radial and rescaled to the full range.
public struct InputBinding: Hashable, Codable, Sendable {
    public var action: InputAction
    public var control: InputControl
    public var scale: SIMD2<Float>
    public var deadZone: Float

    public init(_ action: InputAction, control: InputControl, scale: SIMD2<Float> = [1, 1], deadZone: Float = 0) {
        self.action = action; self.control = control; self.scale = scale; self.deadZone = deadZone
    }
}

/// A named input context. Maps are installed bottom to top; upper maps shadow
/// actions with the same identity and can consume controls used by lower maps.
public struct InputActionMap: Hashable, Codable, Sendable {
    public var name: String
    public var bindings: [InputBinding]
    public var consumesInput: Bool

    public init(name: String, bindings: [InputBinding], consumesInput: Bool = true) {
        self.name = name; self.bindings = bindings; self.consumesInput = consumesInput
    }
}

/// A transition, rather than a frame flag. Held actions retain their current value;
/// repeated identical device samples do not produce additional pressed events.
public enum InputActionPhase: String, Codable, Hashable, Sendable {
    case idle, pressed, changed, released, cancelled
}

/// The latest resolved value and transition for one action.
public struct InputActionState: Hashable, Sendable {
    public let value: InputValue
    public let phase: InputActionPhase
    public var isPressed: Bool { value.isPressed }
}

/// A value transition delivered synchronously on the main actor.
public struct InputActionEvent: Hashable, Codable, Sendable {
    /// The game-defined action that changed.
    public let action: InputAction
    /// The action's resolved value at this transition.
    public let value: InputValue
    /// The original transition phase, including cancellation.
    public let phase: InputActionPhase

    /// Creates a transition without changing its phase or resolved value.
    public init(action: InputAction, value: InputValue, phase: InputActionPhase) {
        self.action = action
        self.value = value
        self.phase = phase
    }
}

/// Retain this token to receive action changes; cancellation or deallocation ends delivery.
@MainActor
public final class InputSubscription {
    var isCancelled = false
    public func cancel() { isCancelled = true }
}
