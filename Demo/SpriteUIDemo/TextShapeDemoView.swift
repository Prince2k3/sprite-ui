import SpriteUI
import SwiftUI

struct TextShapeDemoView: View {
    @State private var model = TextShapeDemoScene()
    var body: some View {
        VStack(spacing: 12) {
            GameView { model.build(in: $0) }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { model.resize($0) }
                .gesture(SpatialTapGesture().targetedToEntity(where: .has(DrawingDemoTarget.self)).onEnded { model.tap($0.entity) })
                .overlay(alignment: .top) {
                    Text(model.summary).font(.caption.monospaced()).multilineTextAlignment(.center)
                        .padding(8).background(.ultraThinMaterial, in: Capsule())
                }
            VStack(spacing: 10) {
                Picker("Text alignment", selection: $model.alignment) {
                    Text("Left").tag(TextComponent.HorizontalAlignment.left)
                    Text("Center").tag(TextComponent.HorizontalAlignment.center)
                    Text("Right").tag(TextComponent.HorizontalAlignment.right)
                }.pickerStyle(.segmented)
                HStack {
                    Toggle("Wrap", isOn: $model.wrap).toggleStyle(.button)
                    Toggle("Bold", isOn: $model.bold).toggleStyle(.button)
                    Button("Animate") { model.animate() }
                    Button("Recycle") { model.recycle() }
                }
                HStack {
                    Text("Vitals").font(.caption)
                    Slider(value: $model.health, in: 0...1).accessibilityLabel("Vitals level")
                    Text("\(model.health * 100, specifier: "%.0f")%").font(.caption.monospaced()).frame(width: 42)
                }
                HStack {
                    Button("Save") { model.save() }; Button("Load") { model.load() }; Button("Reset") { model.reset() }
                }
                Text("World-space labels and vector paths. The ring's center is not a hit target.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(.horizontal).font(.footnote).buttonStyle(.bordered)
        }.padding(.vertical).background(.black).preferredColorScheme(.dark).tint(.orange)
            .onChange(of: model.alignment) { model.applyText() }
            .onChange(of: model.wrap) { model.applyText() }
            .onChange(of: model.bold) { model.applyText() }
            .onChange(of: model.health) { model.applyHealth() }
    }
}

private struct DrawingDemoTarget: Component {}

@MainActor @Observable private final class TextShapeDemoScene {
    var summary = "Text and vector shapes · Drawing.sks"
    var alignment = TextComponent.HorizontalAlignment.center
    var wrap = true
    var bold = false
    var health = 0.75
    @ObservationIgnored private var world: World?
    @ObservationIgnored private var root: Entity?
    @ObservationIgnored private var camera: Entity?
    @ObservationIgnored private var pool: EntityPool?
    @ObservationIgnored private var viewport = CGSize(width: 380, height: 520)
    @ObservationIgnored private var hits = 0
    @ObservationIgnored private var recycled = 0
    private var saveURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("drawing-save.json") }

    func build(in content: GameViewContent) {
        world = content.scene
        let camera = Entity(components: CameraComponent(smoothing: 0)); self.camera = camera; content.add(camera); resize(viewport)
        reset()
        do {
            let template = Entity(name: "pooled-label", components: TextComponent("READY", font: .system(size: 12, weight: .bold), color: .mint))
            pool = try EntityPool(prefab: PrefabResource(root: template), scene: content.scene, capacity: 1)
            _ = try pool?.acquire { $0.position = [0, -245] }
        } catch { summary = "Pool failed: \(error)" }
    }
    func resize(_ size: CGSize) {
        viewport = size
        camera?.components[CameraComponent.self]?.zoom = Float(min(size.width / 390, size.height / 600))
    }
    func reset() {
        do {
            let loaded = try SceneLoader().load(named: "Drawing")
            root?.removeFromParent(); world?.addEntity(loaded); root = loaded; prepareTargets()
            health = 0.75; wrap = true; bold = false; alignment = .center; hits = 0
            applyText(); applyHealth(); refresh("Loaded Drawing.sks")
        } catch { summary = "Scene failed: \(error)" }
    }
    private func prepareTargets() {
        for name in ["title", "orb", "tile", "ring", "curve"] {
            root?.findEntity(named: name)?.components.set([DrawingDemoTarget(), InputTargetComponent()])
        }
    }
    func applyText() {
        guard let paragraph = root?.findEntity(named: "paragraph") else { return }
        let width: Float = wrap ? 250 : 320
        paragraph.components[TextComponent.self]?.maxWidth = width
        paragraph.components[TextComponent.self]?.numberOfLines = wrap ? 0 : 1
        paragraph.components[TextComponent.self]?.lineBreak = wrap ? .wordWrap : .truncateTail
        paragraph.components[TextComponent.self]?.horizontalAlignment = alignment
        paragraph.components[TextComponent.self]?.font = .system(size: 15, weight: bold ? .bold : .regular)
        paragraph.position.x = alignment == .left ? -width / 2 : alignment == .right ? width / 2 : 0
    }
    func applyHealth() {
        var path = VectorPath(); let left: Float = -120, right = left + Float(health) * 240
        path.move(to: [left, -30]); path.addLine(to: [right, -30]); path.addLine(to: [right, -22]); path.addLine(to: [left, -22]); path.closeSubpath()
        root?.findEntity(named: "health")?.components[ShapeComponent.self]?.geometry = .path(path)
        root?.findEntity(named: "status")?.components[TextComponent.self]?.text = "VITALS \(Int(health * 100))%"
        root?.components.set(SceneUserDataComponent(["health": .double(health)]))
    }
    func tap(_ entity: Entity) {
        hits += 1; refresh("Tapped \(entity.name)")
        pulse(entity)
    }
    func animate() {
        for name in ["title", "orb", "tile", "ring", "curve"] { if let entity = root?.findEntity(named: name) { pulse(entity) } }
        refresh("Fading text and shapes")
    }
    private func pulse(_ entity: Entity) {
        do {
            let fade = try AnimationResource.sequence([.fade(to: 0.2, duration: 0.3), .fade(to: 1, duration: 0.4)])
            try entity.playAnimation(fade)
        } catch { summary = "Animation failed: \(error)" }
    }
    func recycle() {
        do {
            for entity in pool?.leasedEntities ?? [] { try pool?.release(entity) }
            recycled += 1
            _ = try pool?.acquire { entity in
                entity.position = [0, -245]
                entity.components[TextComponent.self]?.text = "RECYCLED \(self.recycled)"
            }
            refresh("Reused text entity")
        } catch { summary = "Recycle failed: \(error)" }
    }
    func save() {
        do {
            guard let root else { return }
            try JSONEncoder().encode(root.snapshot()).write(to: saveURL, options: .atomic)
            refresh("Saved labels and paths")
        } catch { summary = "Save failed: \(error)" }
    }
    func load() {
        do {
            let saved = try JSONDecoder().decode(EntitySnapshot.self, from: Data(contentsOf: saveURL))
            let loaded = saved.makeEntity()
            root?.removeFromParent(); world?.addEntity(loaded); root = loaded; prepareTargets()
            health = loaded.components[SceneUserDataComponent.self]?["health"]?.double ?? 0.75
            if let text = loaded.findEntity(named: "paragraph")?.components[TextComponent.self] {
                alignment = text.horizontalAlignment; wrap = text.numberOfLines == 0
                bold = text.font == .system(size: 15, weight: .bold)
            }
            refresh("Restored labels and paths")
        } catch { summary = "Load failed: \(error.localizedDescription)" }
    }
    private func refresh(_ message: String) { summary = "\(message)\n\(hits) hits · \(recycled) recycled" }
}
