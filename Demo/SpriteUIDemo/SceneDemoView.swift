import SpriteUI
import SwiftUI

/// The Scene loading and Camera milestones: `Level.sks` is a scene file like one laid
/// out in Xcode's scene editor (ramps, pegs, crates, coins and a spawn marker), loaded
/// straight into entities. Coins carry `coin` and `spin` keys in their User Data, which a
/// `SceneLoader` turns into components.
///
/// The level is several screens big, so a `CameraComponent` follows the newest ball,
/// stays inside the level and shakes on hard hits. Tap to drop a ball, drag to look
/// around, pinch to zoom.
struct SceneDemoView: View {
    @State private var scene = LevelScene()
    @State private var pinchStart: Float?
    @State private var lastDrag: CGSize = .zero

    var body: some View {
        GameView { content in
            scene.build(in: content)
        }
        .gesture(SpatialTapGesture().onEnded { value in
            scene.drop(atView: value.location)
        })
        .simultaneousGesture(DragGesture(minimumDistance: 12)
            .onChanged { value in
                let delta = CGSize(width: value.translation.width - lastDrag.width,
                                   height: value.translation.height - lastDrag.height)
                lastDrag = value.translation
                scene.pan(by: delta)
            }
            .onEnded { _ in lastDrag = .zero })
        .simultaneousGesture(MagnifyGesture()
            .onChanged { value in
                if pinchStart == nil { pinchStart = scene.zoom }
                scene.zoom = (pinchStart ?? 1) * Float(value.magnification)
            }
            .onEnded { _ in pinchStart = nil })
        .overlay(alignment: .top) {
            Text(scene.summary)
                .font(.caption.bold().monospacedDigit())
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.ultraThinMaterial, in: .capsule)
                .padding(.top, 8)
        }
        .overlay(alignment: .bottom) {
            HStack {
                Button("Spawn") { scene.dropAtSpawn() }
                Button("Fit") { scene.fit() }
                Button("Reload") { scene.reload() }
                Button("Clear") { scene.clearBalls() }
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .font(.footnote)
            .padding(.bottom, 40)
        }
        .background(scene.background)
        .preferredColorScheme(.dark)
    }
}

// MARK: Components from User Data

/// Made from a node's `coin` User Data: how many points it's worth.
struct CoinComponent: Component {
    var points: Int
}

/// Made from a node's `spin` User Data: radians per second.
struct SpinComponent: Component {
    var speed: Float
}

// MARK: Scene

@MainActor
@Observable
final class LevelScene {
    private static let solidCategory: UInt32 = 1 << 0
    private static let coinCategory: UInt32 = 1 << 2
    private static let ballCategory: UInt32 = 1 << 3

    private(set) var summary = "loading"
    private(set) var background = Color.black

    @ObservationIgnored private var world: World?
    @ObservationIgnored private var renderer: SpriteRenderer?
    @ObservationIgnored private var camera: Entity?
    @ObservationIgnored private var level: Entity?
    @ObservationIgnored private var balls: [Entity] = []
    @ObservationIgnored private var points = 0
    @ObservationIgnored private var subscriptions: [EventSubscription] = []
    @ObservationIgnored private var generator = SeededGenerator(seed: 11)

    private static let disc = SpriteImage.disc(diameter: 64)
    private static let colors: [Color] = [.mint, .pink, .orange, .teal, .purple]

    /// Turns the editor's User Data into game components, the way `GKScene` adds
    /// the `GKComponent`s set on a node.
    private static let loader: SceneLoader = {
        var loader = SceneLoader()
        loader.register("coin") { $0.int.map(CoinComponent.init(points:)) }
        loader.register("spin") { $0.float.map(SpinComponent.init(speed:)) }
        return loader
    }()

    func build(in content: GameViewContent) {
        world = content.world
        renderer = content.renderer
        let camera = Entity(name: "camera", components: CameraComponent(zoom: 1, smoothing: 0.25, maxShake: 18))
        content.add(camera)
        self.camera = camera
        subscriptions.append(content.world.subscribe(to: PhysicsEvents.ContactBegan.self) { [weak self] contact in
            self?.contact(contact)
        })
        subscriptions.append(content.world.subscribe(to: WorldEvents.Update.self) { [weak self] update in
            self?.spin(Float(update.deltaTime))
        })
        reload()
    }

