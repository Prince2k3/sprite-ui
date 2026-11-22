@_spi(Backend) import ECSCore
import Foundation
import SpriteKit

/// Makes an entity the camera: what's at its position shows in the middle of the view.
///
/// Put it on a top-level entity. Each frame, after physics, the renderer moves that
/// entity toward its ``target``, keeps the view inside ``bounds`` and applies shake.
/// Move the entity yourself when there's no target. With several cameras, the first
/// active one found is used. Without a camera the view centers on the origin, as before.
///
/// ```swift
/// let camera = Entity(name: "camera", components: CameraComponent(
///     target: .named("player"), zoom: 1.5, smoothing: 0.2,
///     bounds: .init(min: [-800, -400], max: [800, 400])
/// ))
/// content.add(camera)
/// camera.components[CameraComponent.self]?.shake(0.6)   // on a hard landing
/// ```
public struct CameraComponent: Component, Hashable, Codable, Sendable {
    /// What the camera follows.
    public enum Target: Hashable, Codable, Sendable {
        /// An entity, by ``Entity/id``.
        case entity(Entity.ID)
        /// The first entity with this name, searched each frame.
        case named(String)
    }

    /// The rectangle the view has to stay inside, in scene space.
    public struct Bounds: Hashable, Codable, Sendable {
        public var min: SIMD2<Float>
        public var max: SIMD2<Float>

        public init(min: SIMD2<Float>, max: SIMD2<Float>) {
            self.min = min
            self.max = max
        }

        public init(center: SIMD2<Float>, size: SIMD2<Float>) {
            self.init(min: center - size / 2, max: center + size / 2)
        }

        public var center: SIMD2<Float> { (min + max) / 2 }
        public var size: SIMD2<Float> { max - min }
    }

    public var target: Target?
    /// Added to the target's position, to look ahead of it or above it.
    public var offset: SIMD2<Float>
    /// How much bigger things look: 2 shows half as much of the scene, twice as large.
    /// Animates inside `withAnimation`.
    public var zoom: Float
    /// Roughly how many seconds the camera takes to catch up with its target.
    /// 0 locks onto it.
    public var smoothing: Float
    /// Keeps the view inside this rectangle. A view bigger than the bounds on an axis
    /// centers on them along it.
    public var bounds: Bounds?
    /// Whether this is the camera the view uses.
    public var isActive: Bool

    /// How much the view is shaking, from 0 to 1. Raise it with ``shake(_:)``.
    public var trauma: Float
    /// How much ``trauma`` drops each second.
    public var traumaDecay: Float
    /// How far, in points, the view moves at full trauma. Shake grows with trauma squared,
    /// so small bumps barely show.
    public var maxShake: Float

    public init(
        target: Target? = nil,
        offset: SIMD2<Float> = .zero,
        zoom: Float = 1,
        smoothing: Float = 0.15,
        bounds: Bounds? = nil,
        isActive: Bool = true,
        trauma: Float = 0,
        traumaDecay: Float = 1.5,
        maxShake: Float = 14
    ) {
        self.target = target
        self.offset = offset
        self.zoom = zoom
        self.smoothing = smoothing
        self.bounds = bounds
        self.isActive = isActive
        self.trauma = trauma
        self.traumaDecay = traumaDecay
        self.maxShake = maxShake
    }

    /// Adds to ``trauma``, up to 1.
    public mutating func shake(_ amount: Float) {
        trauma = Swift.min(1, Swift.max(0, trauma + amount))
    }

    // MARK: Math

    /// The part of the scene a view of `viewSize` shows at this zoom.
    public func visibleSize(in viewSize: SIMD2<Float>) -> SIMD2<Float> {
        viewSize / Swift.max(zoom, 1e-3)
    }

    /// The camera position nearest to `position` that keeps the view inside ``bounds``.
    public func clamped(_ position: SIMD2<Float>, viewSize: SIMD2<Float>) -> SIMD2<Float> {
        guard let bounds else { return position }
        let half = visibleSize(in: viewSize) / 2
        var result = position
        for axis in 0..<2 {
            let low = bounds.min[axis] + half[axis]
            let high = bounds.max[axis] - half[axis]
            result[axis] = low > high ? bounds.center[axis] : Swift.min(Swift.max(position[axis], low), high)
        }
        return result
    }

    /// Where the camera moves this frame, from `position` toward `goal` (`nil` stays put).
    /// The result stays inside ``bounds``.
    public func step(
        from position: SIMD2<Float>,
        toward goal: SIMD2<Float>?,
        viewSize: SIMD2<Float>,
        deltaTime: Float
    ) -> SIMD2<Float> {
        var next = position
        if let goal {
            let aim = goal + offset
            // Exponential smoothing: the same feel at any frame rate.
            let t = smoothing > 0 ? 1 - exp(-Swift.max(deltaTime, 0) / smoothing) : 1
            next = position + (aim - position) * t
        }
        return clamped(next, viewSize: viewSize)
    }

