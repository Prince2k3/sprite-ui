import SpriteUI
import SwiftUI
import simd

struct PrefabDemoView: View {
    @State private var scene = PrefabDemoScene()
    var body: some View {
        VStack(spacing: 12) {
            GameView { scene.build(in: $0) }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { scene.resize($0) }
                .gesture(SpatialTapGesture().targetedToEntity(where: .has(PrefabInstance.self)).onEnded { scene.select($0.entity) })
                .overlay(alignment: .top) {
                    Text(scene.summary).font(.caption.monospaced()).multilineTextAlignment(.center)
                        .padding(8).background(.ultraThinMaterial, in: Capsule())
                }
            VStack(spacing: 10) {
                HStack {
                    Button("Spawn") { scene.spawn() }.disabled(!scene.canSpawn)
                    Button("Clone") { scene.cloneSelected() }.disabled(!scene.canSpawn || !scene.hasSelection)
                    Button("Kick") { scene.kickSelected() }.disabled(!scene.hasSelection)
                    Button("Disconnect") { scene.disconnectSelected() }.disabled(!scene.hasSelection)
                }
                HStack {
                    Button("Recolor") { scene.recolorSelected() }.disabled(!scene.hasSelection)
                    Button("Remove") { scene.removeSelected() }.disabled(!scene.hasSelection)
                    Button("Reset") { scene.reset() }
                }
                Text("Tap a mechanism to select it. Clone copies its current pose; edits affect only that copy.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.buttonStyle(.bordered).font(.footnote).padding(.horizontal)
        }.padding(.vertical).background(.black).preferredColorScheme(.dark).tint(.orange)
            .task { await scene.load() }
    }
}

private struct PrefabInstance: Component { var number: Int; var slot: Int }
private struct PrefabDemoRuntime: Component {
    weak var scene: PrefabDemoScene?
    func cloned() -> Self? { nil }
}
private struct PrefabDemoPresentation: System {
    static var phase: SystemPhase { .presentation }
    init(world: World) {}
    mutating func update(context: UpdateContext) { context.world.root.components[PrefabDemoRuntime.self]?.scene?.refresh() }
}

@MainActor @Observable private final class PrefabDemoScene {
    var summary = "Loading Pendulum.prefab"
    private(set) var instanceCount = 0
    private(set) var hasSelection = false
    private(set) var isLoaded = false
    var canSpawn: Bool { isLoaded && instanceCount < 6 }
    @ObservationIgnored private var world: World?
    @ObservationIgnored private var resource: PrefabResource?
    @ObservationIgnored private let library = ResourceLibrary()
    @ObservationIgnored private var selected: Entity?
    @ObservationIgnored private var camera: Entity?
    @ObservationIgnored private var nextNumber = 1
    @ObservationIgnored private var viewport = CGSize(width: 380, height: 500)

    func load() async {
        guard resource == nil else { return }
        do {
            resource = try await library.prefab(named: "Pendulum.prefab")
            isLoaded = true
            if world != nil { reset() }
        } catch { summary = "Prefab could not load: \(error)" }
    }
    func build(in content: GameViewContent) {
        world = content.scene; content.scene.physics.gravity = [0, -3]
        content.scene.root.components.set(PrefabDemoRuntime(scene: self)); content.scene.addSystem(PrefabDemoPresentation.self)
        let camera = Entity(name: "preview", components: CameraComponent(zoom: 1, smoothing: 0))
        camera.position = [0, -10]; content.add(camera); self.camera = camera
        resize(viewport)
        if resource != nil { reset() }
    }
    func resize(_ size: CGSize) {
        viewport = size
        if size.width > 0 && size.height > 0 { camera?.components[CameraComponent.self]?.zoom = Float(min(size.width / 370, size.height / 440)) }
    }
    private var instances: [Entity] { world?.entities.filter { $0.components.has(PrefabInstance.self) } ?? [] }
    func reset() {
        for instance in instances { instance.removeFromParent() }
        selected = nil; nextNumber = 1; instanceCount = 0; hasSelection = false
        if resource != nil { for _ in 0..<3 { spawn() } }
    }
    func spawn() { if let resource, canSpawn { insert(resource.instantiate()) } }
    func cloneSelected() {
        guard let selected, canSpawn else { return }
        let copy = selected.clone(); copy.rotation += 0.2
        insert(copy)
    }
    private func insert(_ entity: Entity) {
        guard let world else { return }
        let used = Set(instances.compactMap { $0.components[PrefabInstance.self]?.slot })
        guard let slot = (0..<6).first(where: { !used.contains($0) }) else { return }
        entity.name = "Copy \(nextNumber)"
        entity.components.set(PrefabInstance(number: nextNumber, slot: slot)); nextNumber += 1
        entity.position = [Float(slot % 3 - 1) * 110, slot < 3 ? 155 : -65]
        world.addEntity(entity); instanceCount = instances.count
        select(entity); kickSelected()
    }
    func select(_ entity: Entity) {
        selected = entity; hasSelection = true
        for instance in instances {
            instance.findEntity(named: "pivot")?.components[SpriteComponent.self]?.color = instance === entity ? .white : .orange
        }
    }
    func kickSelected() {
        selected?.findEntity(named: "bob")?.applyImpulse([45, 0])
        selected?.findEntity(named: "rod")?.applyImpulse([25, 0])
    }
    func disconnectSelected() {
        selected?.visit { entity in
            if entity.components.has(PhysicsJointComponent.self) { entity.components[PhysicsJointComponent.self]?.isEnabled.toggle() }
        }
    }
    func recolorSelected() {
        guard let bob = selected?.findEntity(named: "bob") else { return }
        bob.components[SpriteComponent.self]?.color = bob.components[SpriteComponent.self]?.color == .pink ? .mint : .pink
    }
    func removeSelected() {
        selected?.removeFromParent(); selected = nil; instanceCount = instances.count; hasSelection = false
        if let last = instances.last { select(last) }
    }
    func refresh() {
        guard let world else { return }
        var total = 0, active = 0
        for entity in world.allEntities {
            guard let joint = entity.components[PhysicsJointComponent.self] else { continue }
            total += 1; if entity.physicsJointStatus == .active { active += 1 }
            // Lines are components on each instance's joint entities, so they
            // move with that copy and need no shared drawing state.
            if entity.components.has(SpriteComponent.self), let a = world.entity(withID: joint.bodyA), let b = world.entity(withID: joint.bodyB) {
                let point = a.convert(position: [0, -30], to: entity.parent) ?? .zero
                let end = b.position(relativeTo: entity.parent) ?? .zero
                let delta = end - point
                entity.position = (point + end) / 2; entity.rotation = atan2(delta.y, delta.x)
                entity.components[SpriteComponent.self]?.size = [simd_length(delta), 2]
                entity.components[SpriteComponent.self]?.opacity = joint.isEnabled ? 0.7 : 0
            }
        }
        let text = "\(instanceCount) copies · \(active)/\(total) joints · \(library.cachedResourceCount) prefab cached\nSelected: \(selected?.name ?? "none")"
        if isLoaded && summary != text { summary = text }
    }
}
