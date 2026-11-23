@_spi(Backend) import ECSCore
import SpriteKit
import SwiftUI

public enum RenderingEvents {
    /// Presented transforms are current, after actions, physics, constraints, cameras and the
    /// final component flush. Also delivered while simulation is paused.
    public struct DidUpdate: Event { public let scene: World }
}

/// The SpriteKit side of a ``World``: one `SKNode` per entity, kept in sync each frame.
///
/// Frame order:
/// 1. `update(_:)` runs update events and simulation systems, then pushes changed components onto nodes,
///    turning changes made inside `withAnimation` into `SKAction`s, then resolves joints after all bodies exist.
/// 2. SpriteKit evaluates actions and simulates physics.
/// 3. `didSimulatePhysics()` copies simulation results back into ``Transform`` and
///    ``PhysicsBodyComponent`` without marking them changed, then publishes the step's
///    ``PhysicsEvents``.
/// 4. `didFinishUpdate()` runs presentation systems, flushes their writes, evaluates
///    transform constraints, moves cameras (see ``CameraComponent``), and flushes again.
/// 5. SpriteKit renders.
///
/// Component changes are batched: they reach the nodes when ``flush()`` runs, not immediately.
@MainActor
public final class SpriteRenderer: SKScene {
    /// Shows one component type on a node.
    ///
    /// `apply` receives the new value (`nil` when the component was removed) and the value
    /// it last applied (`nil` the first time), so it can touch only what changed.
    /// `present` reads the value currently on screen, for `entity.presentation`.
    /// Visual bindings receive the entity's content container, which can be an
    /// identity crop wrapper when masked. Built-in transform/physics/camera bindings
    /// keep using the stable entity node returned by node(for:).
    public struct Binding<T: Component> {
        public var apply: @MainActor (_ new: T?, _ old: T?, _ node: SKNode, _ animator: Animator) -> Void
        public var present: (@MainActor (_ node: SKNode, _ model: T) -> T)?

        public init(
            apply: @escaping @MainActor (_ new: T?, _ old: T?, _ node: SKNode, _ animator: Animator) -> Void,
            present: (@MainActor (_ node: SKNode, _ model: T) -> T)? = nil
        ) {
            self.apply = apply
            self.present = present
        }
    }

    private struct AnyBinding {
        let apply: @MainActor (_ new: (any Component)?, _ old: (any Component)?, SKNode, Animator) -> Void
        let present: (@MainActor (SKNode, any Component) -> any Component)?
    }

    /// A component's value at the end of a run of changes made in one transaction.
    private struct Change {
        let transaction: ActionTransaction?
        var value: (any Component)?
    }

    private struct RunningAction {
        let token: Int
        let transaction: ActionTransaction?
    }

    public let world: World
    /// Ordered views into this scene. Empty retains the original full-view camera.
    /// Rectangles use normalized top-left coordinates; later views draw on top.
    /// The native multi-viewport host advances this scene once before drawing them.
    public var viewports: [GameViewport] = []
    var viewportRenderSurfaceSize: CGSize?
    private var viewportPhysicsSuspended = false
    var renderVisibilityOverrides: [ObjectIdentifier: VisibilityOverride] = [:]
    var activeRenderVisibilityMask: RenderLayer?
    var visibilityRevisions: [Entity.ID: UInt64] = [:]
    var nextVisibilityRevision: UInt64 = 0
    var knownVisibility: [Entity.ID: VisibilityComponent] = [:]
    var knownCameraVisibility: [Entity.ID: CameraVisibility] = [:]
    var backgroundPresentations: [BackgroundPresentation] = []
    var backgroundContext: BackgroundContext?
    var backgroundTiles: [Entity.ID: BackgroundTiles] = [:]
    var backgroundEntities: Set<Entity.ID> = []

