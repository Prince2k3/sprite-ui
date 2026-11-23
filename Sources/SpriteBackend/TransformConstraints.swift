@_spi(Backend) import ECSCore
import Foundation

/// The reference frame for a point or limit. Scene space is the final coordinate
/// space after the world's root transform; parent space is the owner's parent frame.
public enum ConstraintSpace: String, Hashable, Codable, Sendable { case scene, parent }

/// A tracking target. Names resolve in hierarchy order, including the world root.
/// Inactive entities remain unresolved until enabled again.
public enum ConstraintTarget: Hashable, Codable, Sendable {
    case entity(Entity.ID)
    case named(String)
    case point(SIMD2<Float>, relativeTo: ConstraintSpace = .scene)
}

/// Target offsets use its full presented rotation and scale. A point target uses
/// its declared reference frame. Scene offsets stay aligned with the scene axes.
public enum ConstraintOffsetSpace: String, Hashable, Codable, Sendable { case scene, target }

/// Transform relationships evaluated in list order. Distances are scene points;
/// angles are counterclockwise radians. Smoothing is a time constant in seconds:
/// zero applies immediately, positive values use frame-independent exponential
/// convergence. Look-at uses the shortest local arc. Parent rotation limits clamp
/// unwrapped angles; scene limits measure local +x in -pi...pi and require bounds
/// in that interval. A coincident distance target uses scene +x when pushed apart.
public enum TransformConstraintBehavior: Hashable, Codable, Sendable {
    case follow(ConstraintTarget, offset: SIMD2<Float> = .zero, offsetSpace: ConstraintOffsetSpace = .target, smoothing: Float = 0)
    /// The artwork's local forward direction: 0 for +x, pi/2 for +y.
    case lookAt(ConstraintTarget, forwardAngle: Float = 0, smoothing: Float = 0)
    case distance(to: ConstraintTarget, range: ClosedRange<Float>)
    case positionBounds(min: SIMD2<Float>, max: SIMD2<Float>, relativeTo: ConstraintSpace = .parent)
    case rotationLimits(ClosedRange<Float>, relativeTo: ConstraintSpace = .parent)

    /// Whether parameters are finite, smoothing/distances nonnegative, and limits
    /// ordered. Target availability and presented transforms validate at evaluation.
    public var isValid: Bool {
        func point(_ value: SIMD2<Float>) -> Bool { value.x.isFinite && value.y.isFinite }
        func range(_ value: ClosedRange<Float>) -> Bool { value.lowerBound.isFinite && value.upperBound.isFinite }
        func target(_ value: ConstraintTarget) -> Bool {
            if case .point(let value, _) = value { return point(value) }
            return true
        }
        switch self {
        case .follow(let value, let offset, _, let smoothing): return target(value) && point(offset) && smoothing.isFinite && smoothing >= 0
        case .lookAt(let value, let angle, let smoothing): return target(value) && angle.isFinite && smoothing.isFinite && smoothing >= 0
        case .distance(let value, let limits): return target(value) && range(limits) && limits.lowerBound >= 0
        case .positionBounds(let min, let max, _): return point(min) && point(max) && min.x <= max.x && min.y <= max.y
        case .rotationLimits(let limits, let space):
            return range(limits) && (space == .parent || (limits.lowerBound >= -.pi && limits.upperBound <= .pi))
        }
    }
}

/// One independently switchable relationship, optionally named for runtime edits.
public struct TransformConstraint: Hashable, Codable, Sendable {
    public var behavior: TransformConstraintBehavior
    public var name: String?
    public var isEnabled: Bool
    public init(_ behavior: TransformConstraintBehavior, name: String? = nil, isEnabled: Bool = true) {
        self.behavior = behavior; self.name = name; self.isEnabled = isEnabled
    }
}

