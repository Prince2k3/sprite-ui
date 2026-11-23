import SpriteUI
import SwiftUI
import Observation

struct MovementMotion: Component {
    var velocity: SIMD2<Float> = [80, 0]
}

@MainActor
struct MovementSystem: System {
    private let query = EntityQuery(where: .has(MovementMotion.self))

    init(world: World) {}

    func update(context: UpdateContext) {
        let dt = Float(context.deltaTime)
        for entity in context.entities(matching: query) {
            guard let motion = entity.components[MovementMotion.self] else { continue }
            entity.position += motion.velocity * dt
        }
    }
}

@MainActor
struct MovementBoundsSystem: System {
    static var dependencies: [SystemDependency] { [.after(MovementSystem.self)] }
    private let query = EntityQuery(where: .has(MovementMotion.self))

    init(world: World) {}

    func update(context: UpdateContext) {
        for entity in context.entities(matching: query) {
            guard var motion = entity.components[MovementMotion.self] else { continue }
            if entity.position.x > 100 {
                entity.position.x = 100
                motion.velocity.x = -abs(motion.velocity.x)
            } else if entity.position.x < -100 {
                entity.position.x = -100
                motion.velocity.x = abs(motion.velocity.x)
            }
            entity.components.set(motion)
        }
    }
}

@MainActor
@Observable
final class MovementSceneModel {
    let player = Entity(name: "player", components:
        SpriteComponent(color: .cyan, size: [36, 36]),
        MovementMotion())
    var status = "Preparing movement"

    func install(in content: GameViewContent) {
        player.position = [-100, 0]
        content.add(player)
        do {
            // Install in reverse order to make the dependency visible.
            try content.world.systems.add(MovementBoundsSystem.self)
            try content.world.systems.add(MovementSystem.self)
            status = "Movement ready"
        } catch {
            status = "Could not schedule movement: \(error)"
        }
    }
}

@MainActor
struct ContentView: View {
    @State private var scene = MovementSceneModel()

    var body: some View {
        VStack {
            GameView { content in
                scene.install(in: content)
            }
            .frame(height: 320)
            Text(scene.status)
        }
    }
}