    private var nodes: [Entity.ID: SKNode] = [:]
    /// Which entity each node shows, for mapping physics contacts back.
    private var entityIDs: [ObjectIdentifier: Entity.ID] = [:]
    /// Entities whose node has a physics body.
    var bodies: Set<Entity.ID> = []
    var jointEntries: [Entity.ID: PhysicsJointEntry] = [:]
    var jointStatuses: [Entity.ID: PhysicsJointStatus] = [:]
    var physicsShapes: [Entity.ID: PhysicsShapeConfiguration] = [:]
    var needsLightingRefresh = false
    var constraintEvaluations: [Entity.ID: TransformConstraintEvaluation] = [:]
    /// Contacts reported during the current simulation step, published after it.
    private struct QueuedContact {
        let event: any Event
        let a: Entity
        let b: Entity
        let revisionA: UInt64
        let revisionB: UInt64
    }
    private var contacts: [QueuedContact] = []
    /// Pending changes per entity and component type. A new entry starts whenever the
    /// transaction changes, so a nested `withAnimation(.disabled)` doesn't affect properties
    /// the outer animation changed.
    private var dirty: [Entity.ID: [ObjectIdentifier: [Change]]] = [:]
    private var bindings: [ObjectIdentifier: AnyBinding] = [:]
    /// The model values last pushed to each node.
    private var applied: [Entity.ID: [ObjectIdentifier: any Component]] = [:]
    private var running: [Entity.ID: [String: RunningAction]] = [:]
    /// Transactions whose actions were dropped outside a flush; ended at the next flush.
    private var droppedTransactions: [ActionTransaction] = []
    private var nextToken = 0
    /// Adds ``ContactEffectComponent`` effects as contacts are published.
    private var contactEffects: EventSubscription?
    var manipulationSessions: [UUID: ManipulationSession] = [:]
    var validatingManipulations = false
    var cancellingManipulations = false
    private var lastUpdateTime: TimeInterval?
    private var lastDeltaTime: TimeInterval = 0
    private var currentFrame: WorldFrame?
    private var simulationTime: TimeInterval = 0
    var attachedDebugController: SceneDebugController?
    var debugLayer: SKNode?
    var debugDrawNodes: [String: SKShapeNode] = [:]
    var debugPriorProfiling: Bool?
    var debugLastSampleTime: TimeInterval = -.infinity
    var debugFrameNumber: UInt64 = 0
    var debugSimulationFrameNumber: UInt64 = 0
    var debugFPS: Double = 0
    var pendingDebugStep = false
    var debugStepPrimed = false
    var steppingThisFrame = false

    public init(world: World, size: CGSize = CGSize(width: 1, height: 1)) {
        self.world = world
        super.init(size: size)
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        scaleMode = .resizeFill
        backgroundColor = .black

        Self.registerComponents()
        register(Transform.self, Self.transformBinding)
        register(SpriteComponent.self, Self.spriteBinding)
        register(TextComponent.self, Self.textBinding)
        register(ShapeComponent.self, Self.shapeBinding)
        register(MaskComponent.self, Self.maskBinding)
        register(LightComponent.self, Self.lightBinding)
        register(RenderGroupComponent.self, Self.renderGroupBinding)
        register(PhysicsBodyComponent.self, Self.physicsBinding)
        register(CollisionComponent.self, Self.collisionBinding)
        register(CameraComponent.self, Self.cameraBinding)
        register(TileMapComponent.self, Self.tileMapBinding)
        register(RepeatingBackgroundComponent.self, Self.repeatingBackgroundBinding)
        register(ParticleEmitterComponent.self, Self.particleBinding)
        register(AudioComponent.self, Self.audioBinding)
        physicsWorld.contactDelegate = self

        world.addSystem(LifetimeSystem.self)
        world.addSystem(PlaybackSystem.self)
        contactEffects = world.subscribe(to: PhysicsEvents.ContactBegan.self) { [weak self] contact in
            self?.addContactEffects(contact)
        }

        world.observer = self
        // Mirror the root too: its transform defines scene-space conversions,
        // and its node provides a single action clock for the entire hierarchy.
        self.world(world, didAdd: world.root)
        for entity in world.entities {
            entity.visit { self.world(world, didAdd: $0) }
        }
        worldSimulationDidChange(world)
        synchronizePhysicsJoints()
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("SpriteRenderer is created in code.")
    }

    isolated deinit {
        restoreRenderVisibility()
        if let currentFrame { world.cancelFrame(currentFrame) }
        if let prior = debugPriorProfiling { world.isProfilingEnabled = prior }
        attachedDebugController?.rendererWasDestroyed()
    }

    /// Teaches the renderer how to show a component type. Later registrations replace earlier ones.
    public func register<T: Component>(_ type: T.Type, _ binding: Binding<T>) {
        let apply = binding.apply
        var present: (@MainActor (SKNode, any Component) -> any Component)?
        if let typedPresent = binding.present {
            present = { node, model in typedPresent(node, model as! T) }
        }
        bindings[ObjectIdentifier(type)] = AnyBinding(
            apply: { new, old, node, animator in
                apply(new as? T, old as? T, node, animator)
            },
            present: present
        )
    }

