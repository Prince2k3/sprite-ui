import SpriteUI
import SwiftUI

struct PoolingDemoView: View {
    @State private var scene = PoolingDemoScene()
    var body: some View {
        VStack(spacing: 12) {
            GameView { scene.build(in: $0) }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { scene.resize($0) }
                .gesture(SpatialTapGesture().targetedToEntity(where: .has(PooledShot.self)).onEnded { scene.recycle($0.entity) })
                .overlay(alignment: .top) {
                    Text(scene.summary).font(.caption.monospaced()).multilineTextAlignment(.center)
                        .padding(8).background(.ultraThinMaterial, in: Capsule())
                }
            VStack(spacing: 10) {
                HStack {
                    Button("Fire 8") { scene.fireBurst() }
                    Toggle("Auto", isOn: $scene.automatic).toggleStyle(.button)
                    Toggle("Pool enabled", isOn: $scene.enabled).toggleStyle(.button)
                }
                HStack {
                    Button("Recycle all") { scene.recycleAll() }
                    Toggle("Tails", isOn: $scene.tails).toggleStyle(.button)
                    Button("Reset") { scene.reset() }
                }
                Text("Tap a shot to recycle it. Shots expire after 5 seconds. Disabling the pool suspends every shot; allocated IDs are reused.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.buttonStyle(.bordered).font(.footnote).padding(.horizontal)
        }.padding(.vertical).background(.black).preferredColorScheme(.dark).tint(.orange)
            .onChange(of: scene.enabled) { scene.applyEnabled() }
            .onChange(of: scene.tails) { scene.applyTails() }
    }
}

private struct PooledShot: Component { var remaining: Float = 5 }
private struct PoolingRuntime: Component {
    weak var scene: PoolingDemoScene?
    func cloned() -> Self? { nil }
}
private struct PoolingDemoSystem: System {
    init(world: World) {}
    mutating func update(context: UpdateContext) {
        context.world.resources[PoolingRuntime.self]?.scene?.step(Float(context.deltaTime))
    }
}

@MainActor @Observable private final class PoolingDemoScene {
    var summary = "Preparing projectile pool"
    var automatic = false
    var enabled = true
    var tails = true
    @ObservationIgnored private var pool: EntityPool?
    @ObservationIgnored private var world: World?
    @ObservationIgnored private var camera: Entity?
    @ObservationIgnored private var elapsed: Float = 0
    @ObservationIgnored private var seen: Set<Entity.ID> = []
    @ObservationIgnored private var shots = 0
    @ObservationIgnored private var reuseCount = 0
    @ObservationIgnored private var lastID: Entity.ID?
    @ObservationIgnored private var viewport = CGSize(width: 380, height: 500)

    func build(in content: GameViewContent) {
        let world = content.scene; self.world = world
        world.physics.gravity = [0, -1.4]
        world.resources.set(PoolingRuntime(scene: self)); world.addSystem(PoolingDemoSystem.self)
        let camera = Entity(name: "pool-camera", components: CameraComponent(smoothing: 0))
        content.add(camera); self.camera = camera; resize(viewport)
        let room = Entity(name: "room", components: PhysicsBodyComponent(shape: .edgeLoop(rectangle: [340, 410])))
        content.add(room)
        for (position, size) in [(SIMD2<Float>(0, -200), SIMD2<Float>(340, 8)), ([-166, 0], [8, 410]), ([166, 0], [8, 410])] {
            let wall = Entity(components: SpriteComponent(color: .gray.opacity(0.5), size: size)); wall.position = position; content.add(wall)
        }
        for x: Float in [-90, 0, 90] {
            let peg = Entity(components: SpriteComponent(image: .disc(diameter: 32), size: [32, 32], tint: .gray, tintAmount: 1),
                             PhysicsBodyComponent(shape: .circle(radius: 16), isDynamic: false))
            peg.position = [x, -20]; content.add(peg)
        }
        let template = Entity(name: "shot", components: PooledShot(), InputTargetComponent(),
                              SpriteComponent(image: .disc(diameter: 24), size: [24, 24], tint: .orange, tintAmount: 1),
                              PhysicsBodyComponent(shape: .circle(radius: 12), mass: 1, restitution: 0.8, linearDamping: 0.1))
        let tail = Entity(name: "tail", components: SpriteComponent(color: .white.opacity(0.5), size: [15, 4]))
        tail.position = [-16, 0]; template.addChild(tail)
        do {
            pool = try EntityPool(prefab: PrefabResource(root: template), scene: world, capacity: 12, prewarm: 4,
                onAcquire: { entity in
                    entity.transform = .identity; entity.components.set(PooledShot())
                    entity.components[PhysicsBodyComponent.self]?.angularVelocity = 0
                }, onRelease: { entity in
                    entity.components[PhysicsBodyComponent.self]?.velocity = .zero
                    entity.components[PhysicsBodyComponent.self]?.angularVelocity = 0
                })
            applyEnabled(); fireBurst()
        } catch { summary = "Pool error: \(error)" }
    }
    func resize(_ size: CGSize) {
        viewport = size
        if size.width > 0 && size.height > 0 { camera?.components[CameraComponent.self]?.zoom = Float(min(size.width / 370, size.height / 470)) }
    }
    func fireBurst() { for _ in 0..<8 { fire() }; refresh() }
    private func fire() {
        guard let pool, enabled else { return }
        do {
            let index = shots
            guard let entity = try pool.acquire(configure: { entity in
                entity.position = [Float(index % 5 - 2) * 40, 155]
                entity.components[PhysicsBodyComponent.self]?.velocity = [Float(index % 7 - 3) * 30, 60]
                let colors: [Color] = [.orange, .mint, .pink, .cyan, .yellow]
                entity.components[SpriteComponent.self]?.color = colors[Int(entity.id % 5)]
                entity.findEntity(named: "tail")?.isEnabled = self.tails
            }) else { return }
            if !seen.insert(entity.id).inserted { reuseCount += 1 }
            shots += 1; lastID = entity.id
        } catch { summary = "Pool error: \(error)" }
    }
    func recycle(_ entity: Entity) {
        do { try pool?.release(entity); refresh() }
        catch { summary = "Pool error: \(error)" }
    }
    func recycleAll() { for entity in pool?.leasedEntities ?? [] { recycle(entity) }; refresh() }
    func reset() {
        do { try pool?.removeAll(); seen = []; shots = 0; reuseCount = 0; lastID = nil; refresh() }
        catch { summary = "Pool error: \(error)" }
    }
    func applyEnabled() { pool?.container.isEnabled = enabled; refresh() }
    func applyTails() {
        for entity in pool?.container.children ?? [] { entity.findEntity(named: "tail")?.isEnabled = tails }
    }
    func step(_ delta: Float) {
        guard let world else { return }
        for entity in world.performQuery(EntityQuery(where: .has(PooledShot.self))) {
            entity.components[PooledShot.self]?.remaining -= delta
            if (entity.components[PooledShot.self]?.remaining ?? 0) <= 0 { recycle(entity) }
        }
        if automatic && enabled {
            elapsed += delta
            if elapsed >= 0.4 { elapsed = 0; fire() }
        }
        refresh()
    }
    private func refresh() {
        guard let pool else { return }
        let status = enabled ? "\(pool.leasedCount) in use" : "\(pool.leasedCount) suspended"
        let text = "\(pool.totalCount)/12 allocated · \(status) · \(pool.availableCount) ready\n\(shots) shots · \(reuseCount) reused · latest #\(lastID.map(String.init) ?? "—")"
        if summary != text { summary = text }
    }
}
