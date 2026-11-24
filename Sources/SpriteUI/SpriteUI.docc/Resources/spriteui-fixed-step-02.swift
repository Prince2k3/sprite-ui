import Observation
import SpriteUI
import SwiftUI

// Replace ContentView.swift with this entire file; keep the app entry point.
struct DemoFixedStepMotion: Component {
    var speed: Float = 100
}

@MainActor
struct DemoFixedStepMotionSystem: System {
    static var phase: SystemPhase { .fixedSimulation }
    private let query = EntityQuery(where: .has(DemoFixedStepMotion.self))

    init(world: World) {}

    func update(context: UpdateContext) {
        for entity in context.entities(matching: query) {
            guard var motion = entity.components[DemoFixedStepMotion.self] else { continue }
            entity.position.x += motion.speed * Float(context.deltaTime)
            if entity.position.x > 100 {
                entity.position.x = 200 - entity.position.x
                motion.speed = -abs(motion.speed)
            } else if entity.position.x < -100 {
                entity.position.x = -200 - entity.position.x
                motion.speed = abs(motion.speed)
            }
            entity.components.set(motion)
        }
    }
}

@MainActor @Observable
final class DemoFixedStepScene {
    var status = "Preparing comparison"

    func install(in content: GameViewContent) {
        content.world.fixedStep = FixedStepConfiguration(stepsPerSecond: 20)
        let raw = Entity(name: "Canonical actor", components:
            SpriteComponent(color: .orange, size: [32, 32]), DemoFixedStepMotion())
        raw.position = [-100, 46]
        let smooth = Entity(name: "Interpolated actor", components:
            SpriteComponent(color: .cyan, size: [32, 32]), DemoFixedStepMotion(),
            TransformInterpolationComponent(isEnabled: true))
        smooth.position = [-100, -46]
        content.add(raw)
        content.add(smooth)
        do {
            try content.world.systems.add(DemoFixedStepMotionSystem.self)
            status = "Both models run at 20 Hz · cyan presentation trails one tick"
        } catch {
            status = "Could not schedule fixed motion: \(error)"
        }
    }
}

@MainActor
struct ContentView: View {
    @State private var scene = DemoFixedStepScene()
    @State private var fps = 60

    var body: some View {
        VStack(spacing: 12) {
            Text("Fixed-step interpolation · stage 2").font(.headline)
            Picker("Preferred FPS", selection: $fps) {
                Text("30").tag(30)
                Text("60").tag(60)
                Text("120").tag(120)
            }.pickerStyle(.segmented)
            GameView(rendering: GameRenderConfiguration(preferredFramesPerSecond: fps)) {
                scene.install(in: $0)
            }
            .frame(height: 240)
            Text("Orange: canonical steps · Cyan: interpolated display")
                .font(.caption)
            Text(scene.status).font(.caption)
            Text("Preferred FPS changes rendering cadence; fixed frequency stays 20 Hz.")
                .font(.caption)
        }
        .padding()
    }
}
