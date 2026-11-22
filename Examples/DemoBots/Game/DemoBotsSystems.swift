import SpriteUI

struct DemoBotsRuntime: Component { weak var game: DemoBotsSession? }

struct DemoBotsLogicSystem: System {
    static var dependencies: [SystemDependency] { [.before(SteeringSystem.self)] }
    private var states: StateMachineSystem<BotMode>
    init(world: World) { states = StateMachineSystem(world: world) }
    mutating func update(context: UpdateContext) {
        guard let game = context.world.root.components[DemoBotsRuntime.self]?.game, game.phase == .playing else { return }
        states.update(context: context)
        game.beforeSteering(deltaTime: Float(context.deltaTime))
    }
}

struct DemoBotsPresentationSystem: System {
    static var phase: SystemPhase { .presentation }
    static var dependencies: [SystemDependency] { [.after(SteeringSystem.self)] }
    init(world: World) {}
    mutating func update(context: UpdateContext) {
        context.world.root.components[DemoBotsRuntime.self]?.game?.afterSteering(deltaTime: Float(context.deltaTime))
    }
}
