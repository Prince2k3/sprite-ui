import ECSCore
import Foundation
import Gameplay
import GameplayECS
import Testing

enum Door: String, GameState, Codable {
    case open, closed, locked

    func canTransition(to next: Door) -> Bool {
        switch (self, next) {
        case (.open, .closed), (.closed, .open), (.closed, .locked), (.locked, .closed): true
        default: false
        }
    }
}

enum Light: GameState { case red, green }

@Suite struct StateMachineTests {
    @Test func followsAllowedTransitionsOnly() {
        var door = StateMachine(Door.open)
        #expect(door.enter(.locked) == nil)
        #expect(door.state == .open)
        #expect(door.enter(.closed) == StateTransition(from: .open, to: .closed))
        #expect(door.enter(.locked) != nil)
        #expect(door.state == .locked)
        #expect(door.previousState == .closed)
    }

    @Test func defaultAllowsAnyChangeButNotReentry() {
        var light = StateMachine(Light.red)
        #expect(light.enter(.red) == nil)
        #expect(light.enter(.green) != nil)
    }

    @Test func timerResetsOnEnter() {
        var light = StateMachine(Light.red)
        light.advance(by: 1.5)
        #expect(light.timeInState == 1.5)
        light.enter(.red)  // refused: timer keeps running
        #expect(light.timeInState == 1.5)
        light.enter(.green)
        #expect(light.timeInState == 0)
    }

    @Test func codableRoundTrip() throws {
        var door = StateMachine(Door.open)
        door.enter(.closed)
        door.advance(by: 2)
        let restored = try JSONDecoder().decode(StateMachine<Door>.self, from: JSONEncoder().encode(door))
        #expect(restored == door)
    }
}

/// Records hook calls so tests can check their order.
@MainActor final class HookLog { static var calls: [String] = [] }

enum Guard: EntityState {
    case patrol, chase, attack

    func canTransition(to next: Guard) -> Bool {
        switch (self, next) {
        case (.patrol, .chase), (.chase, .patrol), (.chase, .attack), (.attack, .patrol): true
        default: false
        }
    }

    func didEnter(from previous: Guard?, on entity: Entity) {
        HookLog.calls.append("enter \(self) from \(previous.map { "\($0)" } ?? "nil")")
    }

    func willExit(to next: Guard, on entity: Entity) {
        HookLog.calls.append("exit \(self) to \(next)")
    }

    func update(on entity: Entity, context: UpdateContext) {
        // Attacks last half a second.
        if self == .attack, entity.timeInState(Guard.self) >= 0.5 { entity.enter(Guard.patrol) }
    }
}

@MainActor
@Suite(.serialized) struct StateMachineECSTests {
    init() { HookLog.calls = [] }

    @Test func enterStartsAMachineAndRunsHooksInOrder() {
        let entity = Entity()
        #expect(entity.state(Guard.self) == nil)
        #expect(entity.enter(Guard.patrol))
        #expect(entity.enter(Guard.chase))
        #expect(!entity.enter(Guard.chase))
        #expect(entity.state(Guard.self) == .chase)
        #expect(HookLog.calls == ["enter patrol from nil", "exit patrol to chase", "enter chase from patrol"])
    }

    @Test func refusedTransitionRunsNoHooks() {
        let entity = Entity()
        entity.enter(Guard.patrol)
        HookLog.calls = []
        #expect(!entity.enter(Guard.attack))
        #expect(HookLog.calls.isEmpty)
    }

    @Test func publishesDidEnterEvents() {
        let world = World()
        let entity = Entity()
        world.addEntity(entity)
        var seen: [Guard] = []
        let subscription = world.subscribe(to: StateMachineEvents.DidEnter<Guard>.self, on: entity) {
            seen.append($0.state)
        }
        entity.enter(Guard.patrol)
        entity.enter(Guard.chase)
        entity.enter(Guard.attack)
        #expect(seen == [.patrol, .chase, .attack])
        _ = subscription
    }

    @Test func systemAdvancesTimeAndRunsUpdate() {
        let world = World()
        world.addSystem(StateMachineSystem<Guard>.self)
        let entity = Entity()
        world.addEntity(entity)
        entity.enter(Guard.patrol)
        entity.enter(Guard.chase)
        entity.enter(Guard.attack)

        world.update(deltaTime: 0.3)
        #expect(entity.state(Guard.self) == .attack)
        #expect(abs(entity.timeInState(Guard.self) - 0.3) < 1e-9)
        world.update(deltaTime: 0.3)
        #expect(entity.state(Guard.self) == .patrol)
        #expect(entity.timeInState(Guard.self) == 0)
    }

    @Test func plainGameStatesWorkOnEntitiesToo() {
        let world = World()
        world.addSystem(StateMachineSystem<Door>.self)
        let door = Entity()
        world.addEntity(door)
        door.enter(Door.closed)
        world.update(deltaTime: 1)
        #expect(door.timeInState(Door.self) == 1)
        #expect(!door.enter(Door.closed))
        #expect(door.enter(Door.locked))
    }

    @Test func machinesOfDifferentTypesCoexist() {
        let entity = Entity()
        entity.enter(Guard.patrol)
        entity.enter(Light.green)
        #expect(entity.state(Guard.self) == .patrol)
        #expect(entity.state(Light.self) == .green)
    }
}
