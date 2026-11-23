@_spi(Backend) import ECSCore
import Foundation
import Gameplay

/// Gives an entity a ``StateMachine``.
///
/// Start one with ``ECSCore/Entity/enter(_:)``, which also runs the state's
/// `didEnter` hook. Add ``StateMachineSystem`` for the state type so time in
/// state advances and per-state `update` runs each frame.
public struct StateMachineComponent<State: GameState>: Component {
    /// Change states with `entity.enter(_:)` so hooks and events fire.
    public internal(set) var machine: StateMachine<State>

    public init(_ initialState: State) {
        machine = StateMachine(initialState)
    }

    public var state: State { machine.state }
}

extension StateMachineComponent: Equatable, Hashable, Sendable {}
extension StateMachineComponent: Codable where State: Codable {}

/// A state that runs logic on the entity it belongs to.
///
/// ```swift
/// enum Guard: EntityState {
///     case patrol, chase
///
///     func didEnter(from previous: Guard?, on entity: Entity) {
///         entity.components[SpriteComponent.self]?.color = self == .chase ? .red : .gray
///     }
///
///     func update(on entity: Entity, context: UpdateContext) {
///         if self == .patrol, playerIsClose(to: entity) { entity.enter(Guard.chase) }
///     }
/// }
/// ```
///
/// Every hook is optional.
public protocol EntityState: GameState {
    /// Called after the entity enters this state. `previous` is `nil` when the
    /// machine starts.
    @MainActor func didEnter(from previous: Self?, on entity: Entity)
    /// Called before the entity leaves this state for `next`.
    @MainActor func willExit(to next: Self, on entity: Entity)
    /// Called every frame by ``StateMachineSystem`` while this is the current state.
    @MainActor func update(on entity: Entity, context: UpdateContext)
}

extension EntityState {
    @MainActor public func didEnter(from previous: Self?, on entity: Entity) {}
    @MainActor public func willExit(to next: Self, on entity: Entity) {}
    @MainActor public func update(on entity: Entity, context: UpdateContext) {}
}

/// Events published from an entity when its state machine changes.
public enum StateMachineEvents {
    /// The entity entered `state`. `previous` is `nil` when the machine started.
    public struct DidEnter<State: GameState>: Event {
        public let entity: Entity
        public let previous: State?
        public let state: State
    }
}

extension Entity {
    /// The entity's current state of type `State`, or `nil` if it has no such machine.
    public func state<State: GameState>(_ type: State.Type) -> State? {
        components[StateMachineComponent<State>.self]?.state
    }

    /// Seconds the entity has been in its current `State`, or 0 without a machine.
    public func timeInState<State: GameState>(_ type: State.Type) -> TimeInterval {
        components[StateMachineComponent<State>.self]?.machine.timeInState ?? 0
    }

    /// Moves the entity's state machine to `state`, starting one if it has none.
    ///
    /// Refused if the current state's `canTransition(to:)` says no.
    /// Publishes ``StateMachineEvents/DidEnter`` on success.
    /// - Returns: Whether the entity is now in `state` because of this call.
    @discardableResult
    public func enter<State: GameState>(_ state: State) -> Bool {
        transition(to: state, willExit: { _ in }, didEnter: { _ in })
    }

    /// Moves the entity's state machine to `state`, running the states' hooks.
    @discardableResult
    public func enter<State: EntityState>(_ state: State) -> Bool {
        transition(
            to: state,
            willExit: { current in current.willExit(to: state, on: self) },
            didEnter: { previous in state.didEnter(from: previous, on: self) }
        )
    }

    private func transition<State: GameState>(
        to state: State,
        willExit: (State) -> Void,
        didEnter: (State?) -> Void
    ) -> Bool {
        guard var component = components[StateMachineComponent<State>.self] else {
            components.set(StateMachineComponent(state))
            didEnter(nil)
            world?.publish(StateMachineEvents.DidEnter(entity: self, previous: nil, state: state), from: self)
            return true
        }
        let current = component.state
        guard component.machine.canEnter(state) else { return false }
        willExit(current)
        component.machine.enter(state)
        components.set(component)
        didEnter(current)
        world?.publish(StateMachineEvents.DidEnter(entity: self, previous: current, state: state), from: self)
        return true
    }
}

/// Advances every `State` machine's timer and runs ``EntityState/update(on:context:)``.
///
/// One system per state type:
///
/// ```swift
/// StateMachineSystem<Guard>.registerSystem()       // every new world
/// world.addSystem(StateMachineSystem<Guard>.self)  // or just this one
/// ```
public struct StateMachineSystem<State: GameState>: System {
    private static var query: EntityQuery { EntityQuery(where: .has(StateMachineComponent<State>.self)) }

    public init(world: World) {}

    public mutating func update(context: UpdateContext) {
        for entity in context.entities(matching: Self.query) {
            guard entity.isActive, entity.world === context.world, var component = entity.components[StateMachineComponent<State>.self] else { continue }
            // Timers tick every frame; they aren't changes the renderer needs to hear about.
            component.machine.advance(by: context.deltaTime)
            entity._setWithoutNotifying(component)
            if let state = component.state as? any EntityState {
                state.update(on: entity, context: context)
            }
        }
    }
}
