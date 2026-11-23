import SpriteUI
import SwiftUI
import Observation

struct SteeringMotion: Component {
    var agent = Agent2D(position: [-100, -60], maxSpeed: 70, maxForce: 420, radius: 14)
    var target: SIMD2<Float> = [100, 60]
    var lastError: String?
}

@MainActor
struct SteeringMovementSystem: System {
    private let query = EntityQuery(where: .has(SteeringMotion.self))

    init(world: World) {}

    func update(context: UpdateContext) {
        let dt = Float(context.deltaTime)
        guard dt > 0 else { return }
        for entity in context.entities(matching: query) {
            guard var motion = entity.components[SteeringMotion.self] else { continue }
            let start = entity.scenePosition
            motion.agent.position = start
            let force = AgentGoal.arrive(motion.agent, at: motion.target, slowingRadius: 45)
            motion.agent.apply(force, deltaTime: dt)
            do {
                let result = try entity.moveCharacter(by: motion.agent.position - start)
                // Discard the predicted pose; the controller owns the accepted pose.
                motion.agent.position = entity.scenePosition
                for contact in result.contacts {
                    let normal = contact.normal
                    let inward = motion.agent.velocity.x * normal.x + motion.agent.velocity.y * normal.y
                    if inward < 0 { motion.agent.velocity -= normal * inward }
                }
                if result.isOverlapping { motion.agent.velocity = .zero }
                motion.lastError = nil
            } catch {
                motion.agent.position = start
                motion.agent.velocity = .zero
                motion.lastError = String(describing: error)
            }
            entity.components.set(motion)
        }
    }
}

@MainActor
@Observable
final class SteeringSceneModel {
    let player = Entity(name: "player", components:
        SpriteComponent(color: .cyan, size: [28, 28]),
        CharacterControllerComponent(shape: .circle(radius: 14)),
        SteeringMotion())
    let destination = Entity(name: "destination", components:
        SpriteComponent(color: .green, size: [12, 12]))
    let wall = Entity(name: "wall", components:
        SpriteComponent(color: .orange, size: [18, 160]),
        CollisionComponent(shape: .rectangle(size: [18, 160])))
    var status = "Preparing steering"

    func install(in content: GameViewContent) {
        reset()
        destination.position = [100, 60]
        content.add(destination)
        content.add(wall)
        content.add(player)
        do {
            try content.world.systems.add(SteeringMovementSystem.self)
            status = "Steering ready"
        } catch {
            status = "Could not schedule steering: \(error)"
        }
    }

    func reset() {
        player.position = [-100, -60]
        player.components.set(SteeringMotion())
        status = "Moving toward the green destination"
    }
}

@MainActor
struct ContentView: View {
    @State private var scene = SteeringSceneModel()

    var body: some View {
        VStack {
            GameView { content in
                scene.install(in: content)
            }
            .frame(height: 320)
            Button("Restart route") { scene.reset() }
            Text(scene.status)
        }
    }
}
