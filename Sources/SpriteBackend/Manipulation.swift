@_spi(Backend) import ECSCore
import Foundation
import SpriteKit

/// A stable direct-manipulation capture. Samples are cumulative from the start,
/// not per-frame deltas. Keep the session for programmatic interaction and call
/// end or cancel when finished. GameView manages native gesture sessions itself.
@MainActor
public final class ManipulationSession {
    public let entity: Entity
    public let initialTransform: Transform
    public var isActive: Bool { active && renderer != nil }
    private weak var renderer: SpriteRenderer?
    private weak var world: World?
    private let id = UUID()
    private let configuration: ManipulationComponent
    private let operations: ManipulationComponent.Operations
    private let viewportID: String?
    private let initialPoint: SIMD2<Float>
    private let grab: SIMD2<Float>
    private let hit: Entity
    private let hitRevision: UInt64
    private let revision: UInt64
    private let ancestry: [Entity.ID]
    private let participants: [Entity.ID]
    private let participantRevisions: [Entity.ID: UInt64]
    private var expected: Transform
    private var active = true
    private var writing = false
    private var hasBegun = false
    private struct BodyLease {
        let entity: Entity
        let configuration: PhysicsBodyComponent
    }
    private var bodies: [BodyLease] = []

    fileprivate init?(entity: Entity, hit: Entity, at point: SIMD2<Float>, operations requested: ManipulationComponent.Operations, renderer: SpriteRenderer, inViewport viewportID: String?) {
        guard entity.world === renderer.world, entity !== renderer.world.root, entity.isActive, entity.isInputTarget,
              hit.world === renderer.world, hit.isActive, hit.isInputTarget,
              let configuration = entity.components[ManipulationComponent.self], configuration.isEnabled,
              !configuration.operations.intersection(requested).isEmpty,
              let node = renderer.node(for: entity), renderer.isVisible(entity, inViewport: viewportID),
              renderer.isVisible(hit, inViewport: viewportID),
              renderer.manipulationDriversAreAvailable(for: entity),
              !renderer.manipulationSessions.values.contains(where: {
                  $0.entity === entity || $0.entity.isDescendant(of: entity) || entity.isDescendant(of: $0.entity)
              }), point.x.isFinite, point.y.isFinite else { return nil }
        let initial = entity.presentation.transform
        guard configuration.constrained(initial, relativeTo: initial, operations: requested) != nil else { return nil }
        guard let inverse = renderer.displayedCollisionMatrix(for: node).inverted() else { return nil }
        let local = inverse.apply(to: point)
        guard local.x.isFinite, local.y.isFinite else { return nil }
        self.entity = entity; self.hit = hit; self.renderer = renderer; world = renderer.world
        self.viewportID = viewportID
        self.configuration = configuration; operations = configuration.operations.intersection(requested)
        initialTransform = initial; expected = entity.transform; initialPoint = point; grab = [Float(local.x), Float(local.y)]
        revision = entity.activationRevision; hitRevision = hit.activationRevision
        ancestry = Self.lineage(of: entity)
        var members: [Entity.ID] = []
        var leases: [BodyLease] = []
        var capturedRevisions: [Entity.ID: UInt64] = [:]
        entity.visit { item in
            members.append(item.id)
            capturedRevisions[item.id] = item.activationRevision
            if let body = item.components[PhysicsBodyComponent.self], body.isDynamic {
                leases.append(.init(entity: item, configuration: body))
            }
        }
        participants = members; participantRevisions = capturedRevisions; bodies = leases
    }

    fileprivate func start() -> Bool {
        guard let renderer else { return false }
        renderer.manipulationSessions[id] = self
        holdBodies()
        let channels: Set<AnimationChannel> = [.position, .rotation, .scale]
        for controller in entity.components[PlaybackStorage.self]?.controllers ?? [] {
            if let animation = controller as? AnimationPlaybackController, !animation.resource.channels.isDisjoint(with: channels) {
                animation.stop(reason: .replaced)
                guard validate() else { return false }
            }
        }
        guard validate() else { return false }
        renderer.cancelAnimationActions(channels, for: entity, opacityTarget: nil)
        guard validate() else { return false }
        world?.resetFixedTransformHistory(for: entity)
        expected = initialTransform
        writing = true
        withAnimation(.disabled) { entity.transform = initialTransform }
        writing = false
        guard validate() else { return false }
        renderer.flushForDisplayedPicking()
        guard validate() else { return false }
        holdBodies()
        hasBegun = true
        world?.publish(ManipulationEvents.Began(entity: entity, initialTransform: initialTransform, transform: entity.transform), from: entity)
        return validate()
    }