    /// Loads `Level.sks` again, putting every coin and crate back.
    func reload() {
        if let level { world?.removeEntity(level) }
        clearBalls()
        points = 0
        do {
            let level = try Self.loader.load(named: "Level")
            if let scene = level.components[SceneComponent.self] { background = scene.backgroundColor }
            world?.addEntity(level)
            self.level = level
            if let scene = level.components[SceneComponent.self] {
                // A loaded scene is centered on the origin, whatever its anchor point.
                camera?.components[CameraComponent.self]?.bounds = .init(center: .zero, size: scene.size)
            }
            if let spawn = level.findEntity(named: "spawn") { camera?.position = level.position + spawn.position }
        } catch {
            level = nil
            summary = "couldn't load Level.sks: \(error)"
            return
        }
        updateSummary()
    }

    /// Drops a ball at the `spawn` marker placed in the editor.
    func dropAtSpawn() {
        guard let level, let spawn = level.findEntity(named: "spawn") else { return }
        drop(at: level.position + spawn.position + [Float.random(in: -10...10, using: &generator), 0])
    }

    /// Drops a ball under a point in the view, wherever the camera is looking.
    func drop(atView point: CGPoint) {
        guard let renderer else { return }
        drop(at: renderer.scenePoint(fromView: point))
    }

    /// Drops a ball at a point in the scene and has the camera follow it.
    func drop(at point: SIMD2<Float>) {
        let radius = Float.random(in: 8...12, using: &generator)
        let ball = Entity(name: "ball")
        ball.position = point
        ball.components.set(SpriteComponent(
            image: Self.disc, size: [radius * 2, radius * 2],
            tint: Self.colors[balls.count % Self.colors.count], tintAmount: 1
        ))
        ball.components.set(PhysicsBodyComponent(
            shape: .circle(radius: radius), restitution: 0.5,
            categoryBitMask: Self.ballCategory,
            collisionBitMask: ~Self.coinCategory,
            contactTestBitMask: Self.coinCategory | Self.solidCategory
        ))
        balls.append(ball)
        world?.addEntity(ball)
        camera?.components[CameraComponent.self]?.target = .entity(ball.id)
        updateSummary()
    }

    /// How much the camera magnifies, kept between showing most of the level and 3×.
    var zoom: Float {
        get { camera?.components[CameraComponent.self]?.zoom ?? 1 }
        set { camera?.components[CameraComponent.self]?.zoom = min(max(newValue, 0.3), 3) }
    }

    /// Moves the view with a drag, which stops following a ball.
    func pan(by translation: CGSize) {
        guard let camera, var component = camera.components[CameraComponent.self] else { return }
        component.target = nil
        camera.components.set(component)
        camera.position -= SIMD2(Float(translation.width), -Float(translation.height)) / component.zoom
    }

    /// Zooms out to show the whole level.
    func fit() {
        guard let camera, let bounds = camera.components[CameraComponent.self]?.bounds,
              let renderer else { return }
        let view = SIMD2(Float(renderer.size.width), Float(renderer.size.height))
        let fit = view / bounds.size
        withAnimation(.easeInOut(duration: 0.6)) {
            zoom = min(fit.x, fit.y)
        }
        camera.components[CameraComponent.self]?.target = nil
        camera.position = bounds.center
    }

    func clearBalls() {
        for ball in balls { world?.removeEntity(ball) }
        balls.removeAll()
        updateSummary()
    }

    // MARK: Private

    private func contact(_ contact: PhysicsEvents.ContactBegan) {
        // A hard landing shakes the view, more the harder it hit.
        if contact.impulse > 4 {
            camera?.components[CameraComponent.self]?.shake(min(contact.impulse / 40, 0.6))
        }
        guard let coin = [contact.entityA, contact.entityB].first(where: { $0.components.has(CoinComponent.self) }),
              let value = coin.components[CoinComponent.self]?.points
        else { return }
        // Only count it once, even if two balls touch it in the same step.
        coin.components[CoinComponent.self] = nil
        points += value
        withAnimation(.easeOut(duration: 0.25)) {
            coin.components[SpriteComponent.self]?.opacity = 0
            coin.transform.scale = [2, 2]
        } completion: { [weak self] in
            coin.removeFromParent()
            self?.updateSummary()
        }
        updateSummary()
    }

    private func spin(_ deltaTime: Float) {
        level?.visit { entity in
            guard let spin = entity.components[SpinComponent.self] else { return }
            entity.transform.rotation += spin.speed * deltaTime
        }
    }

    private func updateSummary() {
        guard let level else { return }
        var entities = 0, coins = 0
        level.visit { entity in
            entities += 1
            if entity.components.has(CoinComponent.self) { coins += 1 }
        }
        let text = "\(entities) entities from Level.sks · \(coins) coins left · \(points) pts · \(balls.count) balls"
        if text != summary { summary = text }
    }
}
