import SpriteUI
import SwiftUI
import simd

struct CollisionDemoView: View {
    @State private var scene = CollisionDemoScene()
    var body: some View {
        VStack(spacing: 12) {
            GameView { content in scene.build(in: content) }
                .gesture(SpatialTapGesture().onEnded { scene.aim(at: $0.location) })
                .simultaneousGesture(DragGesture(minimumDistance: 0).targetedToEntity(where: .has(CollisionAimHandle.self)).onChanged { value in
                    if let position = value.convertIfAvailable(value.location, to: .scene) { scene.setGoal(position) }
                })
                .overlay(alignment: .top) {
                    Text(scene.summary).font(.caption.monospaced()).padding(8).background(.ultraThinMaterial, in: Capsule())
                }
            VStack(spacing: 10) {
                Picker("Query", selection: $scene.mode) { ForEach(CollisionDemoScene.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                HStack {
                    Text("Radius \(Int(scene.radius))").font(.caption).frame(width: 70)
                    Slider(value: $scene.radius, in: 4...36)
                }
                HStack {
                    Toggle("Walls only", isOn: $scene.wallsOnly)
                    Toggle("Show hit area", isOn: $scene.showsArea)
                }.toggleStyle(.button)
                Text("Tap to aim or drag the orange dot. White lines show hit normals.").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal)
        }
        .padding(.vertical).background(Color.black).preferredColorScheme(.dark).tint(.orange)
        .onChange(of: scene.mode) { scene.refresh() }
        .onChange(of: scene.radius) { scene.refresh() }
        .onChange(of: scene.wallsOnly) { scene.refresh() }
        .onChange(of: scene.showsArea) { scene.refresh() }
    }
}

private struct CollisionAimHandle: Component {}

@MainActor @Observable
private final class CollisionDemoScene {
    enum Mode: String, CaseIterable { case ray = "Ray", overlap = "Overlap", sweep = "Sweep" }
    var mode = Mode.ray
    var radius: Float = 16
    var wallsOnly = false
    var showsArea = false
    var summary = "Tap to aim"
    @ObservationIgnored private var world: World?
    @ObservationIgnored private var renderer: SpriteRenderer?
    @ObservationIgnored private var marker: Entity?
    @ObservationIgnored private var overlay = Entity(name: "query drawing")
    @ObservationIgnored private var targets: [Entity] = []
    @ObservationIgnored private var colors: [Entity.ID: Color] = [:]
    private let origin = SIMD2<Float>(-130, -125)
    private var goal = SIMD2<Float>(125, 120)
    private let walls = CollisionGroup(rawValue: 1), actors = CollisionGroup(rawValue: 2), handles = CollisionGroup(rawValue: 4)

    func build(in content: GameViewContent) {
        world = content.scene; renderer = content.renderer
        let wall = Entity(name: "wall", components: CollisionComponent(shape: .rectangle(size: [12, 160]), filter: .init(group: walls)), SpriteComponent(color: .blue, size: [12, 160]))
        wall.position = [15, -5]; wall.rotation = -0.3
        let actor = Entity(name: "circle", components: CollisionComponent(shape: .circle(radius: 25), filter: .init(group: actors, mask: .none)), SpriteComponent(image: .disc(diameter: 64), size: [50, 50], tint: .cyan, tintAmount: 1))
        actor.position = [-55, 40]
        let polygon: [SIMD2<Float>] = [[-30, -20], [35, -15], [15, 30], [-20, 25]]
        let block = Entity(name: "polygon", components: CollisionComponent(shape: .polygon(polygon), filter: .init(group: walls)))
        block.position = [80, 85]
        for (a, b) in zip(polygon, polygon.dropFirst() + [polygon[0]]) { addLine(from: a, to: b, color: .purple, width: 5, parent: block) }
        for entity in [wall, actor, block] { content.add(entity); targets.append(entity) }
        colors[wall.id] = .blue; colors[actor.id] = .cyan
        let marker = Entity(name: "aim", components: CollisionAimHandle(), CollisionComponent(shape: .circle(radius: 32), filter: .init(group: handles)), InputTargetComponent(), SpriteComponent(image: .disc(diameter: 32), size: [14, 14], tint: .orange, tintAmount: 1))
        marker.position = goal; marker.zPosition = 20; content.add(marker); self.marker = marker
        overlay.zPosition = 10; content.add(overlay)
        refresh()
    }
    func aim(at point: CGPoint) { if let renderer { setGoal(renderer.scenePoint(fromView: point)) } }
    func setGoal(_ position: SIMD2<Float>) {
        goal = [min(155, max(-155, position.x)), min(165, max(-165, position.y))]
        marker?.position = goal; refresh()
    }
    func refresh() {
        guard let world else { return }
        for child in overlay.children { child.removeFromParent() }
        let filter = CollisionQueryFilter(mask: wallsOnly ? walls : walls.union(actors))
        let hits: [CollisionHit]
        switch mode {
        case .ray: hits = world.raycast(from: origin, to: goal, query: .all, filter: filter)
        case .overlap: hits = world.overlaps(shape: .circle(radius: radius), transform: .init(tx: goal.x, ty: goal.y), filter: filter)
        case .sweep: hits = world.sweep(shape: .circle(radius: radius), from: .init(tx: origin.x, ty: origin.y), to: goal, query: .all, filter: filter)
        }
        for entity in targets {
            if let color = colors[entity.id] { entity.components[SpriteComponent.self]?.color = hits.contains(where: { $0.entity === entity }) ? .yellow : color }
        }
        addLine(from: origin, to: goal, color: .yellow.opacity(0.65), width: 2, parent: overlay)
        addDisc(at: origin, size: 9, color: .white)
        if mode != .ray {
            let center = mode == .overlap ? goal : origin + (goal - origin) * (hits.first?.fraction ?? 1)
            outline(center: center, radius: radius, color: .yellow)
        }
        for hit in hits {
            addDisc(at: hit.position, size: 7, color: .red)
            if simd_length_squared(hit.normal) > 0 { addLine(from: hit.position, to: hit.position + hit.normal * 30, color: .white, width: 2, parent: overlay) }
        }
        if showsArea { outline(center: goal, radius: 32, color: .orange.opacity(0.4)) }
        let distance = hits.first.map { " · \(Int($0.distance.rounded())) pt" } ?? ""
        summary = "\(mode.rawValue) · \(hits.count) hits\(distance)"
    }
    private func outline(center: SIMD2<Float>, radius: Float, color: Color) {
        for i in 0..<40 {
            let a = Float(i) / 40 * 2 * .pi, b = Float(i + 1) / 40 * 2 * .pi
            addLine(from: center + [cos(a), sin(a)] * radius, to: center + [cos(b), sin(b)] * radius, color: color, width: 1.5, parent: overlay)
        }
    }
    private func addDisc(at position: SIMD2<Float>, size: Float, color: Color) {
        let disc = Entity(components: SpriteComponent(image: .disc(diameter: 16), size: [size, size], tint: color, tintAmount: 1))
        disc.position = position; overlay.addChild(disc)
    }
    private func addLine(from a: SIMD2<Float>, to b: SIMD2<Float>, color: Color, width: Float, parent: Entity) {
        let delta = b - a
        let entity = Entity(components: SpriteComponent(color: color, size: [simd_length(delta), width]))
        entity.position = (a + b) / 2; entity.rotation = atan2(delta.y, delta.x); parent.addChild(entity)
    }
}
