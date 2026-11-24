@_spi(Backend) import ECSCore
import Foundation
import SpriteKit

struct TransformConstraintEvaluation {
    let statuses: [TransformConstraintStatus]
}

private extension TransformConstraintBehavior {
    var target: ConstraintTarget? {
        switch self {
        case .follow(let target, _, _, _), .lookAt(let target, _, _), .distance(let target, _): target
        default: nil
        }
    }
}

extension SpriteRenderer {
    /// A final presentation pass rather than a simulation System: native actions
    /// have already advanced, and cameras/attachments consume these final poses.
    func updateTransformConstraints(deltaTime: TimeInterval, allowPaused: Bool = false) {
        guard (allowPaused || (!world.isPaused && world.timeScale > 0)), deltaTime.isFinite, deltaTime >= 0 else { return }
        var entities: [Entity] = []
        world.root.visit { entities.append($0) }
        let owners = entities.filter { $0.components.has(TransformConstraintComponent.self) }
        let presentOwners = Set(owners.map(\.id))
        constraintEvaluations = constraintEvaluations.filter { presentOwners.contains($0.key) }
        let enabled = owners.filter { owner in
            owner.isActive && owner.components[TransformConstraintComponent.self].map { $0.isEnabled && $0.constraints.contains(where: \.isEnabled) } == true
        }
        let ownerIDs = Set(enabled.map(\.id))
        let byID = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) })
        var poses: [Entity.ID: Transform] = [:]
        for entity in entities { poses[entity.id] = entity.presentation.transform }
        func matrix(of entity: Entity?) -> AffineTransform2D {
            guard let entity else { return .identity }
            return matrix(of: entity.parent) * (poses[entity.id] ?? entity.transform).matrix
        }
        func targetEntity(_ target: ConstraintTarget) -> Entity? {
            switch target {
            case .entity(let id): byID[id]
            case .named(let name): entities.first { $0.name == name }
            case .point: nil
            }
        }
        func cameraControlled(_ entity: Entity) -> Bool {
            var current: Entity? = entity
            while let value = current {
                if value.components.has(CameraComponent.self) { return true }
                current = value.parent
            }
            return false
        }
        var dynamicSubtrees: Set<Entity.ID> = [], characterSubtrees: Set<Entity.ID> = []
        for entity in entities.reversed() where entity.isActive {
            if entity.components[PhysicsBodyComponent.self]?.isDynamic == true || dynamicSubtrees.contains(entity.id) {
                dynamicSubtrees.insert(entity.id)
                if let parent = entity.parent { dynamicSubtrees.insert(parent.id) }
            }
            if entity.components.has(CharacterControllerComponent.self) || characterSubtrees.contains(entity.id) {
                characterSubtrees.insert(entity.id)
                if let parent = entity.parent { characterSubtrees.insert(parent.id) }
            }
        }
        func ownerRejection(_ owner: Entity) -> TransformConstraintStatus? {
            if dynamicSubtrees.contains(owner.id) { return .dynamicBody }
            if characterSubtrees.contains(owner.id) { return .characterControlled }
            if cameraControlled(owner) { return .cameraControlled }
            return nil
        }
        // An owner depends on its constrained ancestors and on every constrained
        // ancestor of each target. This also catches feedback through descendants.
        var dependencies: [Entity.ID: Set<Entity.ID>] = [:]
        func addAncestors(_ entity: Entity?, to id: Entity.ID) {
            var current = entity
            while let value = current {
                if ownerIDs.contains(value.id) { dependencies[id, default: []].insert(value.id) }
                current = value.parent
            }
        }
        for owner in enabled {
            guard ownerRejection(owner) == nil else { continue }
            addAncestors(owner.parent, to: owner.id)
            for rule in owner.components[TransformConstraintComponent.self]!.constraints where rule.isEnabled && rule.behavior.isValid {
                if let target = rule.behavior.target, let entity = targetEntity(target), entity.isActive, !cameraControlled(entity) {
                    addAncestors(entity, to: owner.id)
                }
            }
        }
        // Strongly connected components distinguish every member of overlapping
        // feedback loops from owners that merely depend on a rejected loop.
        var indices: [Entity.ID: Int] = [:], low: [Entity.ID: Int] = [:], nextIndex = 0
        var onStack: Set<Entity.ID> = [], cycles: Set<Entity.ID> = []
        var stack: [Entity.ID] = [], order: [Entity.ID] = []
        func visit(_ id: Entity.ID) {
            indices[id] = nextIndex; low[id] = nextIndex; nextIndex += 1
            onStack.insert(id); stack.append(id)
            for dependency in (dependencies[id] ?? []).sorted() {
                if indices[dependency] == nil {
                    visit(dependency); low[id] = min(low[id]!, low[dependency]!)
                } else if onStack.contains(dependency) { low[id] = min(low[id]!, indices[dependency]!) }
            }
            if low[id] == indices[id] {
                var component: [Entity.ID] = []
                while let member = stack.popLast() {
                    onStack.remove(member); component.append(member)
                    if member == id { break }
                }
                if component.count > 1 || dependencies[id]?.contains(id) == true { cycles.formUnion(component) }
            }
            order.append(id)
        }
        for owner in enabled where indices[owner.id] == nil { visit(owner.id) }
        var blocked: Set<Entity.ID> = cycles
        for id in order {
            guard let owner = byID[id], let model = owner.components[TransformConstraintComponent.self] else { continue }
            let rejection: TransformConstraintStatus?
            if cycles.contains(id) { rejection = .cycle }
            else if !(dependencies[id] ?? []).isDisjoint(with: blocked) { rejection = .dependencyFailed; blocked.insert(id) }
            else { rejection = ownerRejection(owner) }
            var statuses: [TransformConstraintStatus] = [], channels: Set<AnimationChannel> = []
            var pose = poses[id] ?? owner.transform
            let parent = matrix(of: owner.parent)
            for rule in model.constraints {
                guard rule.isEnabled else { statuses.append(.disabled); continue }
                if let rejection { statuses.append(rejection); continue }
                let result = evaluateConstraint(rule.behavior, pose: &pose, parent: parent, deltaTime: deltaTime) { target in
                    switch target {
                    case .point(let point, let space):
                        guard finite(point) else { return .failure(.invalidConfiguration) }
                        var frame = space == .parent ? parent : .identity
                        let position = frame.apply(to: point); frame.tx = position.x; frame.ty = position.y
                        return .success(frame)
                    default:
                        guard let entity = targetEntity(target) else { return .failure(.missingTarget) }
                        guard entity.isActive else { return .failure(.inactiveTarget) }
                        guard !cameraControlled(entity) else { return .failure(.cameraControlled) }
                        let displayed = proposedFixedTargetMatrix(of: entity) { poses[$0.id] ?? $0.transform }
                        return .success(displayed ?? matrix(of: entity))
                    }
                }
                switch result {
                case .success(let channel): statuses.append(.active); channels.insert(channel)
                case .failure(let status): statuses.append(status)
                }
            }
            if !channels.isEmpty {
                poses[id] = pose
                commitPresentedPose(pose, channels: channels, entity: owner)
            }
            constraintEvaluations[id] = .init(statuses: statuses)
        }
        for owner in owners where !ownerIDs.contains(owner.id) {
            if let model = owner.components[TransformConstraintComponent.self] {
                constraintEvaluations[owner.id] = .init(statuses: model.constraints.map { _ in .disabled })
            }
        }
    }
}