    /// The node backing an entity. An escape hatch for things the ECS doesn't cover yet.
    public func node(for entity: Entity) -> SKNode? {
        nodes[entity.id]
    }

    // MARK: Frame loop

    /// Rebase the display clock when a viewport host resumes. Simulation time,
    /// action state and physics settings are preserved.
    @_spi(Backend) public func resetFrameClock() {
        lastUpdateTime = nil
        lastDeltaTime = 0
    }

    /// SpriteKit may step physics even when its timestamp is unchanged. A
    /// resumed viewport still delivers its zero-delta ECS/presentation frame,
    /// but keeps native bodies frozen until the next advancing clock tick.
    @_spi(Backend) public func withViewportPhysicsSuspended<T>(_ body: () -> T) -> T {
        let previous = viewportPhysicsSuspended
        viewportPhysicsSuspended = true
        worldSimulationDidChange(world)
        defer {
            viewportPhysicsSuspended = previous
            worldSimulationDidChange(world)
        }
        return body()
    }

    public override func update(_ currentTime: TimeInterval) {
        restoreRenderVisibility()
        let interval = lastUpdateTime.map { currentTime - $0 } ?? 0
        let deltaTime = min(interval, 1.0 / 15.0)
        lastUpdateTime = currentTime
        if pendingDebugStep && (!world.isPaused || !world.root.isActive) { cancelDebugStep() }
        let step = pendingDebugStep && world.isPaused && world.root.isActive && deltaTime.isFinite && deltaTime > 0
        if step && !debugStepPrimed {
            // SpriteKit rebases an action's clock on its first unpaused update.
            // Prime that clock at zero speed with physics frozen; the following
            // callback advances exactly one simulation/action/physics frame.
            debugStepPrimed = true
            worldSimulationDidChange(world)
            currentFrame = nil
        } else {
            currentFrame = world.beginFrame(deltaTime: deltaTime, debugStep: step)
        }
        steppingThisFrame = currentFrame?.isDebugStep == true
        if steppingThisFrame { pendingDebugStep = false; debugStepPrimed = false; worldSimulationDidChange(world) }
        lastDeltaTime = currentFrame?.deltaTime ?? 0
        simulationTime += lastDeltaTime
        recordDebugFrame(interval: interval, simulated: currentFrame != nil)
        flush()
    }

    /// Evaluates final constraints and cameras after actions, physics and presentation systems.
    public override func didFinishUpdate() {
        validateManipulations()
        if let currentFrame { world.finishFrame(currentFrame) }
        currentFrame = nil
        // Completions may enqueue more component writes or no-op transactions.
        // Drain them before capturing constraint input; bound reentrant user code.
        var passes = 0
        repeat { flush(); passes += 1 }
        while passes < 32 && (!dirty.isEmpty || !droppedTransactions.isEmpty || ActionTransaction.hasPendingSeals)
        let settled = dirty.isEmpty && droppedTransactions.isEmpty && !ActionTransaction.hasPendingSeals
        if steppingThisFrame || (!world.isPaused && world.timeScale > 0) {
            if settled {
                updateTransformConstraints(deltaTime: lastDeltaTime, allowPaused: steppingThisFrame)
                updateCameras(deltaTime: lastDeltaTime, time: simulationTime)
            } else {
                world.root.visit { entity in
                    if let component = entity.components[TransformConstraintComponent.self] {
                        constraintEvaluations[entity.id] = .init(statuses: component.constraints.map { _ in .pendingChanges })
                    }
                }
            }
        }
        flush()
        finishDebugFrame()
        world.publish(RenderingEvents.DidUpdate(scene: world))
        applyRenderVisibility(visibilityMask() ?? .all)
        applyBackgroundPresentation(camera: camera, size: size)
    }

    /// Constraints write only owned channels, keeping other animation targets and
    /// their native actions intact. Copy-back updates the binding cache too.
    func commitPresentedPose(_ pose: Transform, channels: Set<AnimationChannel>, entity: Entity) {
        guard let node = node(for: entity) else { return }
        var model = entity.transform
        var previous = applied[entity.id]?[Self.transformKey] as? Transform ?? model
        if channels.contains(.position) {
            model.translation = pose.translation; previous.translation = pose.translation
            node.position = CGPoint(x: CGFloat(pose.translation.x), y: CGFloat(pose.translation.y))
        }
        if channels.contains(.rotation) {
            model.rotation = pose.rotation; previous.rotation = pose.rotation; node.zRotation = CGFloat(pose.rotation)
        }
        entity._setWithoutNotifying(model)
        applied[entity.id, default: [:]][Self.transformKey] = previous
    }

