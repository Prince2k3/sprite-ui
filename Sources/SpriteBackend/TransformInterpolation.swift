@_spi(Backend) import ECSCore
import SpriteKit

/// Exact native values, rather than Float-converted model values, are restored
/// before bindings, actions, or physics can use a presentation as their baseline.
@MainActor
struct FixedPresentedPose {
    let node: SKNode
    let position: CGPoint
    let rotation: CGFloat
    let xScale: CGFloat
    let yScale: CGFloat
    let zPosition: CGFloat
    let displayed: Transform

    init(_ node: SKNode, displayed: Transform) {
        self.node = node
        self.displayed = displayed
        position = node.position
        rotation = node.zRotation
        xScale = node.xScale
        yScale = node.yScale
        zPosition = node.zPosition
    }

    /// Restores channels still owned by interpolation, preserving native edits
    /// made since the frame was displayed. Returns whether ownership changed.
    func restore() -> Bool {
        var externallyEdited = false
        if node.position == CGPoint(x: CGFloat(displayed.translation.x), y: CGFloat(displayed.translation.y)) {
            node.position = position
        } else { externallyEdited = true }
        if node.zRotation == CGFloat(displayed.rotation) {
            node.zRotation = rotation
        } else { externallyEdited = true }
        if node.xScale == CGFloat(displayed.scale.x) {
            node.xScale = xScale
        } else { externallyEdited = true }
        if node.yScale == CGFloat(displayed.scale.y) {
            node.yScale = yScale
        } else { externallyEdited = true }
        if node.zPosition == CGFloat(displayed.zPosition) {
            node.zPosition = zPosition
        } else { externallyEdited = true }
        return externallyEdited
    }
}

extension SpriteRenderer {
    func restoreFixedTransformPresentation(affecting changed: Entity? = nil, includingHierarchy: Bool = true) {
        guard !fixedPresentedPoses.isEmpty else { return }
        // Clear first: restoration must never become an animation/model write.
        let previous = fixedPresentedPoses.filter { id, _ in
            guard let changed, let entity = world.entity(withID: id) else { return true }
            return entity === changed || (includingHierarchy && (entity.isDescendant(of: changed) || changed.isDescendant(of: entity)))
        }
        for id in previous.keys { fixedPresentedPoses[id] = nil }
        for (id, pose) in previous {
            if pose.restore(), let entity = world.entity(withID: id) {
                world.resetFixedTransformHistory(for: entity)
            }
        }
    }

    /// Picking needs pending bindings and the pose that was actually displayed.
    /// During native update/physics there is no displayed override to reapply.
    func flushForDisplayedPicking() {
        let wasPresented = !fixedPresentedPoses.isEmpty
        flush()
        if wasPresented && fixedPresentedPoses.isEmpty { applyFixedTransformPresentation() }
    }

    /// Interpolation owns only the stable entity node's displayed local pose.
    /// It never writes Transform, binding caches, snapshots, or query geometry.
    /// Physics, cameras, characters, constraints, and native actions in the
    /// affected subtree/ancestor chain retain exclusive transform ownership.
    /// Unknown native actions are conservatively treated as transform actions.
    /// A separate visual child needs its own changing fixed local transform;
    /// marking a static child cannot smooth its parent's simulation movement.
    func fixedInterpolatedPose(for entity: Entity) -> Transform? {
        if let pose = world.networkPresentedTransform(for: entity), !world.isPaused, world.timeScale > 0,
           entity.isActive, let node = node(for: entity),
           !manipulationSessions.values.contains(where: { $0.isActive && $0.entity === entity }),
           !hasFixedInterpolationConflict(in: entity, node: node), entity.presentation.transform == entity.transform {
            return pose != entity.transform ? pose : nil
        }
        guard world.fixedStep != nil, !world.isPaused, world.timeScale > 0,
              entity.isActive, let node = node(for: entity),
              let sample = world.fixedTransformSample(for: entity) else { return nil }

        // A native action, custom binding, or direct node edit wins over history.
        // Discard the pair, so releasing ownership before the next fixed tick
        // cannot resume an old interpolation and snap the displayed pose back.
        guard !manipulationSessions.values.contains(where: { $0.isActive && $0.entity === entity }),
              !hasFixedInterpolationConflict(in: entity, node: node),
              entity.presentation.transform == sample.current else {
            world.resetFixedTransformHistory(for: entity)
            return nil
        }
        guard sample.previous != sample.current else { return nil }
        return Self.interpolateFixedTransform(previous: sample.previous, current: sample.current,
                                              alpha: world.fixedStepState.interpolationAlpha)
    }

