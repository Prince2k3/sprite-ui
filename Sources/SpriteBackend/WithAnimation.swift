import ECSCore
import SwiftUI

// `withAnimation` for SpriteUI, shaped like SwiftUI's so the two read the same.
//
// These overloads are chosen over SwiftUI's whenever the argument is an `ActionAnimation`
// preset (`.spring(...)`, `.easeInOut`, `.bouncy`...) or omitted. They also forward to
// SwiftUI's `withAnimation`, so `@State` and `@Observable` changes in the same body animate too.
//
// A value explicitly typed as SwiftUI's `Animation` goes to SwiftUI's function and
// does not animate sprites.

/// Animates every component change made in `body`, like SwiftUI's `withAnimation`.
///
/// Components take their new values immediately: `entity.transform` returns the target
/// right away. The renderer animates what's on screen toward it. Read
/// `entity.presentation` for the value currently shown.
///
/// ```swift
/// withAnimation(.spring(duration: 0.4, bounce: 0.3)) {
///     player.position = [100, 0]
///     player.components[SpriteComponent.self]?.opacity = 0
/// } completion: {
///     player.removeFromParent()
/// }
/// ```
///
/// - Starting a new animation on a property replaces the old one, continuing from what's on screen.
/// - Pass `.disabled` to set values directly, even inside an outer `withAnimation`.
/// - `completion` runs once every sprite animation started by this call has finished, been
///   replaced, or had its entity removed. It never runs for `repeatForever` animations.
@MainActor
@discardableResult
public func withAnimation<Result>(
    _ animation: ActionAnimation,
    _ body: () throws -> Result
) rethrows -> Result {
    try SwiftUI.withAnimation(animation.swiftUI) {
        try ActionTransaction.perform(animation, completion: nil, body)
    }
}

/// Animates with ``ActionAnimation/default``.
@MainActor
@discardableResult
public func withAnimation<Result>(_ body: () throws -> Result) rethrows -> Result {
    try withAnimation(.default, body)
}

/// Animates, then calls `completion` once every sprite animation from this call is done.
@MainActor
@discardableResult
public func withAnimation<Result>(
    _ animation: ActionAnimation,
    _ body: () throws -> Result,
    completion: @escaping () -> Void
) rethrows -> Result {
    try SwiftUI.withAnimation(animation.swiftUI) {
        try ActionTransaction.perform(animation, completion: completion, body)
    }
}

/// Animates with ``ActionAnimation/default``, then calls `completion`.
@MainActor
@discardableResult
public func withAnimation<Result>(
    _ body: () throws -> Result,
    completion: @escaping () -> Void
) rethrows -> Result {
    try withAnimation(.default, body, completion: completion)
}

extension ActionAnimation {
    /// The SwiftUI equivalent, used to animate view state changed in the same `withAnimation`.
    public var swiftUI: Animation? {
        guard duration > 0 || delay > 0 else { return nil }
        var result: Animation
        switch curve {
        case .linear: result = .linear(duration: duration)
        case .easeIn: result = .easeIn(duration: duration)
        case .easeOut: result = .easeOut(duration: duration)
        case .easeInOut: result = .easeInOut(duration: duration)
        case .spring(let bounce): result = .spring(duration: duration, bounce: bounce)
        case .custom(let progress): result = Animation(CurveAnimation(duration: duration, progress: progress))
        }
        if delay > 0 { result = result.delay(delay) }
        if speed != 1 { result = result.speed(speed) }
        switch repeatMode {
        case .once: break
        case .count(let count, let autoreverses): result = result.repeatCount(count, autoreverses: autoreverses)
        case .forever(let autoreverses): result = result.repeatForever(autoreverses: autoreverses)
        }
        return result
    }
}

/// Runs a custom progress curve as a SwiftUI animation.
private struct CurveAnimation: CustomAnimation {
    let id = UUID()
    let duration: TimeInterval
    let progress: @Sendable (Double) -> Double

    func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        guard time < duration else { return nil }
        return value.scaled(by: progress(time / duration))
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