    /// Pushes pending component changes, resolves body connections, then lets
    /// transactions that started no actions complete.
    public func flush() {
        restoreRenderVisibility()
        validateManipulations()
        if !dirty.isEmpty {
            let pending = dirty
            dirty.removeAll(keepingCapacity: true)
            for (id, types) in pending {
                guard let node = nodes[id], let entity = world.entity(withID: id) else { continue }
                for (type, changes) in types {
                    for change in changes {
                        apply(type, value: change.value, of: entity, to: node, transaction: change.transaction)
                    }
                }
            }
        }
        synchronizePhysicsJoints()
        refreshLightingIfNeeded()
        if !droppedTransactions.isEmpty {
            let dropped = droppedTransactions
            droppedTransactions.removeAll()
            for transaction in dropped { transaction.endAction() }
        }
        ActionTransaction.sealPending()
    }

    private func apply(_ type: ObjectIdentifier, value: (any Component)?, of entity: Entity, to node: SKNode, transaction: ActionTransaction?) {
        guard let binding = bindings[type] else { return }
        let animator = Animator(renderer: self, entityID: entity.id, transaction: transaction)
        let old = applied[entity.id]?[type]
        binding.apply(value, old, Self.bindingRoot(type, node: node), animator)
        applied[entity.id, default: [:]][type] = value
        if type == Self.physicsKey {
            if node.physicsBody != nil { bodies.insert(entity.id) } else { bodies.remove(entity.id) }
        }
    }

    // MARK: Physics

    private static let physicsKey = ObjectIdentifier(PhysicsBodyComponent.self)
    private static let transformKey = ObjectIdentifier(Transform.self)

    /// Copies each dynamic body's position, rotation and velocity back into its entity,
    /// then publishes the contacts the step reported.
    public override func didSimulatePhysics() {
        guard !viewportPhysicsSuspended else { contacts.removeAll(); return }
        guard world.isDebugStepping || (!world.isPaused && world.timeScale > 0) else { contacts.removeAll(); return }
        for id in bodies { copyPhysicsResult(id) }
        publishContacts()
    }

    private func copyPhysicsResult(_ id: Entity.ID) {
        guard let node = nodes[id], let body = node.physicsBody, body.isDynamic,
              let entity = world.entity(withID: id)
        else { return }
        // A change made during the step (say, by a contact handler) wins over the simulation.
        let pending = dirty[id]
        if pending?[Self.transformKey] == nil {
            var transform = entity.transform
            transform.translation = [Float(node.position.x), Float(node.position.y)]
            transform.rotation = Float(node.zRotation)
            if transform != entity.transform {
                entity._setWithoutNotifying(transform)
                applied[id, default: [:]][Self.transformKey] = transform
            }
        }
        if pending?[Self.physicsKey] == nil, var physics = entity.components[PhysicsBodyComponent.self] {
            physics.velocity = [Float(body.velocity.dx), Float(body.velocity.dy)]
            physics.angularVelocity = Float(body.angularVelocity)
            if physics != entity.components[PhysicsBodyComponent.self] {
                entity._setWithoutNotifying(physics)
                applied[id, default: [:]][Self.physicsKey] = physics
            }
        }
    }

    /// Publishes the queued contacts, skipping any whose entities have left the world.
    func publishContacts() {
        guard !contacts.isEmpty else { return }
        let reported = contacts
        contacts.removeAll()
        for contact in reported {
            guard contact.a.isActive, contact.b.isActive,
                  contact.a.activationRevision == contact.revisionA, contact.b.activationRevision == contact.revisionB else { continue }
            switch contact.event {
            case let began as PhysicsEvents.ContactBegan:
                guard began.entityA.world === world, began.entityB.world === world else { continue }
                world.publish(began, from: [began.entityA, began.entityB])
            case let ended as PhysicsEvents.ContactEnded:
                guard ended.entityA.world === world, ended.entityB.world === world else { continue }
                world.publish(ended, from: [ended.entityA, ended.entityB])
            default:
                break
            }
        }
    }

