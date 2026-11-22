import SpriteUI
import SwiftUI

/// Exercises scene controls, parent-relative dragging and independent input captures.
struct APIConsolidationDemoView: View {
    @State private var paused = false
    @State private var speed = 1.0

    var body: some View {
        VStack(spacing: 12) {
            Text("Drag either square. Each view owns its input.")
                .font(.caption).foregroundStyle(.secondary)
            APIPlaygroundPane(title: "Orange scene", color: .orange, paused: paused, speed: speed)
            APIPlaygroundPane(title: "Blue scene", color: .cyan, paused: paused, speed: speed)
            HStack {
                Toggle("Pause", isOn: $paused).toggleStyle(.button)
                Slider(value: $speed, in: 0...2)
                Text("\(speed, specifier: "%.1f")×").monospacedDigit().frame(width: 42)
            }
            Text("Rotation and the following dot use ordered systems. Pausing freezes simulation; dragging still edits the scene.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding().tint(.orange).background(Color.black).preferredColorScheme(.dark)
    }
}

private struct APIPlaygroundPane: View {
    let title: String
    let color: Color
    let paused: Bool
    let speed: Double
    @State private var model = APIPlaygroundScene()

    var body: some View {
        GameView { content in
            model.build(in: content, color: color)
        } update: { content in
            content.scene.isPaused = paused
            content.scene.timeScale = speed
        }
        .gesture(DragGesture(minimumDistance: 0).targetedToAnyEntity().onChanged { value in
            guard let parent = value.entity.parent,
                  let local = value.convertIfAvailable(value.location, to: parent) else { return }
            value.entity.position = local
            model.drags += 1
        })
        .overlay(alignment: .topLeading) {
            Text("\(title) · \(model.drags) moves").font(.caption.monospaced())
                .padding(8).allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.4)))
    }
}

private struct PlaygroundParent: Component {}
private struct PlaygroundFollower: Component { weak var target: Entity? }

private struct PlaygroundRotationSystem: System {
    init(world: World) {}
    mutating func update(context: UpdateContext) {
        for entity in context.entities(matching: EntityQuery(where: .has(PlaygroundParent.self))) {
            entity.rotation += Float(context.deltaTime) * 0.25
        }
    }
}

private struct PlaygroundPresentationSystem: System {
    static var phase: SystemPhase { .presentation }
    static var dependencies: [SystemDependency] { [.after(PlaygroundRotationSystem.self)] }
    init(world: World) {}
    mutating func update(context: UpdateContext) {
        for entity in context.entities(matching: EntityQuery(where: .has(PlaygroundFollower.self))) {
            if let target = entity.components[PlaygroundFollower.self]?.target {
                try? entity.setPosition(target.scenePosition + [0, -42], relativeTo: nil)
            }
        }
    }
}

@MainActor @Observable
private final class APIPlaygroundScene {
    var drags = 0
    func build(in content: GameViewContent, color: Color) {
        content.scene.physics.gravity = .zero
        // Install in reverse order to exercise dependency and phase scheduling.
        content.scene.addSystem(PlaygroundPresentationSystem.self)
        content.scene.addSystem(PlaygroundRotationSystem.self)
        let parent = Entity(name: "rotated parent", components: PlaygroundParent(), SpriteComponent(color: color.opacity(0.14), size: [190, 105]))
        parent.rotation = 0.45
        parent.scale = [1.1, 0.85]
        let square = Entity(name: "drag me", components: SpriteComponent(color: color, size: [42, 42]), InputTargetComponent())
        square.position = [30, 0]
        parent.addChild(square)
        content.add(parent)
        let dot = Entity(components: PlaygroundFollower(target: square), SpriteComponent(image: .disc(diameter: 16), size: [12, 12], tint: .white, tintAmount: 1))
        dot.position = square.scenePosition + [0, -42]
        content.add(dot)
        let camera = Entity(name: "camera", components: CameraComponent(smoothing: 0))
        content.add(camera)
        content.scene.activeCamera = camera
    }
}
