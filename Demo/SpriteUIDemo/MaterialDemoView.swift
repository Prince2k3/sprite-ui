import SpriteUI
import SwiftUI

/// Three pooled characters share frame textures and shader code. Only the selected
/// material changes; recycling resets its parameters while reusing its rendered node.
struct MaterialDemoView: View {
    @State private var model = MaterialDemoScene()
    var body: some View {
        VStack(spacing: 12) {
            GameView { model.build(in: $0) }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { model.resize($0) }
                .overlay(alignment: .top) {
                    Text(model.summary).font(.caption.monospaced()).multilineTextAlignment(.center)
                        .padding(8).background(.ultraThinMaterial, in: Capsule())
                }
                .overlay(alignment: .bottom) {
                    HStack(spacing: 0) {
                        ForEach(["Left", "Middle", "Right"], id: \.self) { Text($0).frame(maxWidth: .infinity) }
                    }.font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .padding(.horizontal, 24).padding(.bottom, 12)
                }
            VStack(spacing: 10) {
                Picker("Character", selection: $model.selected) {
                    Text("Left").tag(0); Text("Middle").tag(1); Text("Right").tag(2)
                }.pickerStyle(.segmented)
                Picker("Shader", selection: $model.effect) {
                    ForEach(MaterialDemoScene.Effect.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                HStack {
                    Text(model.effect == .scanlines ? "Scanlines" : "Dissolve").font(.caption)
                    Slider(value: $model.amount, in: 0...1).disabled(model.effect == .none)
                        .accessibilityLabel(model.effect == .scanlines ? "Scanline strength" : "Dissolve amount")
                    Text("\(model.amount * 100, specifier: "%.0f")%").font(.caption.monospaced()).frame(width: 40)
                }
                HStack {
                    Button("Flash") { model.flash() }.disabled(model.effect != .effects)
                    Toggle("Outline", isOn: $model.outline).toggleStyle(.button).disabled(model.effect != .effects)
                    Button("Recycle") { model.recycle() }
                    Picker("Blend", selection: $model.blend) {
                        ForEach(SpriteBlendMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.menu)
                }
                Text("Changes affect one character. Recycle restores its material. Scanlines loads a custom .fsh resource.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.buttonStyle(.bordered).font(.footnote).padding(.horizontal)
        }.padding(.vertical).background(.black).preferredColorScheme(.dark).tint(.orange)
            .task { await model.loadShader() }
            .onChange(of: model.selected) { model.select() }
            .onChange(of: model.effect) { model.apply() }
            .onChange(of: model.amount) { model.apply() }
            .onChange(of: model.outline) { model.apply() }
            .onChange(of: model.blend) { model.apply() }
    }
}

private struct MaterialDemoActor: Component {
    var slot: Int
    var flash: Float = 0
}
private struct MaterialDemoSystem: System {
    init(world: World) {}
    mutating func update(context: UpdateContext) {
        for entity in context.entities(matching: EntityQuery(where: .has(MaterialDemoActor.self))) {
            guard var state = entity.components[MaterialDemoActor.self], state.flash > 0 else { continue }
            state.flash = max(0, state.flash - Float(context.deltaTime) * 0.8)
            entity.components.set(state)
            if entity.components[SpriteComponent.self]?.material.shader == .spriteEffects {
                try? entity.components[SpriteComponent.self]?.material.setParameter(.float(state.flash), named: "a_flash")
            }
        }
    }
}

@MainActor @Observable private final class MaterialDemoScene {
    enum Effect: String, CaseIterable { case effects = "Effects", scanlines = "Scanlines", none = "No shader" }
    var summary = "Shared shader · independent materials"
    var selected = 1
    var effect = Effect.effects
    var amount: Double = 0
    var outline = false
    var blend = SpriteBlendMode.alpha
    @ObservationIgnored private var pool: EntityPool?
    @ObservationIgnored private var clip: AnimationResource?
    @ObservationIgnored private var camera: Entity?
    @ObservationIgnored private var scanlines: ShaderResource?
    @ObservationIgnored private var library = ResourceLibrary()
    @ObservationIgnored private var viewport = CGSize(width: 380, height: 400)
    @ObservationIgnored private var recycles = 0
    @ObservationIgnored private var synchronizing = false

    func build(in content: GameViewContent) {
        content.scene.addSystem(MaterialDemoSystem.self)
        let camera = Entity(components: CameraComponent(smoothing: 0)); self.camera = camera; content.add(camera); resize(viewport)
        for col in -4...4 {
            for row in -3...3 {
                let square = Entity(components: SpriteComponent(color: (col + row).isMultiple(of: 2) ? .gray.opacity(0.25) : .gray.opacity(0.12), size: [40, 40]))
                square.position = [Float(col) * 40, Float(row) * 40]; square.zPosition = -5; content.add(square)
            }
        }
        do {
            let frames = (0..<4).map { TextureResource(image: Self.frame($0), name: "bot-\($0)") }
            clip = try AnimationResource(frames: frames, framesPerSecond: 5)
            let template = Entity(name: "material-bot", components: MaterialDemoActor(slot: 0),
                                  SpriteComponent(texture: frames[0], material: SpriteMaterial(shader: .spriteEffects), size: [96, 96]))
            pool = try EntityPool(prefab: PrefabResource(root: template), scene: content.scene, capacity: 3, prewarm: 3,
                                  onAcquire: { $0.components[SpriteComponent.self]?.material = SpriteMaterial(shader: .spriteEffects) })
            for slot in 0..<3 { try spawn(slot) }
            select()
        } catch { summary = "Could not build demo: \(error)" }
    }

    func resize(_ size: CGSize) {
        viewport = size
        camera?.components[CameraComponent.self]?.zoom = Float(min(size.width / 380, size.height / 340))
    }

    func loadShader() async {
        do {
            scanlines = try await library.shader(named: "Scanlines", parameters: ["a_strength": .float(1)])
            if effect == .scanlines { apply() }
            refresh()
        } catch { summary = "Shader load failed: \(error)" }
    }

    private var actor: Entity? { pool?.leasedEntities.first { $0.components[MaterialDemoActor.self]?.slot == selected } }

    private func spawn(_ slot: Int) throws {
        guard let clip, let entity = try pool?.acquire(configure: { entity in
            entity.components.set(MaterialDemoActor(slot: slot))
            entity.position = [Float(slot - 1) * 112, 0]
            entity.components[SpriteComponent.self]?.material.tint = [Color.mint, .orange, .pink][slot]
            entity.components[SpriteComponent.self]?.material.tintAmount = 0.55
        }) else { return }
        try entity.playAnimation(clip, options: .init(repeatMode: .forever))
    }

    func select() {
        guard let material = actor?.components[SpriteComponent.self]?.material else { return }
        synchronizing = true
        effect = material.shader == nil ? .none : (material.shader == scanlines ? .scanlines : .effects)
        blend = material.blendMode
        if case .float(let v) = material.parameter(named: effect == .scanlines ? "a_strength" : "a_dissolve") { amount = Double(v) } else { amount = 0 }
        if case .float(let v) = material.parameter(named: "a_outlineWidth") { outline = v > 0 } else { outline = false }
        synchronizing = false
        refresh()
    }

    func apply() {
        guard !synchronizing, let actor, var sprite = actor.components[SpriteComponent.self] else { return }
        sprite.material.blendMode = blend
        switch effect {
        case .effects:
            sprite.material.shader = .spriteEffects
            try? sprite.material.setParameter(.float(Float(amount)), named: "a_dissolve")
            try? sprite.material.setParameter(.float(outline ? 1.4 : 0), named: "a_outlineWidth")
            try? sprite.material.setParameter(.vector4([1, 0.95, 0.1, 1]), named: "a_effectColor")
        case .scanlines:
            guard let scanlines else { summary = "Loading scanlines"; return }
            sprite.material.shader = scanlines
            try? sprite.material.setParameter(.float(Float(amount)), named: "a_strength")
        case .none: sprite.material.shader = nil
        }
        actor.components.set(sprite); refresh()
    }

    func flash() {
        guard let actor else { return }
        actor.components[MaterialDemoActor.self]?.flash = 1
        try? actor.components[SpriteComponent.self]?.material.setParameter(.float(1), named: "a_flash")
    }

    func recycle() {
        guard let actor else { return }
        do { try pool?.release(actor); try spawn(selected); recycles += 1; select() }
        catch { summary = "Recycle failed: \(error)" }
    }

    private func refresh() { summary = "3 animated instances · \(blend.rawValue)\n\(recycles) recycled · \(library.cachedResourceCount) file shader cached" }

    private static func frame(_ index: Int) -> SpriteImage {
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        func rect(_ x: Range<Int>, _ y: Range<Int>, _ rgba: [UInt8]) {
            for row in y { for col in x {
                let offset = (row * 32 + col) * 4
                pixels.replaceSubrange(offset..<(offset + 4), with: rgba)
            } }
        }
        let bob = index % 2, step = index < 2 ? 0 : 2
        rect(7..<25, (5 + bob)..<(18 + bob), [230, 245, 255, 255])
        rect(10..<22, (18 + bob)..<(25 + bob), [160, 190, 220, 255])
        rect(4..<8, (15 + bob)..<(24 + bob), [210, 230, 250, 255])
        rect(24..<28, (15 + bob)..<(24 + bob), [210, 230, 250, 255])
        rect(10..<15, (25 - step)..<(29 - step), [230, 245, 255, 255])
        rect(18..<23, (23 + step)..<(27 + step), [230, 245, 255, 255])
        rect(10..<13, (9 + bob)..<(13 + bob), [10, 25, 50, 255])
        rect(19..<22, (9 + bob)..<(13 + bob), [10, 25, 50, 255])
        rect(14..<18, (15 + bob)..<(16 + bob), [30, 50, 70, 255])
        return SpriteImage(width: 32, height: 32, pixels: pixels, smoothsScaling: false)
    }
}
