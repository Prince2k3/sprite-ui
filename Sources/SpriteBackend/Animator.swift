@_spi(Backend) import ECSCore
import SpriteKit

/// Turns one property change into either a direct set or a keyed `SKAction`,
/// depending on the `withAnimation` it was made in.
///
/// Bindings call ``update(_:on:to:from:set:)`` once per changed property. Each key
/// ("transform.position", "sprite.opacity"...) runs at most one action at a time, so
/// animating one property never cancels another.
@MainActor
public struct Animator {
    unowned let renderer: SpriteRenderer
    let entityID: Entity.ID
    let transaction: ActionTransaction?

    /// The animation to apply, or `nil` when values should be set directly.
    public var animation: ActionAnimation? { transaction?.effectiveAnimation }

    /// Moves a property to its new value.
    ///
    /// - Parameters:
    ///   - key: Identifies the property. A new update with the same key replaces the running one.
    ///   - node: The node to run the action on.
    ///   - forward: Makes an action that goes to the new value over the given duration.
    ///   - reverse: Makes an action that goes back to the value shown right now. Used for
    ///     `autoreverses` and to restart non-reversing repeats.
    ///   - set: Sets the new value directly.
    public func update(
        _ key: String,
        on node: SKNode,
        to forward: (TimeInterval) -> SKAction,
        from reverse: (TimeInterval) -> SKAction,
        set: () -> Void
    ) {
        renderer.cancelAction(key, entityID: entityID, node: node)
        guard !renderer.isAnimationControlled(key, entityID: entityID), let animation else {
            set()
            return
        }
        let action = Self.makeAction(animation, forward: forward, reverse: reverse)
        renderer.runAction(action, key: key, entityID: entityID, node: node, transaction: transaction!, finite: animation.isFinite)
    }

    /// Stops a property's running action, if any, leaving it where it is.
    public func cancel(_ key: String, on node: SKNode) {
        renderer.cancelAction(key, entityID: entityID, node: node)
    }

    // MARK: Building actions

    static func makeAction(
        _ animation: ActionAnimation,
        forward: (TimeInterval) -> SKAction,
        reverse: (TimeInterval) -> SKAction
    ) -> SKAction {
        let duration = animation.duration
        let curve = animation.curve
        func timed(_ action: SKAction) -> SKAction {
            if case .linear = curve {
                action.timingMode = .linear
            } else {
                action.timingFunction = { Float(curve.progress(Double($0))) }
            }
            return action
        }

        var body: SKAction
        switch animation.repeatMode {
        case .once:
            body = timed(forward(duration))
        case .count(let count, let autoreverses):
            var passes: [SKAction] = []
            for pass in 0..<count {
                if autoreverses {
                    passes.append(timed(pass.isMultiple(of: 2) ? forward(duration) : reverse(duration)))
                } else {
                    if pass > 0 { passes.append(reverse(0)) }
                    passes.append(timed(forward(duration)))
                }
            }
            // An even number of autoreversing passes ends where it started; land on the target
            // so the screen agrees with the component.
            passes.append(forward(0))
            body = .sequence(passes)
        case .forever(let autoreverses):
            body = .repeatForever(.sequence(
                autoreverses
                    ? [timed(forward(duration)), timed(reverse(duration))]
                    : [timed(forward(duration)), reverse(0)]
            ))
        }

        if animation.delay > 0 {
            body = .sequence([.wait(forDuration: animation.delay), body])
        }
        body.speed = CGFloat(animation.speed)
        return body
    }
}