/// Maintains transform relationships after actions, physics and presentation
/// systems, before camera following. A SpriteRenderer evaluates this automatically;
/// a headless world stores the data without evaluating it. Pausing freezes it.
///
/// Constraints consume presented poses and have final authority over the position
/// or rotation they affect. Animations keep their clocks and supply the baseline;
/// scale and draw order are untouched. List order matters: put limits after follow
/// or look-at. Later constraints may supersede earlier ones. Targets and parents
/// with constraints evaluate first, independently of entity insertion order.
///
/// Dynamic bodies or character controllers anywhere in the owner's active subtree,
/// and camera-controlled owners/targets (including descendants), are rejected.
/// Camera components track even when not selected, so isActive does not bypass
/// that check. Use steering/joints or character moves
/// for collision-aware movement, and CameraComponent for
/// cameras. Missing/inactive targets and invalid rules are skipped individually.
/// A dependency cycle skips the entire affected owner; dependents wait too.
/// Singular transforms never produce partial invalid writes. Status values are
/// available through Entity.transformConstraintStatuses after evaluation.
/// Completion-generated writes settle first; chains still writing after 32 flush
/// passes defer constraints/cameras to the next frame with pendingChanges status.
///
/// ```swift
/// companion.components.set(TransformConstraintComponent([
///     TransformConstraint(.follow(.entity(player.id), offset: [-60, 40], smoothing: 0.2), name: "follow"),
///     TransformConstraint(.distance(to: .entity(player.id), range: 30...120))
/// ]))
/// ```
public struct TransformConstraintComponent: Component, Hashable, Codable, Sendable {
    public var constraints: [TransformConstraint]
    public var isEnabled: Bool
    public init(_ constraints: [TransformConstraint], isEnabled: Bool = true) {
        self.constraints = constraints; self.isEnabled = isEnabled
    }
    /// Switches every rule with this name. Returns whether any value changed.
    @discardableResult public mutating func setEnabled(_ enabled: Bool, named name: String) -> Bool {
        var changed = false
        for index in constraints.indices where constraints[index].name == name && constraints[index].isEnabled != enabled {
            constraints[index].isEnabled = enabled; changed = true
        }
        return changed
    }
    /// The first matching rule's state, or nil when the name is absent.
    public func isEnabled(named name: String) -> Bool? { constraints.first { $0.name == name }?.isEnabled }
}

extension TransformConstraintComponent: EntityReferencingComponent {
    @MainActor public mutating func remapEntityReferences(_ context: EntityReferenceRemapping) {
        func remap(_ target: ConstraintTarget) -> ConstraintTarget {
            switch target {
            case .entity(let id): return .entity(context.id(for: id))
            case .named(let name) where context.operation == .clone:
                return context.entity(named: name).map { .entity($0.id) } ?? target
            default: return target
            }
        }
        for index in constraints.indices {
            switch constraints[index].behavior {
            case .follow(let target, let offset, let space, let smoothing):
                constraints[index].behavior = .follow(remap(target), offset: offset, offsetSpace: space, smoothing: smoothing)
            case .lookAt(let target, let angle, let smoothing):
                constraints[index].behavior = .lookAt(remap(target), forwardAngle: angle, smoothing: smoothing)
            case .distance(let target, let range): constraints[index].behavior = .distance(to: remap(target), range: range)
            default: break
            }
        }
    }
}

/// Last evaluation of a rule, in the component's list order. Diagnostics are
/// transient, not saved or cloned. Correcting a target/configuration retries it.
public enum TransformConstraintStatus: String, Hashable, Sendable {
    case active, disabled, missingTarget, inactiveTarget, cycle, dependencyFailed
    case dynamicBody, characterControlled, cameraControlled, invalidConfiguration, invalidTransform, notRendered
    case pendingChanges
}

extension Entity {
    /// Nil without the component; otherwise one status per rule. Before the first
    /// rendered evaluation (or after an edit), enabled rules report notRendered.
    /// - Complexity: O(number of rules).
    public var transformConstraintStatuses: [TransformConstraintStatus]? {
        guard let model = components[TransformConstraintComponent.self] else { return nil }
        let cached = (world?.observer as? SpriteRenderer)?.constraintEvaluations[id]
        return model.constraints.enumerated().map { index, rule in
            if !isActive || !model.isEnabled || !rule.isEnabled { return .disabled }
            return cached?.statuses.count == model.constraints.count ? cached!.statuses[index] : .notRendered
        }
    }
}