    /// Applies cumulative scene-space pointer displacement, parent-local rotation
    /// in counterclockwise radians, and a positive uniform scale multiplier. The
    /// grabbed point stays under the pointer when translation is enabled. Locks,
    /// snapping and bounds can deliberately keep that point away from the pointer.
    /// Invalid samples leave the capture and pose unchanged.
    @discardableResult
    public func update(translation: SIMD2<Float> = .zero, rotation: Float = 0, scale: Float = 1) -> Bool {
        guard translation.x.isFinite, translation.y.isFinite, rotation.isFinite, scale.isFinite, scale > 0,
              validate(), let renderer else { return false }
        var proposed = initialTransform
        if operations.contains(.rotation) { proposed.rotation += rotation }
        if operations.contains(.scale) { proposed.scale *= scale }
        guard var pose = configuration.constrained(proposed, relativeTo: initialTransform, operations: operations.subtracting(.translation)) else { return false }
        if operations.contains(.translation) {
            guard let node = renderer.node(for: entity) else { cancel(reason: .entityUnavailable); return false }
            let point = initialPoint + translation
            let parentMatrix = node.parent.map { renderer.displayedCollisionMatrix(for: $0) } ?? .identity
            guard let inverse = parentMatrix.inverted() else { cancel(reason: .hierarchyChanged); return false }
            let parentPoint = inverse.apply(to: point)
            guard parentPoint.x.isFinite, parentPoint.y.isFinite else { cancel(reason: .hierarchyChanged); return false }
            let offset = pose.matrix.apply(toDirection: grab)
            pose.translation = parentPoint - offset
        }
        guard let constrained = configuration.constrained(pose, relativeTo: initialTransform, operations: operations) else { return false }
        if constrained != expected {
            expected = constrained
            writing = true
            withAnimation(.disabled) { entity.transform = constrained }
            writing = false
            guard validate() else { return false }
            renderer.flushForDisplayedPicking()
            guard validate() else { return false }
            holdBodies()
            world?.publish(ManipulationEvents.Changed(entity: entity, initialTransform: initialTransform, transform: entity.transform), from: entity)
        }
        return validate()
    }

    /// Completes the capture, keeping its final pose and restoring physics.
    public func end() {
        guard validate() else { return }
        finish(reason: nil)
    }

    /// Cancels the capture, keeping its last committed pose and restoring physics.
    public func cancel() { cancel(reason: .inputCancelled) }

    fileprivate func cancel(reason: ManipulationEvents.CancellationReason) { finish(reason: reason) }

    @discardableResult
    func validate() -> Bool {
        guard isActive else { return false }
        if writing { return true }
        guard let renderer, let world, world.observer === renderer,
              entity.world === world, entity.isActive, entity.activationRevision == revision,
              hit.world === world, hit.isInputTarget, hit.activationRevision == hitRevision,
              renderer.isVisible(entity, inViewport: viewportID), renderer.isVisible(hit, inViewport: viewportID),
              hit.components[CollisionComponent.self]?.isEnabled != false else {
            cancel(reason: .entityUnavailable); return false
        }
        guard Self.lineage(of: entity) == ancestry else { cancel(reason: .hierarchyChanged); return false }
        var current: [Entity.ID] = []
        var sameActivations = true
        var dynamicBodies: Set<Entity.ID> = []
        entity.visit {
            current.append($0.id)
            if $0.components[PhysicsBodyComponent.self]?.isDynamic == true { dynamicBodies.insert($0.id) }
            if participantRevisions[$0.id] != $0.activationRevision { sameActivations = false }
        }
        guard sameActivations else { cancel(reason: .entityUnavailable); return false }
        guard current == participants else { cancel(reason: .hierarchyChanged); return false }
        guard entity.components[ManipulationComponent.self] == configuration,
              renderer.manipulationOwner(for: hit) === entity else { cancel(reason: .configurationChanged); return false }
        guard entity.transform == expected else { cancel(reason: .transformChanged); return false }
        guard renderer.manipulationDriversAreAvailable(for: entity),
              dynamicBodies == Set(bodies.map { $0.entity.id }),
              bodies.allSatisfy({ $0.entity.components[PhysicsBodyComponent.self] == $0.configuration }) else {
            cancel(reason: .physicsChanged); return false
        }
        return true
    }

    fileprivate func holdsBody(_ entity: Entity) -> Bool { isActive && bodies.contains { $0.entity === entity } }
    fileprivate func involves(_ other: Entity) -> Bool {
        entity === other || entity.isDescendant(of: other) || other.isDescendant(of: entity)
    }

    private func holdBodies() {
        guard let renderer, isActive else { return }
        for lease in bodies {
            let body = renderer.node(for: lease.entity)?.physicsBody
            body?.isDynamic = false; body?.velocity = .zero; body?.angularVelocity = 0
        }
    }

