import SpriteUI
import SwiftUI
import simd

struct RenderGroupDemoView: View {
    @State private var model = RenderGroupDemoScene()
    var body: some View {
        VStack(spacing: 12) {
            GameView { model.build(in: $0) } attachments: {
                GameAttachment(id: "portal-label") { _ in
                    Text("PORTAL ACTIVE").font(.caption2.monospaced().bold()).foregroundStyle(.cyan)
                        .padding(6).background(.black.opacity(0.8), in: Capsule())
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { model.resize($0) }
            .gesture(SpatialTapGesture().targetedToEntity(where: .has(RenderDemoBall.self)).onEnded { model.tap($0.entity) })
            .overlay(alignment: .top) {
                Text(model.summary).font(.caption.monospaced()).multilineTextAlignment(.center)
                    .padding(8).background(.ultraThinMaterial, in: Capsule())
            }
            .overlay {
                if model.paused {
                    Text("PAUSED").font(.title2.bold()).padding(18)
                        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
                        .allowsHitTesting(false)
                }
            }
            VStack(spacing: 10) {
                HStack {
                    Toggle("Pause", isOn: $model.paused)
                    Toggle("World pass", isOn: $model.enabled)
                    Toggle("Bloom", isOn: $model.bloom)
                }.toggleStyle(.button)
                HStack {
                    Text("Blur").font(.caption).frame(width: 50, alignment: .leading)
                    Slider(value: $model.blur, in: 0...16).accessibilityLabel("World blur radius")
                    Text("\(model.blur, specifier: "%.0f")").font(.caption.monospaced()).frame(width: 30)
                }
                HStack {
                    Text("Opacity").font(.caption).frame(width: 50, alignment: .leading)
                    Slider(value: $model.opacity, in: 0.2...1).accessibilityLabel("World group opacity")
                    Text("\(model.opacity * 100, specifier: "%.0f")%").font(.caption.monospaced()).frame(width: 30)
                }
                HStack {
                    Toggle("Mono", isOn: $model.monochrome).toggleStyle(.button)
                    Picker("Portal blend", selection: $model.blend) {
                        Text("Add").tag(SpriteBlendMode.add); Text("Alpha").tag(SpriteBlendMode.alpha); Text("Screen").tag(SpriteBlendMode.screen)
                    }.pickerStyle(.menu).fixedSize()
                    Button("Kick") { model.kick() }
                    Button("Recycle") { model.recycle() }
                }
                Text("Tap a ball: hit shapes stay sharp. Pause blurs the world while the label and controls stay clear.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.buttonStyle(.bordered).font(.footnote).padding(.horizontal)
        }.padding(.vertical).background(.black).preferredColorScheme(.dark).tint(.orange)
            .onChange(of: model.paused) { model.applyWorld() }
            .onChange(of: model.enabled) { model.applyWorld() }
            .onChange(of: model.blur) { model.applyWorld() }
            .onChange(of: model.opacity) { model.applyWorld() }
            .onChange(of: model.monochrome) { model.applyWorld() }
            .onChange(of: model.bloom) { model.applyPortal() }
            .onChange(of: model.blend) { model.applyPortal() }
    }
}

private struct RenderDemoBall: Component {}

@MainActor @Observable private final class RenderGroupDemoScene {
    var summary = "Live compositing · nested bloom"
    var paused = false
    var enabled = true
    var bloom = true
    var monochrome = false
    var blur = 0.0
    var opacity = 1.0
    var blend = SpriteBlendMode.add
    @ObservationIgnored private var world: World?
    @ObservationIgnored private var stage: Entity?
    @ObservationIgnored private var portal: Entity?
    @ObservationIgnored private var camera: Entity?
    @ObservationIgnored private var pool: EntityPool?
    @ObservationIgnored private var viewport = CGSize(width: 380, height: 420)
    @ObservationIgnored private var rng = SeededGenerator(seed: 72)
    @ObservationIgnored private var taps = 0
    @ObservationIgnored private var recycled = 0

    func build(in content: GameViewContent) {
        world = content.scene
        content.scene.physics.gravity = [0, -2]
        let camera = Entity(components: CameraComponent(smoothing: 0)); content.add(camera); self.camera = camera; resize(viewport)
        let stage = Entity(name: "filtered-world", components: RenderGroupComponent(),
                           PhysicsBodyComponent(shape: .edgeLoop(rectangle: [340, 360]), categoryBitMask: 1))
        self.stage = stage; content.add(stage)
        let backdrop = Entity(components: SpriteComponent(color: Color(red: 0.035, green: 0.055, blue: 0.1), size: [340, 360]))
        backdrop.zPosition = -20; stage.addChild(backdrop)
        for row in -4...4 {
            let line = Entity(components: SpriteComponent(color: .cyan.opacity(0.18), size: [338, 1]))
            line.position = [0, Float(row) * 40]; line.zPosition = -19; stage.addChild(line)
        }
        for column in -4...4 {
            let line = Entity(components: SpriteComponent(color: .cyan.opacity(0.18), size: [1, 358]))
            line.position = [Float(column) * 40, 0]; line.zPosition = -19; stage.addChild(line)
        }
        let portal = Entity(name: "glowing-portal", components: RenderGroupComponent(effects: [.bloom(radius: 12, intensity: 1)], blendMode: .add))
        portal.position = [0, 75]; portal.zPosition = 5; stage.addChild(portal); self.portal = portal
        let ring = Entity(components: SpriteComponent(image: Self.ring(), size: [118, 118], tint: .cyan, tintAmount: 1)); portal.addChild(ring)
        for index in 0..<6 {
            let angle = Float(index) * .pi / 3
            let shard = Entity(components: SpriteComponent(color: .mint, size: [8, 18]))
            shard.position = [cos(angle) * 68, sin(angle) * 68]; shard.rotation = angle; portal.addChild(shard)
        }
        let label = Entity(components: AttachmentComponent(id: "portal-label")); label.position = [0, 160]; stage.addChild(label)
        do {
            try portal.playAnimation(.rotate(from: 0, to: .pi * 2, duration: 8), options: .init(repeatMode: .forever))
            let template = Entity(name: "ball", components: RenderDemoBall(), InputTargetComponent(),
                SpriteComponent(image: SpriteImage.disc(diameter: 48), size: [28, 28], tint: .orange, tintAmount: 1),
                CollisionComponent(shape: .circle(radius: 14)),
                PhysicsBodyComponent(shape: .circle(radius: 14), restitution: 0.85, linearDamping: 0.02,
                                     categoryBitMask: 2, collisionBitMask: 3))
            pool = try EntityPool(prefab: PrefabResource(root: template), scene: content.scene, capacity: 5)
            if let container = pool?.container { stage.addChild(container) }
            spawn()
        } catch { summary = "Could not build rendering demo: \(error)" }
        applyWorld(); applyPortal()
    }

    func resize(_ size: CGSize) {
        viewport = size
        camera?.components[CameraComponent.self]?.zoom = Float(min(size.width / 390, size.height / 450))
    }
    func applyWorld() {
        var effects: [PostProcessEffect] = []
        let radius = paused ? max(blur, 10) : blur
        if radius > 0 { effects.append(.blur(radius: Float(radius))) }
        if monochrome { effects.append(.colorAdjustment(saturation: 0)) }
        stage?.components.set(RenderGroupComponent(effects: effects, opacity: Float(opacity), isEnabled: enabled))
        world?.isPaused = paused
        refresh()
    }
    func applyPortal() {
        portal?.components.set(RenderGroupComponent(effects: bloom ? [.bloom(radius: 12, intensity: 1)] : [], blendMode: blend))
        refresh()
    }
    private func spawn() {
        do {
            for index in 0..<5 {
                let point = SIMD2<Float>(Float(index - 2) * 48, Float.random(in: -30...70, using: &rng))
                let velocity = SIMD2<Float>(Float.random(in: -70...70, using: &rng), Float.random(in: 20...80, using: &rng))
                _ = try pool?.acquire { entity in
                    entity.position = point; entity.rotation = 0; entity.zPosition = 10
                    entity.components[PhysicsBodyComponent.self]?.velocity = velocity
                    entity.components[PhysicsBodyComponent.self]?.angularVelocity = 0
                    entity.components[SpriteComponent.self]?.color = [Color.orange, .pink, .yellow, .mint, .purple][index]
                }
            }
        } catch { summary = "Could not acquire balls: \(error)" }
        refresh()
    }
    func tap(_ entity: Entity) {
        guard !paused else { return }
        taps += 1; entity.applyImpulse([0, 6]); refresh()
    }
    func kick() {
        for entity in pool?.leasedEntities ?? [] { entity.applyImpulse([Float.random(in: -2...2, using: &rng), 6]) }
    }
    func recycle() {
        do { for entity in pool?.leasedEntities ?? [] { try pool?.release(entity) }; recycled += 5; spawn() }
        catch { summary = "Recycle failed: \(error)" }
    }
    private func refresh() { summary = "\(pool?.leasedCount ?? 0) physics balls · \(taps) hits\n\(recycled) recycled · \(enabled ? "world pass on" : "world pass bypassed")" }
    private static func ring() -> SpriteImage {
        let size = 96
        var pixels: [UInt8] = []
        for y in 0..<size { for x in 0..<size {
            let p = SIMD2<Float>(Float(x) - 47.5, Float(y) - 47.5) / 48
            let gap = abs(simd_length(p) - 0.72)
            let alpha = UInt8(clamping: Int(max(0, 1 - gap / 0.055) * 255))
            pixels += [255, 255, 255, alpha]
        } }
        return SpriteImage(width: size, height: size, pixels: pixels)
    }
}
