import SpriteUI
import SwiftUI

struct AttachmentDemoView: View {
    @State private var model = AttachmentDemoScene()
    @State private var paused = false
    var body: some View {
        VStack(spacing: 10) {
            GameView { model.build(in: $0) } update: { content in
                content.scene.isPaused = paused
            } attachments: {
                GameAttachment(id: "health") { context in
                    let id = context.entity.parent?.id ?? 0
                    let hp = model.health[id] ?? 100
                    VStack(spacing: 3) {
                        Text("Bot #\(id) · \(hp)").font(.caption2.monospaced())
                        ZStack(alignment: .leading) {
                            Capsule().fill(.gray.opacity(0.4))
                            Capsule().fill(hp > 30 ? .green : .red).frame(width: 72 * CGFloat(hp) / 100)
                        }.frame(width: 72, height: 6)
                    }.padding(6).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                GameAttachment(id: "panel") { context in
                    VStack(spacing: 6) {
                        Text("Selected #\(context.entity.parent?.id ?? 0)").font(.caption.monospaced())
                        HStack(spacing: 6) {
                            Button("Hit −10") { context.perform { model.panelHit($0.parent) } }
                            Button("Heal") { context.perform { model.heal($0.parent) } }
                        }
                        Button("Recycle bot") { context.perform { model.recycle($0.parent) } }
                    }
                    .font(.caption).buttonStyle(.bordered).tint(.orange)
                    .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                GameAttachment(id: "damage") { context in
                    Text(model.damageText[context.entity.id] ?? "")
                        .font(.headline.monospaced().bold()).foregroundStyle(.red)
                        .padding(4).background(.black.opacity(0.7), in: Capsule())
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { model.resize($0) }
            .gesture(SpatialTapGesture().targetedToEntity(where: .has(AttachmentDemoActor.self)).onEnded { model.select($0.entity) })
            .overlay(alignment: .top) {
                Text(model.summary).font(.caption.monospaced()).multilineTextAlignment(.center)
                    .padding(8).background(.ultraThinMaterial, in: Capsule())
            }
            VStack(spacing: 10) {
                HStack {
                    Button("Spawn 3") { model.spawn() }
                    Button("Damage all") { model.damageAll() }
                    Button("Recycle all") { model.recycleAll() }
                }
                HStack {
                    Toggle("Scene UI", isOn: $model.sceneSizing)
                    Toggle("Pool enabled", isOn: $model.enabled)
                    Toggle("Pause", isOn: $paused)
                }.toggleStyle(.button)
                HStack {
                    Text("Zoom").font(.caption)
                    Slider(value: $model.zoom, in: 0.7...1.7)
                    Button("Pan") { model.pan() }
                    Button("Rotate") { model.rotate() }
                }
                Text("Tap a bot to select it. Panel buttons should increase panel taps only. Labels pass scene taps through; recycled bots get fresh UI state.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.buttonStyle(.bordered).font(.footnote).padding(.horizontal)
        }.padding(.vertical).background(.black).preferredColorScheme(.dark).tint(.orange)
            .onChange(of: model.enabled) { model.applyEnabled() }
            .onChange(of: model.zoom) { model.applyCamera() }
            .onChange(of: model.sceneSizing) { model.applySizing() }
    }
}

private struct AttachmentDemoActor: Component { var slot: Int }
private struct AttachmentDemoRuntime: Component {
    weak var scene: AttachmentDemoScene?
    func cloned() -> Self? { nil }
}
private struct AttachmentDemoSystem: System {
    static var phase: SystemPhase { .presentation }
    init(world: World) {}
    mutating func update(context: UpdateContext) { context.world.resources[AttachmentDemoRuntime.self]?.scene?.refresh() }
}

@MainActor @Observable private final class AttachmentDemoScene {
    var health: [Entity.ID: Int] = [:]
    var damageText: [Entity.ID: String] = [:]
    var summary = "Preparing attachments"
    var enabled = true
    var sceneSizing = false
    var zoom = 1.0
    @ObservationIgnored private var world: World?
    @ObservationIgnored private var attachments: GameViewAttachments?
    @ObservationIgnored private var pool: EntityPool?
    @ObservationIgnored private var camera: Entity?
    @ObservationIgnored private var selected: Entity.ID?
    @ObservationIgnored private var taps = 0
    @ObservationIgnored private var panelTaps = 0
    @ObservationIgnored private var panned = false
    @ObservationIgnored private var rotated = false
    @ObservationIgnored private var viewport = CGSize(width: 380, height: 500)
    @ObservationIgnored private var subscriptions: [EventSubscription] = []

    func build(in content: GameViewContent) {
        world = content.scene; attachments = content.attachments
        content.scene.resources.set(AttachmentDemoRuntime(scene: self)); content.scene.addSystem(AttachmentDemoSystem.self)
        let camera = Entity(components: CameraComponent(smoothing: 0)); content.add(camera); self.camera = camera
        resize(viewport)
        let template = Entity(name: "bot", components: AttachmentDemoActor(slot: 0), InputTargetComponent(),
            CollisionComponent(shape: .rectangle(size: [38, 38])), SpriteComponent(color: .mint, size: [38, 38]))
        let label = Entity(components: AttachmentComponent(id: "health", offset: [0, 30], anchor: .bottom))
        let panel = Entity(name: "panel", components: AttachmentComponent(id: "panel", offset: [0, -30], anchor: .top, isInteractive: true))
        panel.isEnabled = false; panel.zPosition = 20
        template.addChild(label); template.addChild(panel)
        do { pool = try EntityPool(prefab: PrefabResource(root: template), scene: content.scene, capacity: 3, prewarm: 3,
            onRelease: { root in
                for child in root.children where child.components[AttachmentComponent.self]?.attachmentID == "damage" { child.removeFromParent() }
            }) }
        catch { summary = "Pool error: \(error)" }
        subscriptions = [content.subscribe(to: WorldEvents.WillRemoveEntity.self) { [weak self] event in self?.damageText[event.entity.id] = nil }]
        spawn()
    }
    func resize(_ size: CGSize) { viewport = size; applyCamera() }
    func applyCamera() {
        guard viewport.width > 0 && viewport.height > 0 else { return }
        camera?.components[CameraComponent.self]?.zoom = Float(min(viewport.width / 380, viewport.height / 470) * zoom)
        camera?.position = panned ? [35, 20] : .zero
        camera?.rotation = rotated ? 0.18 : 0
    }
    func pan() { panned.toggle(); applyCamera() }
    func rotate() { rotated.toggle(); applyCamera() }
    func spawn() {
        guard let pool else { return }
        recycleAll()
        do {
            for index in 0..<3 {
                let x = Float(index - 1) * 100, y = Float(index - 1) * 85
                guard let root = try pool.acquire(configure: { root in
                    root.transform = Transform(translation: [x, y])
                    root.components.set(AttachmentDemoActor(slot: index))
                    root.components[SpriteComponent.self]?.color = [Color.mint, .orange, .pink][index]
                    root.findEntity(named: "panel")?.isEnabled = false
                    self.health[root.id] = 100
                }) else { continue }
                let motion = try AnimationResource.sequence([
                    .move(from: [x - 18, y], to: [x + 18, y], duration: 1.8, curve: .easeInOut),
                    .move(to: [x - 18, y], duration: 1.8, curve: .easeInOut)
                ])
                try root.playAnimation(motion, options: .init(repeatMode: .forever))
            }
            applySizing(); applyEnabled()
            if let root = pool.leasedEntities.first(where: { $0.components[AttachmentDemoActor.self]?.slot == 1 }) { setSelected(root.id) }
        } catch { summary = "Spawn error: \(error)" }
        refresh()
    }
    func select(_ entity: Entity) { taps += 1; setSelected(entity.id); refresh() }
    private func setSelected(_ id: Entity.ID?) {
        selected = id
        for root in pool?.leasedEntities ?? [] { root.findEntity(named: "panel")?.isEnabled = root.id == id }
    }
    func panelHit(_ entity: Entity?) { panelTaps += 1; hit(entity); refresh() }
    func heal(_ entity: Entity?) { panelTaps += 1; if let entity { health[entity.id] = 100 }; refresh() }
    private func hit(_ entity: Entity?) {
        guard let entity, entity.isActive else { return }
        health[entity.id] = max(0, (health[entity.id] ?? 100) - 10)
        guard let label = attachments?.makeEntity(for: "damage") else { return }
        damageText[label.id] = "−10"; label.position = [0, 40]; label.zPosition = 30
        label.components.set(LifetimeComponent(1)); entity.addChild(label)
        do { try label.playAnimation(.move(to: [0, 90], duration: 0.9, curve: .easeOut)) }
        catch { summary = "Damage animation error: \(error)" }
    }
    func damageAll() { for root in pool?.leasedEntities ?? [] { hit(root) }; refresh() }
    func recycle(_ entity: Entity?) {
        panelTaps += 1
        guard let entity else { return }
        do { try pool?.release(entity); if selected == entity.id { selected = nil } }
        catch { summary = "Recycle error: \(error)" }
        refresh()
    }
    func recycleAll() {
        do { for root in pool?.leasedEntities ?? [] { try pool?.release(root) } }
        catch { summary = "Recycle error: \(error)" }
        selected = nil; refresh()
    }
    func applyEnabled() { pool?.container.isEnabled = enabled; refresh() }
    func applySizing() {
        for root in pool?.container.children ?? [] {
            root.visit { if $0.components[AttachmentComponent.self]?.attachmentID == "health" {
                $0.components[AttachmentComponent.self]?.sizing = sceneSizing ? .scene : .screen
            } }
        }
    }
    func refresh() {
        let text = "\(pool?.leasedCount ?? 0)/3 active · selected #\(selected.map(String.init) ?? "—")\n\(taps) scene taps · \(panelTaps) panel taps"
        if summary != text { summary = text }
    }
}
