import Foundation

/// How a change made inside ``withAnimation(_:_:completion:)`` moves from its old value to its new one.
///
/// Mirrors SwiftUI's `Animation`:
///
/// ```swift
/// withAnimation(.spring(duration: 0.4, bounce: 0.3)) { player.position = [0, 120] }
/// withAnimation(.easeOut(duration: 0.2).delay(0.1)) { coin.transform.scale = [2, 2] }
/// withAnimation(.linear(duration: 1).repeatForever(autoreverses: true)) { glow.components[SpriteComponent.self]?.opacity = 0.2 }
/// ```
public struct ActionAnimation: Sendable {
    public enum Curve: Sendable {
        case linear
        case easeIn
        case easeOut
        case easeInOut
        /// A damped spring. `bounce` 0 settles without overshoot; higher values overshoot more.
        case spring(bounce: Double)
        /// Maps linear progress 0...1 to eased progress. It should return 0 at 0 and 1 at 1.
        case custom(@Sendable (Double) -> Double)
    }

    public enum Repeat: Sendable, Equatable {
        case once
        case count(Int, autoreverses: Bool)
        case forever(autoreverses: Bool)
    }

    public var curve: Curve
    /// Seconds for one pass, before `speed` is applied.
    public var duration: TimeInterval
    public var delay: TimeInterval = 0
    public var speed: Double = 1
    public var repeatMode: Repeat = .once

    public init(curve: Curve, duration: TimeInterval) {
        self.curve = curve
        self.duration = max(0, duration)
    }

    // MARK: Presets

    public static let `default` = easeInOut(duration: 0.35)

    public static var linear: Self { linear() }
    public static var easeIn: Self { easeIn() }
    public static var easeOut: Self { easeOut() }
    public static var easeInOut: Self { easeInOut() }
    public static var spring: Self { spring() }
    public static var smooth: Self { spring(duration: 0.5, bounce: 0) }
    /// Sets values directly. Use it inside an outer `withAnimation` to opt some changes out.
    public static var disabled: Self { Self(curve: .linear, duration: 0) }

    public static func linear(duration: TimeInterval = 0.35) -> Self { Self(curve: .linear, duration: duration) }
    public static func easeIn(duration: TimeInterval = 0.35) -> Self { Self(curve: .easeIn, duration: duration) }
    public static func easeOut(duration: TimeInterval = 0.35) -> Self { Self(curve: .easeOut, duration: duration) }
    public static func easeInOut(duration: TimeInterval = 0.35) -> Self { Self(curve: .easeInOut, duration: duration) }

    public static func spring(duration: TimeInterval = 0.5, bounce: Double = 0) -> Self {
        Self(curve: .spring(bounce: bounce), duration: duration)
    }

    public static func smooth(duration: TimeInterval = 0.5) -> Self { spring(duration: duration, bounce: 0) }
    public static func snappy(duration: TimeInterval = 0.3) -> Self { spring(duration: duration, bounce: 0.15) }
    public static func bouncy(duration: TimeInterval = 0.5) -> Self { spring(duration: duration, bounce: 0.3) }

    public static var bouncy: Self { spring(duration: 0.5, bounce: 0.3) }
    public static var snappy: Self { spring(duration: 0.3, bounce: 0.15) }

    public static func timingCurve(duration: TimeInterval, _ progress: @escaping @Sendable (Double) -> Double) -> Self {
        Self(curve: .custom(progress), duration: duration)
    }

    // MARK: Modifiers

    public func delay(_ seconds: TimeInterval) -> Self {
        var copy = self; copy.delay = max(0, seconds); return copy
    }

    public func speed(_ multiplier: Double) -> Self {
        var copy = self; copy.speed = max(0.0001, multiplier); return copy
    }

    public func repeatCount(_ count: Int, autoreverses: Bool = true) -> Self {
        var copy = self; copy.repeatMode = .count(max(1, count), autoreverses: autoreverses); return copy
    }

    public func repeatForever(autoreverses: Bool = true) -> Self {
        var copy = self; copy.repeatMode = .forever(autoreverses: autoreverses); return copy
    }

    /// Whether this animation ever finishes on its own.
    public var isFinite: Bool {
        if case .forever = repeatMode { return false }
        return true
    }
}

extension ActionAnimation.Curve {
    /// Eased progress for linear progress `t` in 0...1. Springs may briefly exceed 1.
    public func progress(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        switch self {
        case .linear: return t
        case .easeIn: return t * t * t
        case .easeOut: let u = 1 - t; return 1 - u * u * u
        case .easeInOut: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .spring(let bounce): return Self.spring(t, bounce: bounce)
        case .custom(let f): return f(t)
        }
    }

    /// A damped spring tuned to settle by the end of the duration.
    static func spring(_ t: Double, bounce: Double) -> Double {
        if t >= 1 { return 1 }
        let damping = 1 - min(max(bounce, 0), 0.9)          // 1 = critically damped
        if damping >= 0.999 {
            let omega = 9.2                                    // (1 + ωt)e^(-ωt) ≈ 0.001 at t = 1
            return 1 - (1 + omega * t) * exp(-omega * t)
        }
        let decay = 6.9                                        // e^(-6.9) ≈ 0.001 at t = 1
        let omega = decay / damping
        let damped = omega * (1 - damping * damping).squareRoot()
        let envelope = exp(-decay * t)
        return 1 - envelope * (cos(damped * t) + (decay / damped) * sin(damped * t))
    }
}
