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
///
/// The Particles and audio milestone: each ball has a `ContactEffectComponent`, so a hard
/// hit throws sparks and thuds, more the harder it lands. A collected coin bursts into
/// gold sparks with a chime, and the ball the camera follows trails smoke.
///
/// The Save and load milestone: Save writes a snapshot of the world (the level, the
/// balls in flight with their velocities, the camera and the score) to a JSON file in
/// Documents, and Load puts it all back, even after the app is relaunched.
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
            VStack {
                HStack {
                    Button("Save") { scene.save() }
                    Button("Load") { scene.load() }
                        .disabled(!scene.hasSave)
                }
                HStack {
                    Button("Spawn") { scene.dropAtSpawn() }
                    Button("Fit") { scene.fit() }
                    Button("Reload") { scene.reload() }
                    Button("Clear") { scene.clearBalls() }
                }
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .font(.footnote)
            .padding(.bottom, 40)
        }
        .overlay(alignment: .top) {
            if let message = scene.message {
                Text(message)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.top, 36)
            }
        }
        .background(scene.background)
        .preferredColorScheme(.dark)
    }
}

// MARK: Components from User Data

/// Made from a node's `coin` User Data: how many points it's worth.
struct CoinComponent: Component, Codable {
    var points: Int
}

/// Made from a node's `spin` User Data: radians per second.
struct SpinComponent: Component, Codable {
    var speed: Float
}

/// The score so far, kept on the level so it's saved with it.
struct ScoreComponent: Component, Codable {
    var points: Int
}

// MARK: Scene

@MainActor
@Observable
final class LevelScene {
    private static let solidCategory: UInt32 = 1 << 0
    private static let coinCategory: UInt32 = 1 << 2
    private static let ballCategory: UInt32 = 1 << 3
    private static let thud = AudioComponent(named: "thud", volume: 0.8)
    private static let chime = AudioComponent(named: "coin", volume: 0.6)

    private(set) var summary = "loading"
    private(set) var background = Color.black
    /// What the last save or load did.
    private(set) var message: String?
    private(set) var hasSave = FileManager.default.fileExists(atPath: LevelScene.saveURL.path)

    /// Where Save writes the world.
    static let saveURL = URL.documentsDirectory.appending(path: "level-save.json")

    @ObservationIgnored private var world: World?
    @ObservationIgnored private var renderer: SpriteRenderer?
    @ObservationIgnored private var camera: Entity?
    @ObservationIgnored private var level: Entity?
    @ObservationIgnored private var balls: [Entity] = []
    @ObservationIgnored private var subscriptions: [EventSubscription] = []
    @ObservationIgnored private var generator = SeededGenerator(seed: 11)

    private static let disc = SpriteImage.disc(diameter: 64)
    private static let colors: [Color] = [.mint, .pink, .orange, .teal, .purple]

    /// Turns the editor's User Data into game components.
    private static let loader: SceneLoader = {
        var loader = SceneLoader()
        loader.register("coin") { $0.int.map(CoinComponent.init(points:)) }
        loader.register("spin") { $0.float.map(SpinComponent.init(speed:)) }
        return loader
    }()

    func build(in content: GameViewContent) {
        // Lets snapshots save the game's own components.
        CoinComponent.registerComponent(named: "coin")
        SpinComponent.registerComponent(named: "spin")
        ScoreComponent.registerComponent(named: "score")
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
        do {
            let level = try Self.loader.load(named: "Level")
            if let scene = level.components[SceneComponent.self] { background = scene.backgroundColor }
            world?.addEntity(level)
            self.level = level
            level.components.set(ScoreComponent(points: 0))
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
        addEffects(to: ball, color: Self.colors[balls.count % Self.colors.count])
        // Only the ball being followed trails smoke.
        balls.last?.components[ParticleEmitterComponent.self] = nil
        ball.components.set(ParticleEmitterComponent.smoke(color: .white.opacity(0.5)))
        balls.append(ball)
        world?.addEntity(ball)
        camera?.components[CameraComponent.self]?.target = .entity(ball.id)
        updateSummary()
    }

    // MARK: Save and load

    /// Writes the whole world to ``saveURL``, leaving out sparks that are about to vanish.
    func save() {
        guard let world else { return }
        do {
            let snapshot = world.snapshot(including: { $0.name != "one-shot" })
            try snapshot.write(to: Self.saveURL)
            hasSave = true
            let size = (try? Self.saveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            message = "saved \(snapshot.entityCount) entities · \(size / 1024) KB · \(points) pts"
        } catch {
            message = "couldn't save: \(error.localizedDescription)"
        }
    }

    /// Replaces the world with the last save. Balls keep flying the way they were, and the
    /// camera still follows the same one, because restored entities keep their IDs.
    func load() {
        guard let world else { return }
        do {
            let snapshot = try WorldSnapshot(contentsOf: Self.saveURL)
            world.restore(snapshot)
            camera = world.entities.first { $0.name == "camera" }
            level = world.entities.first { $0.components.has(SceneComponent.self) }
            balls = world.entities.filter { $0.name == "ball" }
            // Effects aren't saved: put the sparks and the smoke trail back.
            let followed: Entity.ID? = if case .entity(let id) = camera?.components[CameraComponent.self]?.target { id } else { nil }
            for (index, ball) in balls.enumerated() {
                addEffects(to: ball, color: Self.colors[index % Self.colors.count])
                if ball.id == followed {
                    ball.components.set(ParticleEmitterComponent.smoke(color: .white.opacity(0.5)))
                }
            }
            message = "loaded \(snapshot.entityCount) entities · \(points) pts"
            updateSummary()
        } catch {
            message = "couldn't load: \(error.localizedDescription)"
        }
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

    private var points: Int {
        get { level?.components[ScoreComponent.self]?.points ?? 0 }
        set { level?.components[ScoreComponent.self]?.points = newValue }
    }

    private func addEffects(to ball: Entity, color: Color) {
        ball.components.set(ContactEffectComponent(
            particles: .sparks(color: color), count: 14, sound: Self.thud, minimumImpulse: 3
        ))
    }

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
        world?.addEntity(.oneShot(particles: .sparks(color: .yellow), count: 30,
                                  sound: Self.chime, at: coin.scenePosition))
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