    /// Queues a contact between two nodes for publishing after the step.
    func reportContact(between nodeA: SKNode?, and nodeB: SKNode?, began: Bool,
                       point: CGPoint = .zero, normal: CGVector = .zero, impulse: CGFloat = 0) {
        guard let nodeA, let nodeB,
              let idA = entityIDs[ObjectIdentifier(nodeA)], let idB = entityIDs[ObjectIdentifier(nodeB)],
              let a = world.entity(withID: idA), let b = world.entity(withID: idB), a.isActive, b.isActive
        else { return }
        let event: any Event
        if began {
            event = PhysicsEvents.ContactBegan(
                entityA: a, entityB: b,
                point: [Float(point.x), Float(point.y)],
                normal: [Float(normal.dx), Float(normal.dy)],
                impulse: Float(impulse)
            )
        } else {
            event = PhysicsEvents.ContactEnded(entityA: a, entityB: b)
        }
        contacts.append(QueuedContact(event: event, a: a, b: b, revisionA: a.activationRevision, revisionB: b.activationRevision))
    }

    // MARK: Running actions (used by Animator)

    private static let animationKeys: [AnimationChannel: String] = [
        .position: "transform.position", .rotation: "transform.rotation",
        .scale: "transform.scale"
    ]
    func isAnimationControlled(_ key: String, entityID: Entity.ID) -> Bool {
        let opacity = VisualOpacityTarget.allCases.first { $0.key == key }
        guard let channel = opacity == nil ? Self.animationKeys.first(where: { $0.value == key })?.key : .opacity else { return false }
        return world.entity(withID: entityID)?.components[PlaybackStorage.self]?.controllers.contains {
            guard let animation = $0 as? AnimationPlaybackController else { return false }
            return !animation.isTerminal && animation.resource.channels.contains(channel)
                && (opacity == nil || animation.baseline.opacityTarget == opacity)
        } ?? false
    }
    func cancelAnimationActions(_ channels: Set<AnimationChannel>, for entity: Entity, opacityTarget: VisualOpacityTarget?) {
        guard let node = node(for: entity) else { return }
        for channel in channels {
            guard let key = channel == .opacity ? opacityTarget?.key : Self.animationKeys[channel] else { continue }
            let target = channel == .opacity ? opacityTarget.flatMap { Self.contentRoot(node).childNode(withName: $0.nodeName) } : node
            if let target { cancelAction(key, entityID: entity.id, node: target) }
        }
    }

    func runAction(_ action: SKAction, key: String, entityID: Entity.ID, node: SKNode, transaction: ActionTransaction, finite: Bool) {
        nextToken += 1
        let token = nextToken
        if finite {
            transaction.beginAction()
            node.run(.sequence([action, .run { [weak self] in
                self?.actionFinished(key, entityID: entityID, token: token)
            }]), withKey: key)
        } else {
            node.run(action, withKey: key)
        }
        running[entityID, default: [:]][key] = RunningAction(token: token, transaction: finite ? transaction : nil)
    }

    func cancelAction(_ key: String, entityID: Entity.ID, node: SKNode) {
        guard let previous = running[entityID]?.removeValue(forKey: key) else { return }
        node.removeAction(forKey: key)
        previous.transaction?.endAction()
    }

    private func actionFinished(_ key: String, entityID: Entity.ID, token: Int) {
        guard let current = running[entityID]?[key], current.token == token else { return }
        running[entityID]?[key] = nil
        current.transaction?.endAction()
    }

    // MARK: Built-in bindings

    static let transformBinding = Binding<Transform>(
        apply: { new, old, node, animator in
            let t = new ?? .identity
            let position = CGPoint(x: CGFloat(t.translation.x), y: CGFloat(t.translation.y))
            let rotation = CGFloat(t.rotation)
            let scale = (x: CGFloat(t.scale.x), y: CGFloat(t.scale.y))

            if old?.translation != t.translation {
                let start = node.position
                animator.update("transform.position", on: node,
                    to: { .move(to: position, duration: $0) },
                    from: { .move(to: start, duration: $0) },
                    set: { node.position = position })
            }
            if old?.rotation != t.rotation {
                let start = node.zRotation
                animator.update("transform.rotation", on: node,
                    to: { .rotate(toAngle: rotation, duration: $0, shortestUnitArc: false) },
                    from: { .rotate(toAngle: start, duration: $0, shortestUnitArc: false) },
                    set: { node.zRotation = rotation })
            }
            if old?.scale != t.scale {
                let start = (x: node.xScale, y: node.yScale)
                animator.update("transform.scale", on: node,
                    to: { .scaleX(to: scale.x, y: scale.y, duration: $0) },
                    from: { .scaleX(to: start.x, y: start.y, duration: $0) },
                    set: { node.xScale = scale.x; node.yScale = scale.y })
            }
            if old?.zPosition != t.zPosition {
                node.zPosition = CGFloat(t.zPosition)
            }
        },
        present: { node, model in
            var t = model
            t.translation = [Float(node.position.x), Float(node.position.y)]
            t.rotation = Float(node.zRotation)
            t.scale = [Float(node.xScale), Float(node.yScale)]
            return t
        }
    )