    private func finish(reason: ManipulationEvents.CancellationReason?) {
        guard active else { return }
        active = false
        let renderer = renderer
        renderer?.manipulationSessions[id] = nil
        for lease in bodies {
            guard var body = lease.entity.components[PhysicsBodyComponent.self] else { continue }
            if configuration.physicsRelease == .stop {
                if body.velocity == lease.configuration.velocity { body.velocity = .zero }
                if body.angularVelocity == lease.configuration.angularVelocity { body.angularVelocity = 0 }
            }
            if body != lease.entity.components[PhysicsBodyComponent.self] {
                withAnimation(.disabled) { lease.entity.components.set(body) }
            }
            if let renderer, lease.entity.world === renderer.world, let node = renderer.node(for: lease.entity) {
                renderer.applyPhysics(body, previous: nil, entity: lease.entity, node: node)
            }
        }
        if hasBegun, let world {
            if let reason {
                world.publish(ManipulationEvents.Cancelled(entity: entity, initialTransform: initialTransform, transform: entity.transform, reason: reason), from: entity)
            } else {
                world.publish(ManipulationEvents.Ended(entity: entity, initialTransform: initialTransform, transform: entity.transform), from: entity)
            }
        }
    }

    private static func lineage(of entity: Entity) -> [Entity.ID] {
        var result: [Entity.ID] = []
        var parent = entity.parent
        while let item = parent { result.append(item.id); parent = item.parent }
        return result
    }
}

extension SpriteRenderer {
    /// Picks the front-most input target and captures its nearest manipulation
    /// owner. A nonmanipulable foreground target does not click through.
    public func beginManipulation(at scenePoint: SIMD2<Float>, operations: ManipulationComponent.Operations = .all, inViewport viewportID: String? = nil) -> ManipulationSession? {
        guard scenePoint.x.isFinite, scenePoint.y.isFinite else { return nil }
        flushForDisplayedPicking()
        guard let hit = inputTarget(at: CGPoint(x: CGFloat(scenePoint.x), y: CGFloat(scenePoint.y)), inViewport: viewportID),
              let owner = manipulationOwner(for: hit) else { return nil }
        return beginManipulation(of: owner, hit: hit, at: scenePoint, operations: operations, inViewport: viewportID)
    }

    /// Starts a programmatic capture at a scene-space anchor on a known entity.
    /// It must be active and pickable, but this overload does not require a hit
    /// at the anchor. This supports accessible controls and custom input adapters.
    public func beginManipulation(of entity: Entity, at scenePoint: SIMD2<Float>, operations: ManipulationComponent.Operations = .all, inViewport viewportID: String? = nil) -> ManipulationSession? {
        flushForDisplayedPicking()
        return beginManipulation(of: entity, hit: entity, at: scenePoint, operations: operations, inViewport: viewportID)
    }

    private func beginManipulation(of entity: Entity, hit: Entity, at point: SIMD2<Float>, operations: ManipulationComponent.Operations, inViewport viewportID: String?) -> ManipulationSession? {
        guard !cancellingManipulations,
              let session = ManipulationSession(entity: entity, hit: hit, at: point, operations: operations, renderer: self, inViewport: viewportID), session.start() else { return nil }
        return session
    }

    func manipulationOwner(for hit: Entity) -> Entity? {
        var current: Entity? = hit
        while let entity = current {
            if let component = entity.components[ManipulationComponent.self] { return component.isEnabled ? entity : nil }
            current = entity.parent
        }
        return nil
    }

    /// Cancels all captures owned by this renderer, including programmatic ones.
    public func cancelManipulations() {
        guard !cancellingManipulations else { return }
        cancellingManipulations = true
        defer { cancellingManipulations = false }
        for session in Array(manipulationSessions.values) { session.cancel() }
    }
    func cancelManipulations(involving entity: Entity) {
        guard !cancellingManipulations else { return }
        cancellingManipulations = true
        defer { cancellingManipulations = false }
        for session in Array(manipulationSessions.values) where session.involves(entity) { session.cancel(reason: .entityUnavailable) }
    }
    func validateManipulations() {
        guard !validatingManipulations else { return }
        validatingManipulations = true
        defer { validatingManipulations = false }
        for session in Array(manipulationSessions.values) { session.validate() }
    }
    func isManipulationHoldingPhysics(_ entity: Entity) -> Bool {
        manipulationSessions.values.contains { $0.holdsBody(entity) }
    }
    func manipulationDriversAreAvailable(for root: Entity) -> Bool {
        var members: Set<Entity.ID> = [], valid = true
        root.visit { entity in
            members.insert(entity.id)
            if entity.components[CharacterControllerComponent.self]?.isEnabled == true { valid = false }
            if entity.components[TransformConstraintComponent.self]?.isEnabled == true { valid = false }
        }
        var ancestor = root.parent
        while let entity = ancestor {
            if entity.components[PhysicsBodyComponent.self]?.isDynamic == true { valid = false }
            ancestor = entity.parent
        }
        for entity in world.allEntities where entity.isActive {
            if let joint = entity.components[PhysicsJointComponent.self], joint.isEnabled,
               members.contains(joint.bodyA) || members.contains(joint.bodyB) { valid = false }
        }
        return valid
    }
}
