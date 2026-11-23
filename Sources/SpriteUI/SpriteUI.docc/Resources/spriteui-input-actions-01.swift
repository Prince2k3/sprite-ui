import SpriteUI
import SwiftUI
import Observation

// These helpers remain unchanged in all three stages.
enum InputDemoActions {
    static let move = InputAction("move", kind: .axis2D)
    static let fire = InputAction("fire")

    static let virtualMap = InputActionMap(name: "Play", bindings: [
        InputBinding(move, control: .virtual("left"), scale: [-1, 0]),
        InputBinding(move, control: .virtual("right"), scale: [1, 0]),
        InputBinding(move, control: .virtual("up"), scale: [0, 1]),
        InputBinding(move, control: .virtual("down"), scale: [0, -1]),
        InputBinding(fire, control: .virtual("fire"))
    ])

    static var hardwareMap: InputActionMap {
        var map = virtualMap
        map.bindings += [
            InputBinding(move, control: .key("a"), scale: [-1, 0]),
            InputBinding(move, control: .key("d"), scale: [1, 0]),
            InputBinding(move, control: .key("w"), scale: [0, 1]),
            InputBinding(move, control: .key("s"), scale: [0, -1]),
            InputBinding(move, control: .gamepadAxis(.leftStick), deadZone: 0.2),
            InputBinding(move, control: .gamepadAxis(.dpad)),
            InputBinding(fire, control: .key("space")),
            InputBinding(fire, control: .pointerButton(0)),
            InputBinding(fire, control: .gamepadButton(.south))
        ]
        return map
    }
}

@MainActor
struct InputDemoHoldStyle: ButtonStyle {
    let input: InputController
    let name: String

    private var device: InputDevice {
        .virtual(name == "fire" ? "screen-fire" : "screen-controls")
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(12)
            .background(configuration.isPressed ? Color.cyan : Color.gray.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onChange(of: configuration.isPressed) { _, pressed in
                input.setValue(.button(pressed), for: .virtual(name),
                               device: device)
            }
            .onDisappear {
                input.setValue(.button(false), for: .virtual(name),
                               device: device)
            }
    }
}

@MainActor
struct InputDemoControls: View {
    let input: InputController

    private func hold(_ title: String, _ name: String) -> some View {
        Button(title) {}.buttonStyle(InputDemoHoldStyle(input: input, name: name))
    }

    var body: some View {
        VStack {
            hold("Up", "up")
            HStack {
                hold("Left", "left")
                hold("Down", "down")
                hold("Right", "right")
            }
            hold("Fire", "fire")
        }
        .disabled(!input.isEnabled)
    }
}

@MainActor
struct InputDemoReadout: View {
    let input: InputController

    var body: some View {
        let move = input.value(for: InputDemoActions.move).vector
        let fire = input.state(for: InputDemoActions.fire)
        VStack {
            Text("Move: x \(move.x, specifier: "%.2f"), y \(move.y, specifier: "%.2f")")
            Text("Fire held: \(fire.isPressed ? "yes" : "no"); last: \(fire.phase.rawValue)")
        }
        .font(.caption.monospaced())
    }
}

@MainActor
@Observable
final class InputDemoScene {
    let input = InputController(contexts: [InputDemoActions.virtualMap])
}

@MainActor
struct ContentView: View {
    @State private var scene = InputDemoScene()

    var body: some View {
        VStack(spacing: 12) {
            InputDemoControls(input: scene.input)
            InputDemoReadout(input: scene.input)
        }
        .padding()
        .onDisappear { scene.input.cancelAll() }
    }
}
