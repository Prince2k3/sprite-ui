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
    var status = "Preparing fixed simulation"

    func install(in content: GameViewContent) {
        // Twenty ticks per second makes each canonical pose easy to see.
        content.world.fixedStep = FixedStepConfiguration(stepsPerSecond: 20)
        let actor = Entity(name: "Fixed actor", components:
            SpriteComponent(color: .cyan, size: [32, 32]), DemoFixedStepMotion())
        actor.position = [-100, 0]
        content.add(actor)
        do {
            try content.world.systems.add(DemoFixedStepMotionSystem.self)
            status = "20 Hz simulation · no native physics or actions"
        } catch {
            status = "Could not schedule fixed motion: \(error)"
        }
    }
}

@MainActor
struct ContentView: View {
    @State private var scene = DemoFixedStepScene()

    var body: some View {
        VStack(spacing: 12) {
            Text("Fixed-step simulation · stage 1").font(.headline)
            GameView { scene.install(in: $0) }
                .frame(height: 240)
            Text(scene.status).font(.caption)
            Text("The cyan actor advances in fixed 0.05-second steps.")
                .font(.caption)
        }
        .padding()
    }
}