extension SpriteRenderer {
    /// Includes presented ancestor actions and physics, not their model targets.
    func presentedSceneMatrix(of entity: Entity?) -> AffineTransform2D {
        guard let entity else { return .identity }
        return presentedSceneMatrix(of: entity.parent) * entity.presentation.transform.matrix
    }
}

// Result requires an Error failure; the public status remains a small value enum.
extension TransformConstraintStatus: Error {}

private func finite(_ point: SIMD2<Float>) -> Bool { point.x.isFinite && point.y.isFinite }
private func valid(_ range: ClosedRange<Float>) -> Bool { range.lowerBound.isFinite && range.upperBound.isFinite }
private func wrapped(_ angle: Float) -> Float { atan2(sin(angle), cos(angle)) }

/// Validates and computes one rule atomically. Matrix inversion handles rotated,
/// nonuniform, reflected and sheared ancestor frames without decomposing them.
private func evaluateConstraint(_ behavior: TransformConstraintBehavior, pose: inout Transform, parent: AffineTransform2D,
                                deltaTime: TimeInterval, target: (ConstraintTarget) -> Result<AffineTransform2D, TransformConstraintStatus>) -> Result<AnimationChannel, TransformConstraintStatus> {
    guard behavior.isValid else { return .failure(.invalidConfiguration) }
    guard let inverse = parent.inverted(), pose.matrix.inverted() != nil else { return .failure(.invalidTransform) }
    var next = pose
    func factor(_ seconds: Float) -> Float { seconds == 0 ? 1 : Float(-expm1(-deltaTime / Double(seconds))) }
    func frame(_ reference: ConstraintTarget) -> Result<AffineTransform2D, TransformConstraintStatus> {
        target(reference).flatMap { $0.inverted() == nil ? .failure(.invalidTransform) : .success($0) }
    }
    func rotation(toward direction: SIMD2<Float>, forwardAngle: Float) -> Float? {
        let local = inverse.apply(toDirection: direction)
        let forward = SIMD2(cos(forwardAngle), sin(forwardAngle)) * pose.scale
        guard finite(local), finite(forward), hypot(local.x, local.y) > 0, hypot(forward.x, forward.y) > 0 else { return nil }
        return atan2(local.y, local.x) - atan2(forward.y, forward.x)
    }
    let channel: AnimationChannel
    switch behavior {
    case .follow(let reference, let offset, let space, let smoothing):
        guard finite(offset), smoothing.isFinite, smoothing >= 0 else { return .failure(.invalidConfiguration) }
        switch frame(reference) {
        case .failure(let status): return .failure(status)
        case .success(let target):
            let origin = SIMD2(target.tx, target.ty)
            let desired = origin + (space == .target ? target.apply(toDirection: offset) : offset)
            next.translation += (inverse.apply(to: desired) - pose.translation) * factor(smoothing)
        }
        channel = .position
    case .lookAt(let reference, let forward, let smoothing):
        guard forward.isFinite, smoothing.isFinite, smoothing >= 0 else { return .failure(.invalidConfiguration) }
        switch frame(reference) {
        case .failure(let status): return .failure(status)
        case .success(let target):
            let direction = SIMD2(target.tx, target.ty) - parent.apply(to: pose.translation)
            if direction != .zero {
                guard let desired = rotation(toward: direction, forwardAngle: forward) else { return .failure(.invalidTransform) }
                next.rotation += wrapped(desired - pose.rotation) * factor(smoothing)
            }
        }
        channel = .rotation
    case .distance(let reference, let range):
        guard valid(range), range.lowerBound >= 0 else { return .failure(.invalidConfiguration) }
        switch frame(reference) {
        case .failure(let status): return .failure(status)
        case .success(let target):
            let origin = SIMD2(target.tx, target.ty), delta = parent.apply(to: pose.translation) - origin
            let length = hypot(delta.x, delta.y)
            guard length.isFinite else { return .failure(.invalidTransform) }
            let desired = min(range.upperBound, max(range.lowerBound, length))
            next.translation = inverse.apply(to: origin + (length > 0 ? delta / length : [1, 0]) * desired)
        }
        channel = .position
    case .positionBounds(let min, let max, let space):
        guard finite(min), finite(max), min.x <= max.x, min.y <= max.y else { return .failure(.invalidConfiguration) }
        let point = space == .parent ? pose.translation : parent.apply(to: pose.translation)
        let clamped = SIMD2(Swift.min(max.x, Swift.max(min.x, point.x)), Swift.min(max.y, Swift.max(min.y, point.y)))
        next.translation = space == .parent ? clamped : inverse.apply(to: clamped)
        channel = .position
    case .rotationLimits(let range, let space):
        guard valid(range) else { return .failure(.invalidConfiguration) }
        if space == .parent { next.rotation = min(range.upperBound, max(range.lowerBound, pose.rotation)) }
        else {
            guard range.lowerBound >= -.pi, range.upperBound <= .pi else { return .failure(.invalidConfiguration) }
            let axis = (parent * pose.matrix).apply(toDirection: [1, 0])
            let angle = atan2(axis.y, axis.x), desired = min(range.upperBound, max(range.lowerBound, angle))
            guard let local = rotation(toward: [cos(desired), sin(desired)], forwardAngle: 0) else { return .failure(.invalidTransform) }
            next.rotation += wrapped(local - pose.rotation)
        }
        channel = .rotation
    }
    guard finite(next.translation), next.rotation.isFinite, next.matrix.inverted() != nil else { return .failure(.invalidTransform) }
    pose = next
    return .success(channel)
}
