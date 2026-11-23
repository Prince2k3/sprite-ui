import SpriteUI
import SwiftUI
import simd

struct LightingDemoView: View {
    @State private var model = LightingDemoScene()
    var body: some View {
        VStack(spacing: 12) {
            GameView { model.build(in: $0) }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { model.resize($0) }
                .gesture(DragGesture(minimumDistance: 0).onChanged { model.moveLamp(toView: $0.location) })
                .overlay(alignment: .top) {
                    Text(model.summary).font(.caption.monospaced()).multilineTextAlignment(.center)
                        .padding(8).background(.ultraThinMaterial, in: Capsule())
                }
            VStack(spacing: 10) {
                HStack {
                    Toggle("Sweep", isOn: $model.sweeps)
                    Toggle("Normals", isOn: $model.normals)
                    Toggle("Shadows", isOn: $model.shadows)
                }.toggleStyle(.button)
                Picker("Lamp color", selection: $model.tint) {
                    ForEach(LightingDemoScene.Tint.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                HStack {
                    Text("Intensity").font(.caption)
                    Slider(value: $model.intensity, in: 0...1.5).accessibilityLabel("Light intensity")
                    Text("\(model.intensity, specifier: "%.1f")").font(.caption.monospaced()).frame(width: 26)
                }
                HStack {
                    Toggle("Lamp", isOn: $model.enabled)
                    Toggle("Blue light", isOn: $model.secondLight)
                    Picker("Floor lighting", selection: $model.receives) {
                        ForEach(LightingDemoScene.Receives.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.menu).fixedSize()
                }.toggleStyle(.button)
                HStack {
                    Button("Recycle crates") { model.recycle() }
                    Button("Reset lamp") { model.resetLamp() }
                }
                Text("Drag to move the lamp. Toggle normals to flatten the floor, or shadows to reveal the surfaces behind the crates.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.buttonStyle(.bordered).font(.footnote).padding(.horizontal)
        }.padding(.vertical).background(.black).preferredColorScheme(.dark).tint(.orange)
            .onChange(of: model.normals) { model.applyMaterials() }
            .onChange(of: model.shadows) { model.applyMaterials() }
            .onChange(of: model.receives) { model.applyMaterials() }
            .onChange(of: model.tint) { model.applyLight() }
            .onChange(of: model.intensity) { model.applyLight() }
            .onChange(of: model.enabled) { model.applyLight() }
            .onChange(of: model.secondLight) { model.applyLight() }
    }
}

private struct LightingDemoRuntime: Component {
    weak var model: LightingDemoScene?
    func cloned() -> Self? { nil }
}
private struct LightingDemoSystem: System {
    init(world: World) {}
    mutating func update(context: UpdateContext) {
        context.world.resources[LightingDemoRuntime.self]?.model?.step(context.deltaTime)
    }
}

@MainActor @Observable private final class LightingDemoScene {
    enum Tint: String, CaseIterable {
        case warm = "Warm", cool = "Cool", rose = "Rose"
        var color: Color {
            switch self { case .warm: Color(red: 1, green: 0.85, blue: 0.6); case .cool: Color(red: 0.5, green: 0.85, blue: 1); case .rose: Color(red: 1, green: 0.4, blue: 0.65) }
        }
    }
    enum Receives: String, CaseIterable {
        case both = "Both lights", first = "Lamp only", second = "Blue only", unlit = "Unlit floor"
        var mask: UInt32 { switch self { case .both: 3; case .first: 1; case .second: 2; case .unlit: 0 } }
    }
    var summary = "Point lighting · normal-mapped stone"
    var sweeps = true
    var normals = true
    var shadows = true
    var tint = Tint.warm
    var intensity = 1.0
    var enabled = true
    var secondLight = false
    var receives = Receives.both
    @ObservationIgnored private var renderer: SpriteRenderer?
    @ObservationIgnored private var camera: Entity?
    @ObservationIgnored private var lamp: Entity?
    @ObservationIgnored private var blue: Entity?
    @ObservationIgnored private var floor: Entity?
    @ObservationIgnored private var pool: EntityPool?
    @ObservationIgnored private var floorNormal: TextureResource?
    @ObservationIgnored private var crateNormal: TextureResource?
    @ObservationIgnored private var viewport = CGSize(width: 380, height: 440)
    @ObservationIgnored private var time = 0.0
    @ObservationIgnored private var recycled = 0

    func build(in content: GameViewContent) {
        renderer = content.renderer
        content.scene.resources.set(LightingDemoRuntime(model: self)); content.scene.addSystem(LightingDemoSystem.self)
        let camera = Entity(components: CameraComponent(smoothing: 0)); self.camera = camera; content.add(camera); resize(viewport)
        let stone = Self.surface(size: 128, tiled: true), crate = Self.surface(size: 64, tiled: false)
        floorNormal = TextureResource(image: stone.normal, name: "stone-normals")
        crateNormal = TextureResource(image: crate.normal, name: "crate-normals")
        let floor = Entity(name: "stone-floor", components: SpriteComponent(texture: TextureResource(image: stone.color),
            material: SpriteMaterial(normalMap: floorNormal, lightingBitMask: 3, shadowedBitMask: 3), size: [344, 424]))
        self.floor = floor; content.add(floor)
        for x: Float in [-176, 176] {
            let wall = Entity(components: SpriteComponent(color: .gray, size: [6, 436])); wall.position = [x, 0]; content.add(wall)
        }
        for y: Float in [-216, 216] {
            let wall = Entity(components: SpriteComponent(color: .gray, size: [358, 6])); wall.position = [0, y]; content.add(wall)
        }
        let template = Entity(name: "crate", components: SpriteComponent(texture: TextureResource(image: crate.color),
            material: SpriteMaterial(normalMap: crateNormal, lightingBitMask: 3, shadowCastBitMask: 3, shadowedBitMask: 3), size: [52, 64]))
        template.zPosition = 10
        do { pool = try EntityPool(prefab: PrefabResource(root: template), scene: content.scene, capacity: 3, prewarm: 3); spawnCrates() }
        catch { summary = "Could not build crates: \(error)" }
        let lamp = Entity(name: "lamp", components: LightComponent(color: tint.color,
            ambientColor: Color(white: 0.06), shadowColor: .black.opacity(0.75), falloff: 1, categoryBitMask: 1))
        lamp.position = [-95, 115]; lamp.zPosition = 30
        let marker = Entity(components: SpriteComponent(image: SpriteImage.disc(diameter: 32), size: [12, 12], tint: .yellow, tintAmount: 1))
        lamp.addChild(marker); content.add(lamp); self.lamp = lamp
        let blue = Entity(name: "blue-light", components: LightComponent(color: Color(red: 0.25, green: 0.55, blue: 1), intensity: 0.8,
            shadowColor: .black.opacity(0.5), falloff: 1.3, categoryBitMask: 2))
        blue.position = [110, -140]; blue.zPosition = 30; blue.isEnabled = false
        let blueMarker = Entity(components: SpriteComponent(image: SpriteImage.disc(diameter: 32), size: [10, 10], tint: .cyan, tintAmount: 1))
        blue.addChild(blueMarker); content.add(blue); self.blue = blue
        applyMaterials(); applyLight()
    }

    func resize(_ size: CGSize) {
        viewport = size
        camera?.components[CameraComponent.self]?.zoom = Float(min(size.width / 380, size.height / 490))
    }
    func step(_ delta: TimeInterval) {
        time += delta
        if sweeps { lamp?.position = [Float(cos(time * 0.55)) * 135, Float(sin(time * 0.55)) * 160] }
    }
    func moveLamp(toView point: CGPoint) {
        guard let renderer else { return }
        sweeps = false
        let p = renderer.scenePoint(fromView: point)
        lamp?.position = [min(max(p.x, -165), 165), min(max(p.y, -205), 205)]
    }
    func resetLamp() { time = 0; sweeps = true; enabled = true; intensity = 1; tint = .warm; receives = .both; applyLight() }
    func applyLight() {
        lamp?.isEnabled = enabled; blue?.isEnabled = secondLight
        lamp?.components[LightComponent.self]?.color = tint.color
        lamp?.components[LightComponent.self]?.intensity = Float(intensity)
        refresh()
    }
    func applyMaterials() {
        floor?.components[SpriteComponent.self]?.material.normalMap = normals ? floorNormal : nil
        floor?.components[SpriteComponent.self]?.material.lightingBitMask = receives.mask
        floor?.components[SpriteComponent.self]?.material.shadowedBitMask = shadows && receives != .unlit ? receives.mask : 0
        for entity in pool?.leasedEntities ?? [] {
            entity.components[SpriteComponent.self]?.material.normalMap = normals ? crateNormal : nil
            entity.components[SpriteComponent.self]?.material.shadowCastBitMask = shadows ? 3 : 0
            entity.components[SpriteComponent.self]?.material.shadowedBitMask = shadows ? 3 : 0
        }
        refresh()
    }
    private func spawnCrates() {
        let spots: [SIMD2<Float>] = [[-85, 10], [65, 90], [65, -105]]
        do {
            for (i, spot) in spots.enumerated() {
                _ = try pool?.acquire { entity in
                    entity.position = spot; entity.rotation = Float(i - 1) * 0.15; entity.scale = i == 1 ? [1.3, 0.75] : .one
                }
            }
        } catch { summary = "Could not spawn crates: \(error)" }
        applyMaterials()
    }
    func recycle() {
        do { for entity in pool?.leasedEntities ?? [] { try pool?.release(entity) }; recycled += 3; spawnCrates() }
        catch { summary = "Recycle failed: \(error)" }
    }
    private func refresh() {
        let count = (enabled ? 1 : 0) + (secondLight ? 1 : 0)
        summary = "\(count) \(count == 1 ? "light" : "lights") · \(receives.rawValue)\n\(recycled) crates recycled · \(normals ? "raised" : "flat") surfaces"
    }

    /// Diffuse pixels and matching tangent-space normals from the same height field.
    private static func surface(size: Int, tiled: Bool) -> (color: SpriteImage, normal: SpriteImage) {
        func height(_ x: Int, _ y: Int) -> Float {
            let period = tiled ? 32 : size
            let u = (x % period + period) % period, v = (y % period + period) % period
            let edge = Float(min(min(u, period - 1 - u), min(v, period - 1 - v)))
            return min(edge / 4, 1) * 1.5 + (tiled ? sin(Float(x) * 0.2) * cos(Float(y) * 0.3) * 0.25 : 0)
        }
        var diffuse: [UInt8] = [], normals: [UInt8] = []
        for y in 0..<size { for x in 0..<size {
            let h = height(x, y)
            let n = simd_normalize(SIMD3<Float>(-(height(x + 1, y) - height(x - 1, y)) * 1.4,
                                                (height(x, y + 1) - height(x, y - 1)) * 1.4, 1))
            normals += [n.x, n.y, n.z].map { UInt8(clamping: Int(($0 * 0.5 + 0.5) * 255)) } + [255]
            let shade = UInt8(clamping: Int(75 + h * 45))
            diffuse += tiled ? [shade, shade, UInt8(clamping: Int(shade) + 10), 255] : [shade, UInt8(clamping: Int(shade) * 3 / 4), UInt8(clamping: Int(shade) / 2), 255]
        } }
        return (SpriteImage(width: size, height: size, pixels: diffuse), SpriteImage(width: size, height: size, pixels: normals))
    }
}