    static func interpolateFixedTransform(previous: Transform, current: Transform, alpha: Double) -> Transform? {
        guard alpha.isFinite, (0...1).contains(alpha) else { return nil }
        func finite(_ pose: Transform) -> Bool {
            pose.translation.x.isFinite && pose.translation.y.isFinite && pose.rotation.isFinite
                && pose.scale.x.isFinite && pose.scale.y.isFinite && pose.zPosition.isFinite
        }
        guard finite(previous), finite(current) else { return nil }
        func mix(_ a: Float, _ b: Float) -> Float {
            Float(Double(a) + (Double(b) - Double(a)) * alpha)
        }
        // Double intermediates keep finite Float extremes from overflowing in
        // subtraction, including opposite-sign positions, scales, and angles.
        var angle = (Double(current.rotation) - Double(previous.rotation)).truncatingRemainder(dividingBy: 2 * .pi)
        if angle > .pi { angle -= 2 * .pi }
        if angle < -.pi { angle += 2 * .pi }
        let pose = Transform(
            translation: [mix(previous.translation.x, current.translation.x), mix(previous.translation.y, current.translation.y)],
            rotation: Float(Double(previous.rotation) + angle * alpha),
            scale: [mix(previous.scale.x, current.scale.x), mix(previous.scale.y, current.scale.y)],
            zPosition: mix(previous.zPosition, current.zPosition))
        return finite(pose) ? pose : nil
    }

    private func hasFixedInterpolationConflict(in entity: Entity, node: SKNode) -> Bool {
        func controlled(_ entity: Entity) -> Bool {
            entity.components.has(PhysicsBodyComponent.self)
                || entity.components.has(CameraComponent.self)
                || entity.components.has(CharacterControllerComponent.self)
                || entity.components.has(TransformConstraintComponent.self)
                || entity.components[PlaybackStorage.self]?.controllers.contains {
                    guard let animation = $0 as? AnimationPlaybackController else { return false }
                    return !animation.isTerminal && !animation.resource.channels.isDisjoint(with: [.position, .rotation, .scale])
                } == true
        }
        var conflict = false
        entity.visit { if controlled($0) { conflict = true } }
        if conflict || hasFixedInterpolationNativeConflict(node, includingEntityChildren: true) { return true }
        var ancestor = entity.parent
        while let value = ancestor {
            if controlled(value) { return true }
            if let node = self.node(for: value), hasFixedInterpolationNativeConflict(node, includingEntityChildren: false) { return true }
            ancestor = value.parent
        }
        return false
    }

    /// Cameras need the proposed pose before the final flush. Nil preserves the
    /// existing camera path when neither the target nor an ancestor interpolates.
    func proposedFixedTargetPosition(of entity: Entity) -> SIMD2<Float>? {
        guard let matrix = proposedFixedTargetMatrix(of: entity, canonicalPose: { $0.presentation.transform }) else { return nil }
        let position = matrix.apply(to: .zero)
        return position.x.isFinite && position.y.isFinite ? position : nil
    }

    /// Constraint targets need full displayed rotation/scale as well as position.
    /// The caller supplies canonical poses so already-evaluated constraints keep
    /// their authority. Constraint sources continue to use their own baseline.
    func proposedFixedTargetMatrix(of entity: Entity, canonicalPose: (Entity) -> Transform) -> AffineTransform2D? {
        guard world.fixedStep != nil || world.hasNetworkTransformPresentation,
              !world.isPaused, world.timeScale > 0 else { return nil }
        var chain: [Entity] = [], current: Entity? = entity
        while let value = current { chain.append(value); current = value.parent }
        var matrix = AffineTransform2D.identity
        var interpolated = false
        for value in chain.reversed() {
            let proposed = fixedInterpolatedPose(for: value)
            interpolated = interpolated || proposed != nil
            matrix = matrix * (proposed ?? canonicalPose(value)).matrix
        }
        guard interpolated else { return nil }
        return matrix
    }

    /// Called after cameras and the last flush. Capture every canonical value
    /// before applying any parent offsets, so nested samples stay independent.
    func applyFixedTransformPresentation() {
        guard world.fixedStep != nil || world.hasNetworkTransformPresentation,
              !world.isPaused, world.timeScale > 0 else { return }
        var poses: [(Entity.ID, SKNode, Transform)] = []
        for entity in world.allEntities {
            if let pose = fixedInterpolatedPose(for: entity), let node = node(for: entity) {
                poses.append((entity.id, node, pose))
            }
        }
        for (id, node, pose) in poses {
            fixedPresentedPoses[id] = FixedPresentedPose(node, displayed: pose)
            node.position = CGPoint(x: CGFloat(pose.translation.x), y: CGFloat(pose.translation.y))
            node.zRotation = CGFloat(pose.rotation)
            node.xScale = CGFloat(pose.scale.x)
            node.yScale = CGFloat(pose.scale.y)
            node.zPosition = CGFloat(pose.zPosition)
        }
    }
}