    static let spriteNodeName = "__sprite"
    static let spriteKeys = ["sprite.opacity", "sprite.size", "sprite.color"]

    static func makeTexture(_ image: SpriteImage) -> SKTexture? {
        let data = Data(image.pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let cgImage = CGImage(
                width: image.width, height: image.height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: image.smoothsScaling,
                intent: .defaultIntent
              )
        else { return nil }
        let texture = SKTexture(cgImage: cgImage)
        texture.filteringMode = image.smoothsScaling ? .linear : .nearest
        return texture
    }

    static let spriteBinding = Binding<SpriteComponent>(
        apply: { new, old, node, animator in
            let existing = node.childNode(withName: spriteNodeName) as? SKSpriteNode
            guard let sprite = new else {
                animator.renderer.removeBackgroundTiles(for: animator.entityID)
                if let existing {
                    for key in spriteKeys { animator.cancel(key, on: existing) }
                    existing.removeFromParent()
                }
                return
            }

            let spriteNode: SKSpriteNode
            var old = old
            if let existing {
                spriteNode = existing
            } else {
                spriteNode = SKSpriteNode()
                spriteNode.name = spriteNodeName
                node.addChild(spriteNode)
                old = nil   // a fresh node has none of the old values
            }

            let imageChanged = old == nil || old?.imageName != sprite.imageName || old?.image != sprite.image || old?.texture != sprite.texture
            if imageChanged {
                if let texture = sprite.texture {
                    spriteNode.texture = texture.nativeTexture
                } else if let image = sprite.image {
                    spriteNode.texture = makeTexture(image)
                } else {
                    spriteNode.texture = sprite.imageName.map { SKTexture(imageNamed: $0) }
                }
            }
            if old?.anchorPoint != sprite.anchorPoint {
                spriteNode.anchorPoint = CGPoint(x: CGFloat(sprite.anchorPoint.x), y: CGFloat(sprite.anchorPoint.y))
            }
            if sprite.material.apply(to: spriteNode, previous: old?.material,
                                     isActive: animator.renderer.world.entity(withID: animator.entityID)?.isActive ?? false) {
                animator.renderer.needsLightingRefresh = true
            }

            // A fresh sprite has nothing to animate from, so its first values are set directly.
            let animator = old == nil
                ? Animator(renderer: animator.renderer, entityID: animator.entityID, transaction: nil)
                : animator

            if old?.opacity != sprite.opacity {
                let alpha = CGFloat(sprite.opacity)
                let start = spriteNode.alpha
                animator.update("sprite.opacity", on: spriteNode,
                    to: { .fadeAlpha(to: alpha, duration: $0) },
                    from: { .fadeAlpha(to: start, duration: $0) },
                    set: { spriteNode.alpha = alpha })
            }
            if old?.color != sprite.color || old?.colorBlendFactor != sprite.colorBlendFactor {
                let color = SKColor(sprite.color)
                let blend = CGFloat(sprite.colorBlendFactor)
                let start = (spriteNode.color, spriteNode.colorBlendFactor)
                animator.update("sprite.color", on: spriteNode,
                    to: { .colorize(with: color, colorBlendFactor: blend, duration: $0) },
                    from: { .colorize(with: start.0, colorBlendFactor: start.1, duration: $0) },
                    set: { spriteNode.color = color; spriteNode.colorBlendFactor = blend })
            }
            let size = sprite.size.map { CGSize(width: CGFloat($0.x), height: CGFloat($0.y)) }
                ?? spriteNode.texture?.size()
            if let size, old?.size != sprite.size || imageChanged {
                let start = spriteNode.size
                animator.update("sprite.size", on: spriteNode,
                    to: { .resize(toWidth: size.width, height: size.height, duration: $0) },
                    from: { .resize(toWidth: start.width, height: start.height, duration: $0) },
                    set: { spriteNode.size = size })
            }
        },
        present: { node, model in
            guard let spriteNode = node.childNode(withName: spriteNodeName) as? SKSpriteNode else { return model }
            var sprite = model
            sprite.opacity = Float(spriteNode.alpha)
            sprite.colorBlendFactor = Float(spriteNode.colorBlendFactor)
            if model.size != nil {
                sprite.size = [Float(spriteNode.size.width), Float(spriteNode.size.height)]
            }
            return sprite
        }
    )
}

// MARK: - WorldObserver

extension SpriteRenderer: WorldObserver {
    public func worldWillPublishEvent(_ world: World) {
        restoreRenderVisibility()
    }

