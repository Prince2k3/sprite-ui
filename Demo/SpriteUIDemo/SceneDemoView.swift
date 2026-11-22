import SpriteUI
import SwiftUI

/// The Scene loading milestone: `Level.sks` is a scene file like one laid out in
/// Xcode's scene editor (ledges, crates, coins and a spawn marker), loaded straight
/// into entities. Coins carry `coin` and `spin` keys in their User Data, which a
/// `SceneLoader` turns into components. Tap to drop a ball; balls that touch a coin collect it.
struct SceneDemoView: View {
    @State private var scene = LevelScene()
    @State private var size = CGSize(width: 400, height: 700)

    var body: some View {
        GameView { content in
            scene.build(in: content)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .gesture(SpatialTapGesture().onEnded { value in
            scene.drop(at: [
                Float(value.location.x - size.width / 2),
                Float(size.height / 2 - value.location.y),
            ])
        })
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

    /// Drops a ball at a point in the view, centered on the origin.
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
            contactTestBitMask: Self.coinCategory
        ))
        balls.append(ball)
        world?.addEntity(ball)
        updateSummary()
    }

    func clearBalls() {
        for ball in balls { world?.removeEntity(ball) }
        balls.removeAll()
        updateSummary()
    }

    // MARK: Private

    private func contact(_ contact: PhysicsEvents.ContactBegan) {
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
