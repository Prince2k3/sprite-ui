import SpriteUI
import SwiftUI

struct MaskDemoView: View {
    @State private var model = MaskDemoScene()
    var body: some View {
        VStack(spacing: 12) {
            GameView { model.build(in: $0) }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { model.resize($0) }
                .gesture(SpatialTapGesture().targetedToEntity(where: .has(MaskDemoBall.self)).onEnded { model.tap($0.entity) })
                .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { model.moveMask(toView: $0.location) })
                .overlay(alignment: .top) {
                    Text(model.summary).font(.caption.monospaced()).multilineTextAlignment(.center)
                        .padding(8).background(.ultraThinMaterial, in: Capsule())
                }
            VStack(spacing: 10) {
                Picker("Mask artwork", selection: $model.style) {
                    ForEach(MaskDemoScene.Style.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                HStack {
                    Toggle("Mask", isOn: $model.enabled)
                    Toggle("Nested", isOn: $model.nested)
                    Toggle("Pause", isOn: $model.paused)
                }.toggleStyle(.button)
                HStack {
                    Button("Animate") { model.animate() }
                    Button("Center") { model.center() }
                    Button("Recycle") { model.recycle() }
                }
                Text("Drag the window. Tap visible balls; hidden areas cannot be tapped. Physics continues outside the mask.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(.horizontal).font(.footnote).buttonStyle(.bordered)
        }.padding(.vertical).background(.black).preferredColorScheme(.dark).tint(.orange)
            .onChange(of: model.style) { model.applyMask() }
            .onChange(of: model.enabled) { model.applyMask() }
            .onChange(of: model.nested) { model.applyNested() }
            .onChange(of: model.paused) { model.applyPause() }
    }
}

private struct MaskDemoBall: Component {}

@MainActor @Observable private final class MaskDemoScene {
    enum Style: String, CaseIterable { case window = "Window", circle = "Circle", alpha = "Alpha holes" }
    var summary = "Loading Masking.sks"
    var style = Style.window
    var enabled = true
    var nested = true
    var paused = false
    @ObservationIgnored private var world: World?
    @ObservationIgnored private var renderer: SpriteRenderer?
    @ObservationIgnored private var room: Entity?
    @ObservationIgnored private var camera: Entity?
    @ObservationIgnored private var pool: EntityPool?
    @ObservationIgnored private var viewport = CGSize(width: 380, height: 460)
    @ObservationIgnored private var rng = SeededGenerator(seed: 88)
    @ObservationIgnored private var hits = 0
    @ObservationIgnored private var recycled = 0
    @ObservationIgnored private let alpha = MaskDemoScene.alphaArtwork()

    func build(in content: GameViewContent) {
        world = content.scene; renderer = content.renderer; content.scene.physics.gravity = .zero
        let camera = Entity(components: CameraComponent(smoothing: 0)); self.camera = camera; content.add(camera); resize(viewport)
        do {
            let loaded = try SceneLoader().load(named: "Masking")
            guard let room = loaded.findEntity(named: "masked-room") else { summary = "Missing room in Masking.sks"; return }
            self.room = room
            room.components.set(PhysicsBodyComponent(shape: .edgeLoop(rectangle: [320, 320]), categoryBitMask: 1))
            content.add(loaded)
            let frame = Entity(components: ShapeComponent(.rectangle(size: [320, 320]), stroke: .white.opacity(0.3), lineWidth: 1))
            frame.zPosition = -30; content.add(frame)
            let title = Entity(components: TextComponent("CLIPPED WORLD", font: .system(size: 17, weight: .bold), color: .cyan))
            title.position = [0, 178]; title.zPosition = 20; content.add(title)
            let template = Entity(name: "masked-ball", components: MaskDemoBall(), InputTargetComponent(),
                MaskComponent(shape: .circle(radius: 12)), SpriteComponent(color: .orange, size: [26, 26]),
                PhysicsBodyComponent(shape: .circle(radius: 12), restitution: 1, linearDamping: 0, affectedByGravity: false,
                                     categoryBitMask: 2, collisionBitMask: 3))
            let number = Entity(components: TextComponent("•", font: .system(size: 15, weight: .bold))); number.zPosition = 2; template.addChild(number)
            pool = try EntityPool(prefab: PrefabResource(root: template), scene: content.scene, capacity: 6)
            if let container = pool?.container { room.addChild(container) }
            spawn(); applyNested(); refresh()
        } catch { summary = "Mask scene failed: \(error)" }
    }
    func resize(_ size: CGSize) {
        viewport = size; camera?.components[CameraComponent.self]?.zoom = Float(min(size.width / 390, size.height / 470))
    }
    func applyMask() {
        let source: MaskContent = switch style {
        case .window: .shape(.roundedRectangle(size: [300, 300], cornerRadius: 30))
        case .circle: .shape(.circle(radius: 125))
        case .alpha: .texture(alpha, size: [300, 300])
        }
        room?.components[MaskComponent.self]?.content = source
        room?.components[MaskComponent.self]?.isEnabled = enabled
        refresh()
    }
    func applyNested() { room?.findEntity(named: "inner-mask")?.components[MaskComponent.self]?.isEnabled = nested; refresh() }
    func applyPause() { world?.isPaused = paused; refresh() }
    func moveMask(toView point: CGPoint) {
        guard let renderer else { return }
        let scenePoint = renderer.scenePoint(fromView: point)
        room?.components[MaskComponent.self]?.transform = Transform(translation: [min(120, max(-120, scenePoint.x)), min(120, max(-120, scenePoint.y))])
        refresh()
    }
    func animate() {
        center()
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            room?.components[MaskComponent.self]?.transform = Transform(translation: [75, 25], rotation: .pi / 5, scale: [0.65, 0.9])
        }
        refresh()
    }
    func center() { room?.components[MaskComponent.self]?.transform = .identity; refresh() }
    func tap(_ entity: Entity) {
        hits += 1; if !paused { entity.applyImpulse([0.5, 1]) }; refresh()
    }
    private func spawn() {
        do {
            for index in 0..<6 {
                let p = SIMD2<Float>(Float(index - 3) * 40 + 20, Float.random(in: -100...100, using: &rng))
                let velocity = SIMD2<Float>(Float.random(in: -60...60, using: &rng), Float.random(in: -60...60, using: &rng))
                _ = try pool?.acquire { entity in
                    entity.position = p; entity.zPosition = 10
                    entity.components[PhysicsBodyComponent.self]?.velocity = velocity
                    entity.components[SpriteComponent.self]?.color = [Color.orange, .pink, .cyan, .yellow, .mint, .purple][index]
                }
            }
        } catch { summary = "Pool failed: \(error)" }
        refresh()
    }
    func recycle() {
        do { for entity in pool?.leasedEntities ?? [] { try pool?.release(entity) }; recycled += 6; spawn() }
        catch { summary = "Recycle failed: \(error)" }
    }
    private func refresh() {
        summary = "\(pool?.leasedCount ?? 0) physics balls · \(hits) hits · \(recycled) recycled\n\(enabled ? style.rawValue : "Mask bypassed") · \(paused ? "paused" : "physics active")"
    }
    private static func alphaArtwork() -> TextureResource {
        var bytes: [UInt8] = []
        for y in 0..<64 { for x in 0..<64 {
            let p = SIMD2<Float>(Float(x) / 63 * 2 - 1, Float(y) / 63 * 2 - 1)
            let holes = hypot(p.x + 0.3, p.y - 0.25) < 0.28 || hypot(p.x - 0.35, p.y + 0.25) < 0.23
            let inside = max(abs(p.x), abs(p.y)) < 0.95 && !holes
            bytes += [0, 0, 0, inside ? 255 : 0]
        } }
        return TextureResource(image: SpriteImage(width: 64, height: 64, pixels: bytes, smoothsScaling: false), name: "alpha-holes")
    }
}
