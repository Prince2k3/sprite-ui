import Foundation

/// A state in a ``StateMachine``, usually an enum.
///
/// ```swift
/// enum Door: GameState {
///     case open, closed, locked
///
///     func canTransition(to next: Door) -> Bool {
///         switch (self, next) {
///         case (.open, .closed), (.closed, .open),
///              (.closed, .locked), (.locked, .closed): true
///         default: false
///         }
///     }
/// }
/// ```
public protocol GameState: Hashable, Sendable {
    /// Whether the machine may move from this state to `next`.
    ///
    /// By default any change is allowed, but re-entering the current state is not,
    /// so calling `enter(.chase)` every frame doesn't restart the state's timer.
    func canTransition(to next: Self) -> Bool
}

extension GameState {
    public func canTransition(to next: Self) -> Bool { next != self }
}

/// A move from one state to another.
public struct StateTransition<State: GameState>: Hashable, Sendable {
    public let from: State
    public let to: State

    public init(from: State, to: State) {
        self.from = from
        self.to = to
    }
}

/// Tracks the current state and how long the machine has been in it.
///
/// A value type: copy it, compare it, and (when its state is `Codable`) save it.
///
/// ```swift
/// var door = StateMachine(Door.closed)
/// door.enter(.locked)     // allowed
/// door.enter(.open)       // refused: returns nil, stays locked
/// ```
public struct StateMachine<State: GameState>: Hashable, Sendable {
    public private(set) var state: State
    public private(set) var previousState: State?
    /// Seconds since the current state was entered, advanced by ``advance(by:)``.
    public private(set) var timeInState: TimeInterval = 0

    public init(_ initialState: State) {
        state = initialState
    }

    /// Whether ``enter(_:)`` would accept `next` right now.
    public func canEnter(_ next: State) -> Bool {
        state.canTransition(to: next)
    }

    /// Moves to `next` if the current state allows it.
    /// - Returns: The transition, or `nil` if it was refused.
    @discardableResult
    public mutating func enter(_ next: State) -> StateTransition<State>? {
        guard canEnter(next) else { return nil }
        let transition = StateTransition(from: state, to: next)
        previousState = state
        state = next
        timeInState = 0
        return transition
    }

    /// Adds `deltaTime` seconds to ``timeInState``.
    public mutating func advance(by deltaTime: TimeInterval) {
        timeInState += deltaTime
    }
}

extension StateMachine: Codable where State: Codable {}