    public func worldSimulationDidChange(_ world: World) {
        restoreRenderVisibility()
        let priming = debugStepPrimed && pendingDebugStep && world.isPaused && world.root.isEnabledInHierarchy
        let paused = (!world.isDebugStepping && !priming && (world.isPaused || world.timeScale == 0)) || !world.root.isEnabledInHierarchy
        node(for: world.root)?.isPaused = paused
        let rate = priming ? 0 : world.isDebugStepping ? 1 : world.timeScale
        node(for: world.root)?.speed = CGFloat(rate)
        physicsWorld.speed = paused || viewportPhysicsSuspended ? 0 : CGFloat(rate)
        let gravity = world.physics.gravity
        physicsWorld.gravity = CGVector(dx: CGFloat(gravity.x), dy: CGFloat(gravity.y))
        chooseCamera()
    }

    public func world(_ world: World, activationDidChange entity: Entity) {
        restoreRenderVisibility()
        validateManipulations()
        guard let node = nodes[entity.id] else { return }
        if !entity.isActive {
            copyPhysicsResult(entity.id)
            removePhysicsJoints(involving: [entity.id])
        }
        node.isHidden = !entity.isEnabledInHierarchy
        node.isPaused = !entity.isEnabledInHierarchy || (entity === world.root && !world.isDebugStepping && (world.isPaused || world.timeScale == 0))
        synchronizeLightingActivation(entity, node: node)
        applyPhysics(entity.components[PhysicsBodyComponent.self], previous: nil, entity: entity, node: node)
        if entity === world.root { worldSimulationDidChange(world) }
        chooseCamera()
    }

    /// A pool release is a new use of the entity, not an ordinary pause. Cancel
    /// old actions without delivering their completion into a later lease.
    func resetPooledPresentation(_ root: Entity, preparing: Bool = true) {
        root.visit { entity in
            constraintEvaluations[entity.id] = nil
            guard let node = nodes[entity.id] else { return }
            let pending = dirty.removeValue(forKey: entity.id) ?? [:]
            for change in pending.values.flatMap({ $0 }) { change.transaction?.cancelCompletion() }
            if let actions = running.removeValue(forKey: entity.id) {
                for action in actions.values {
                    action.transaction?.cancelCompletion()
                    action.transaction?.endAction()
                }
            }
            @MainActor func clear(_ node: SKNode) {
                node.removeAllActions()
                if let crop = node as? MaskCropNode { clear(crop.artwork) }
                for child in node.children where entityIDs[ObjectIdentifier(child)] == nil { clear(child) }
            }
            // Do not clear descendant entity nodes here; each is processed below.
            node.removeAllActions()
            for child in node.children where entityIDs[ObjectIdentifier(child)] == nil { clear(child) }
            // Also remove retired streams whose component was removed while
            // particles were still fading (their reserved name is already nil).
            for child in Self.contentRoot(node).children where child is SKEmitterNode {
                child.removeFromParent()
            }
            let keys = Set(applied[entity.id]?.keys.map { $0 } ?? []).union(entity.componentKeys)
            applied[entity.id] = nil
            for key in keys {
                if !preparing && (key == ObjectIdentifier(AudioComponent.self) || key == ObjectIdentifier(ParticleEmitterComponent.self)) { continue }
                apply(key, value: entity.component(forKey: key), of: entity, to: node, transaction: nil)
            }
        }
    }

    public func worldActiveCamera(_ world: World) -> Entity? { activeCamera }

