@_spi(Backend) import ECSCore
import SpriteKit
import SwiftUI

/// The SpriteKit side of a ``World``: one `SKNode` per entity, kept in sync each frame.
///
/// Frame order:
/// 1. `update(_:)` runs the world's systems, then pushes changed components onto nodes,
///    turning changes made inside `withAnimation` into `SKAction`s.
/// 2. SpriteKit evaluates actions and simulates physics.
/// 3. `didSimulatePhysics()` copies simulation results back into ``Transform`` and
///    ``PhysicsBodyComponent`` without marking them changed, then publishes the step's
///    ``PhysicsEvents``.
/// 4. `didFinishUpdate()` moves cameras (see ``CameraComponent``) and flushes again.
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

    private var nodes: [Entity.ID: SKNode] = [:]
    /// Which entity each node shows, for mapping physics contacts back.
    private var entityIDs: [ObjectIdentifier: Entity.ID] = [:]
    /// Entities whose node has a physics body.
    private var bodies: Set<Entity.ID> = []
    /// Contacts reported during the current simulation step, published after it.
    private var contacts: [any Event] = []
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
    private var lastUpdateTime: TimeInterval?
    private var lastDeltaTime: TimeInterval = 0
    /// The time SpriteKit passed to the latest `update(_:)`.
    var lastFrameTime: TimeInterval? { lastUpdateTime }

    public init(world: World, size: CGSize = CGSize(width: 1, height: 1)) {
        self.world = world
        super.init(size: size)
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        scaleMode = .resizeFill
        backgroundColor = .black

        Self.registerComponents()
        register(Transform.self, Self.transformBinding)
        register(SpriteComponent.self, Self.spriteBinding)
        register(PhysicsBodyComponent.self, Self.physicsBinding)
        register(CameraComponent.self, Self.cameraBinding)
        register(TileMapComponent.self, Self.tileMapBinding)
        register(ParticleEmitterComponent.self, Self.particleBinding)
        register(AudioComponent.self, Self.audioBinding)
        physicsWorld.contactDelegate = self

        world.addSystem(LifetimeSystem.self)
        contactEffects = world.subscribe(to: PhysicsEvents.ContactBegan.self) { [weak self] contact in
            self?.addContactEffects(contact)
        }

        world.observer = self
        for entity in world.entities {
            entity.visit { self.world(world, didAdd: $0) }
        }
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("SpriteRenderer is created in code.")
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

    public override func update(_ currentTime: TimeInterval) {
        let deltaTime = lastUpdateTime.map { min(currentTime - $0, 1.0 / 15.0) } ?? 0
        lastUpdateTime = currentTime
        lastDeltaTime = deltaTime
        world.update(deltaTime: deltaTime)
        flush()
    }

    /// Moves cameras once physics and actions have run, so they frame where things ended up.
    public override func didFinishUpdate() {
        updateCameras(deltaTime: lastDeltaTime, time: lastUpdateTime ?? 0)
        flush()
    }

    /// Pushes every pending component change onto its node, then lets transactions
    /// that started no actions complete.
    public func flush() {
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
        binding.apply(value, old, node, animator)
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
        for id in bodies {
            guard let node = nodes[id], let body = node.physicsBody, body.isDynamic,
                  let entity = world.entity(withID: id)
            else { continue }
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
        publishContacts()
    }

    /// Publishes the queued contacts, skipping any whose entities have left the world.
    func publishContacts() {
        guard !contacts.isEmpty else { return }
        let reported = contacts
        contacts.removeAll()
        for event in reported {
            switch event {
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
              let a = world.entity(withID: idA), let b = world.entity(withID: idB)
        else { return }
        if began {
            contacts.append(PhysicsEvents.ContactBegan(
                entityA: a, entityB: b,
                point: [Float(point.x), Float(point.y)],
                normal: [Float(normal.dx), Float(normal.dy)],
                impulse: Float(impulse)
            ))
        } else {
            contacts.append(PhysicsEvents.ContactEnded(entityA: a, entityB: b))
        }
    }

    // MARK: Running actions (used by Animator)

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

            let imageChanged = old == nil || old?.imageName != sprite.imageName || old?.image != sprite.image
            if imageChanged {
                if let image = sprite.image {
                    spriteNode.texture = makeTexture(image)
                } else {
                    spriteNode.texture = sprite.imageName.map { SKTexture(imageNamed: $0) }
                }
            }
            if old?.anchorPoint != sprite.anchorPoint {
                spriteNode.anchorPoint = CGPoint(x: CGFloat(sprite.anchorPoint.x), y: CGFloat(sprite.anchorPoint.y))
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
    public func world(_ world: World, didAdd entity: Entity) {
        guard nodes[entity.id] == nil else { return }
        let node = SKNode()
        node.name = entity.name.isEmpty ? "entity-\(entity.id)" : entity.name
        nodes[entity.id] = node
        entityIDs[ObjectIdentifier(node)] = entity.id

        let parentNode: SKNode = entity.parent.flatMap { nodes[$0.id] } ?? self
        parentNode.addChild(node)

        // New nodes get every component set directly so nothing pops in a frame late
        // or animates in from the origin.
        for key in entity.componentKeys {
            apply(key, value: entity.component(forKey: key), of: entity, to: node, transaction: nil)
        }
    }

    public func world(_ world: World, willRemove entity: Entity) {
        dirty[entity.id] = nil
        applied[entity.id] = nil
        bodies.remove(entity.id)
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
        let key = ObjectIdentifier(componentType)
        let value = entity.component(forKey: key)
        if let last = dirty[entity.id]?[key]?.last, last.transaction === transaction {
            dirty[entity.id]![key]![dirty[entity.id]![key]!.count - 1].value = value
        } else {
            dirty[entity.id, default: [:]][key, default: []].append(Change(transaction: transaction, value: value))
        }
    }

    public func world(_ world: World, presentationValueOf componentType: any Component.Type, for entity: Entity) -> (any Component)? {
        let key = ObjectIdentifier(componentType)
        guard let present = bindings[key]?.present,
              let node = nodes[entity.id],
              let model = entity.component(forKey: key)
        else { return nil }
        return present(node, model)
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