    /// How far the view is pushed off the camera's position at `time`, for this ``trauma``.
    /// Smooth over time, so it wobbles rather than jitters.
    public func shakeOffset(at time: Double) -> SIMD2<Float> {
        guard trauma > 0, maxShake > 0 else { return .zero }
        let t = Float(time.truncatingRemainder(dividingBy: 1000))
        let wobble = SIMD2<Float>(
            sin(t * 47) * 0.6 + sin(t * 83 + 1.3) * 0.4,
            sin(t * 53 + 2.1) * 0.6 + sin(t * 97 + 0.7) * 0.4
        )
        return wobble * (maxShake * trauma * trauma)
    }
}

// MARK: - Renderer support

extension SpriteRenderer {
    static let cameraNodeName = "__camera"
    static let cameraZoomKey = "camera.zoom"

    static let cameraBinding = Binding<CameraComponent>(
        apply: { new, old, node, animator in
            let existing = node.childNode(withName: cameraNodeName) as? SKCameraNode
            guard let camera = new else {
                if let existing {
                    animator.cancel(cameraZoomKey, on: existing)
                    existing.removeFromParent()
                }
                animator.renderer.chooseCamera()
                return
            }
            let cameraNode: SKCameraNode
            var old = old
            if let existing {
                cameraNode = existing
            } else {
                cameraNode = SKCameraNode()
                cameraNode.name = cameraNodeName
                node.addChild(cameraNode)
                old = nil
            }
            if old?.zoom != camera.zoom {
                let scale = CGFloat(1 / max(camera.zoom, 1e-3))
                let start = cameraNode.xScale
                let animator = old == nil
                    ? Animator(renderer: animator.renderer, entityID: animator.entityID, transaction: nil)
                    : animator
                animator.update(cameraZoomKey, on: cameraNode,
                    to: { .scale(to: scale, duration: $0) },
                    from: { .scale(to: start, duration: $0) },
                    set: { cameraNode.setScale(scale) })
            }
            if old?.isActive != camera.isActive {
                animator.renderer.chooseCamera()
            }
        },
        present: { node, model in
            guard let cameraNode = node.childNode(withName: cameraNodeName) else { return model }
            var camera = model
            camera.zoom = Float(1 / max(cameraNode.xScale, 1e-6))
            return camera
        }
    )

    /// The entity whose camera the view uses, if any.
    public var activeCamera: Entity? {
        cameraEntities().first { $0.components[CameraComponent.self]?.isActive == true && node(for: $0) != nil }
    }

    /// Points it the scene at the first active camera.
    func chooseCamera() {
        camera = cameraEntities().lazy
            .filter { $0.components[CameraComponent.self]?.isActive == true }
            .compactMap { self.node(for: $0)?.childNode(withName: Self.cameraNodeName) as? SKCameraNode }
            .first
    }

    private func cameraEntities() -> [Entity] {
        world.allEntities
            .filter { $0.components.has(CameraComponent.self) }
            .sorted { $0.id < $1.id }
    }

    /// Moves every camera toward its target, keeps it in bounds and applies shake.
    /// Runs after physics, so it follows where bodies ended up this frame.
    func updateCameras(deltaTime: TimeInterval, time: TimeInterval) {
        let viewSize = SIMD2(Float(size.width), Float(size.height))
        for entity in cameraEntities() {
            guard var camera = entity.components[CameraComponent.self] else { continue }
            let goal = camera.target.flatMap(target(of:))?.scenePosition
            let next = camera.step(from: entity.position, toward: goal, viewSize: viewSize, deltaTime: Float(deltaTime))
            if next != entity.position { entity.position = next }

            if camera.trauma > 0 {
                camera.trauma = max(0, camera.trauma - camera.traumaDecay * Float(deltaTime))
                entity.components.set(camera)
            }
            if let cameraNode = node(for: entity)?.childNode(withName: Self.cameraNodeName) {
                let shake = camera.shakeOffset(at: time)
                cameraNode.position = CGPoint(x: CGFloat(shake.x), y: CGFloat(shake.y))
            }
        }
    }

    private func target(of target: CameraComponent.Target) -> Entity? {
        switch target {
        case .entity(let id): world.entity(withID: id)
        case .named(let name): world.root.findEntity(named: name).flatMap { $0 === world.root ? nil : $0 }
        }
    }

    /// The scene-space point under a point in the view, taking the camera into account.
    /// View points have their origin at the top left, like SwiftUI's.
    public func scenePoint(fromView point: CGPoint) -> SIMD2<Float> {
        let viewSize = SIMD2(Float(size.width), Float(size.height))
        var local = SIMD2(Float(point.x), Float(point.y)) - viewSize / 2
        local.y = -local.y
        guard let entity = activeCamera, let camera = entity.components[CameraComponent.self] else { return local }
        let shake = camera.shakeOffset(at: lastFrameTime ?? 0)
        let zoom = presentation(of: entity)?.zoom ?? camera.zoom
        return entity.position + shake + local / max(zoom, 1e-3)
    }

    private func presentation(of entity: Entity) -> CameraComponent? {
        guard let model = entity.components[CameraComponent.self] else { return nil }
        return self.world(self.world, presentationValueOf: CameraComponent.self, for: entity) as? CameraComponent ?? model
    }
}