    public func world(_ world: World, didAdd entity: Entity) {
        restoreRenderVisibility()
        validateManipulations()
        guard nodes[entity.id] == nil else { return }
        // A stable backing node can opt into compositing later without replacing
        // physics bodies, entity references, hierarchy links, or running actions.
        let node = SKEffectNode()
        node.shouldEnableEffects = false
        node.shouldRasterize = false
        node.shouldCenterFilter = false
        node.name = entity.name.isEmpty ? "entity-\(entity.id)" : entity.name
        nodes[entity.id] = node
        entityIDs[ObjectIdentifier(node)] = entity.id

        let parentNode: SKNode = entity.parent.flatMap { nodes[$0.id] } ?? self
        Self.contentRoot(parentNode).addChild(node)
        node.isHidden = !entity.isEnabledInHierarchy
        node.isPaused = !entity.isEnabledInHierarchy

        // New nodes get every component set directly so nothing pops in a frame late
        // or animates in from the origin.
        for key in entity.componentKeys {
            apply(key, value: entity.component(forKey: key), of: entity, to: node, transaction: nil)
        }
        knownVisibility[entity.id] = entity.components[VisibilityComponent.self]
        knownCameraVisibility[entity.id] = entity.components[CameraComponent.self].map { .init(mask: $0.cullingMask, active: $0.isActive) }
        updateBackgroundMembership(entity)
    }

    public func world(_ world: World, willRemove entity: Entity) {
        restoreRenderVisibility()
        removeBackgroundTiles(for: entity.id)
        backgroundEntities.remove(entity.id)
        cancelManipulations(involving: entity)
        attachedDebugController?.removed(entity)
        // Cancellation handlers may edit components while the entity is still
        // attached. Clear policy caches after those callbacks, like dirty state.
        knownVisibility[entity.id] = nil
        knownCameraVisibility[entity.id] = nil
        visibilityRevisions[entity.id] = nil
        var subtree: Set<Entity.ID> = []
        entity.visit { subtree.insert($0.id) }
        removePhysicsJoints(involving: subtree)
        jointStatuses[entity.id] = nil
        constraintEvaluations[entity.id] = nil
        dirty[entity.id] = nil
        applied[entity.id] = nil
        bodies.remove(entity.id)
        physicsShapes[entity.id] = nil
        // Completions waiting on this entity's actions run at the next flush, not in the
        // middle of a removal.
        if let actions = running.removeValue(forKey: entity.id) {
            droppedTransactions.append(contentsOf: actions.values.compactMap(\.transaction))
        }
        if let node = nodes.removeValue(forKey: entity.id) {
            entityIDs[ObjectIdentifier(node)] = nil
            node.removeFromParent()
            if let camera, camera.inParentHierarchy(node) { chooseCamera() }
        }
    }

    public func world(
        _ world: World,
        entity: Entity,
        didChange componentType: any Component.Type,
        transaction: ActionTransaction?
    ) {
        restoreRenderVisibility()
        let key = ObjectIdentifier(componentType)
        if componentType == ParallaxComponent.self || componentType == RepeatingBackgroundComponent.self {
            updateBackgroundMembership(entity)
        }
        if componentType == TransformConstraintComponent.self { constraintEvaluations[entity.id] = nil }
        let value = entity.component(forKey: key)
        if let last = dirty[entity.id]?[key]?.last, last.transaction === transaction {
            dirty[entity.id]![key]![dirty[entity.id]![key]!.count - 1].value = value
        } else {
            dirty[entity.id, default: [:]][key, default: []].append(Change(transaction: transaction, value: value))
        }
        recordVisibilityChange(entity, type: componentType)
        validateManipulations()
    }

    public func world(_ world: World, presentationValueOf componentType: any Component.Type, for entity: Entity) -> (any Component)? {
        let key = ObjectIdentifier(componentType)
        guard let present = bindings[key]?.present,
              let node = nodes[entity.id],
              let model = entity.component(forKey: key)
        else { return nil }
        return present(Self.bindingRoot(key, node: node), model)
    }
}

// MARK: - SKPhysicsContactDelegate

// SpriteKit reports contacts on the main thread, during the simulation step.

extension SpriteRenderer: @preconcurrency SKPhysicsContactDelegate {
    public func didBegin(_ contact: SKPhysicsContact) {
        reportContact(between: contact.bodyA.node, and: contact.bodyB.node, began: true,
                      point: contact.contactPoint, normal: contact.contactNormal, impulse: contact.collisionImpulse)
    }

    public func didEnd(_ contact: SKPhysicsContact) {
        reportContact(between: contact.bodyA.node, and: contact.bodyB.node, began: false)
    }
}
