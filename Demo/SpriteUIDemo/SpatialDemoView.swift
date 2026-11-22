import SpriteUI
import SwiftUI

/// The Spatial milestone: dots wander while the world's spatial index tracks them.
/// Drag to move the probe; dots within its radius light up and the nearest few turn
/// orange. Quadtree draws a `QuadTree` built from the same positions.
struct SpatialDemoView: View {
    @State private var scene = SpatialScene()
    @State private var size = CGSize(width: 400, height: 600)

    var body: some View {
        VStack(spacing: 0) {
            GameView { content in
                scene.build(in: content)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { newSize in
                size = newSize
                scene.resize(to: newSize)
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                scene.moveProbe(to: [
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

            VStack(spacing: 10) {
                HStack {
                    Text("Radius").font(.footnote)
                    Slider(value: $scene.radius, in: 20...200)
                    Text("\(Int(scene.radius))").font(.footnote.monospacedDigit()).frame(width: 32)
                }
                Picker("Find", selection: $scene.filter) {
                    ForEach(SpatialScene.Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                HStack {
                    Toggle("Quadtree", isOn: $scene.showsTree)
                    Toggle("Pause", isOn: $scene.paused)
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .tint(.orange)
                .font(.footnote)
            }
            .padding()
        }
        .onChange(of: scene.radius) { scene.applyControls() }
        .onChange(of: scene.filter) { scene.applyControls() }
        .onChange(of: scene.paused) { scene.applyControls() }
        .onChange(of: scene.showsTree) { scene.clearTreeIfHidden() }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}

// MARK: Demo components and systems

extension SpatialCategories {
    static let red = SpatialCategories(rawValue: 1 << 1)
    static let blue = SpatialCategories(rawValue: 1 << 2)
}

/// Moves an entity in a straight line, bouncing off the probe's bounds.
struct WanderComponent: Component {
    var velocity: SIMD2<Float>
    var baseColor: Color
}

/// The demo's settings, kept on the probe entity so systems can read them.
struct SpatialProbeComponent: Component {
    var radius: Float = 90
    var nearestCount = 5
    var categories = SpatialCategories.all
    var paused = false
    var bounds = BoundingBox(center: .zero, size: [360, 560])
}

enum SpatialProbeEvents {
    /// Published each frame after the probe's queries run.
    struct Scanned: Event {
        let inRange: Int
        let nearestDistance: Float?
    }
}

struct WanderSystem: System {
    private static let probes = EntityQuery(where: .has(SpatialProbeComponent.self))
    private static let wanderers = EntityQuery(where: .has(WanderComponent.self))

    init(world: World) {}

    mutating func update(context: UpdateContext) {
        guard let settings = context.entities(matching: Self.probes).first?.components[SpatialProbeComponent.self],
              !settings.paused
        else { return }
        let dt = Float(context.deltaTime)
        let bounds = settings.bounds
        for entity in context.entities(matching: Self.wanderers) {
            guard var wander = entity.components[WanderComponent.self] else { continue }
            var position = entity.position + wander.velocity * dt
            for axis in 0..<2 {
                if position[axis] < bounds.min[axis] { position[axis] = bounds.min[axis]; wander.velocity[axis] = abs(wander.velocity[axis]) }
                if position[axis] > bounds.max[axis] { position[axis] = bounds.max[axis]; wander.velocity[axis] = -abs(wander.velocity[axis]) }
            }
            entity.position = position
            entity.components[WanderComponent.self] = wander
        }
    }
}

/// Queries the spatial index around each probe and colors what it finds.
/// Runs after ``SpatialIndexSystem`` so the index is current.
struct ProbeSystem: System {
    private static let probes = EntityQuery(where: .has(SpatialProbeComponent.self))
    private static let wanderers = EntityQuery(where: .has(WanderComponent.self))

    init(world: World) {}

    mutating func update(context: UpdateContext) {
        let world = context.world
        guard let probe = context.entities(matching: Self.probes).first,
              let settings = probe.components[SpatialProbeComponent.self]
        else { return }

        let inRange = world.entities(within: settings.radius, of: probe.position, matching: settings.categories)
        let nearest = world.nearestEntities(
            to: probe.position, count: settings.nearestCount, matching: settings.categories
        )
        let inRangeIDs = Set(inRange.map(\.id))
        let nearestIDs = Set(nearest.map(\.id))

        for entity in context.entities(matching: Self.wanderers) {
            guard let wander = entity.components[WanderComponent.self] else { continue }
            let color: Color
            let size: SIMD2<Float>
            if nearestIDs.contains(entity.id) {
                color = .orange; size = [12, 12]
            } else if inRangeIDs.contains(entity.id) {
                color = .white; size = [10, 10]
            } else {
                color = wander.baseColor.opacity(0.55); size = [8, 8]
            }
            if entity.components[SpriteComponent.self]?.color != color {
                entity.components[SpriteComponent.self]?.color = color
                entity.components[SpriteComponent.self]?.size = size
            }
        }

        let distance = nearest.first.map { (($0.position - probe.position) * ($0.position - probe.position)).sum().squareRoot() }
        world.publish(SpatialProbeEvents.Scanned(inRange: inRange.count, nearestDistance: distance), from: probe)
    }
}

// MARK: Scene

@MainActor
@Observable
final class SpatialScene {
    enum Filter: String, CaseIterable {
        case all = "All", red = "Red", blue = "Blue"

        var categories: SpatialCategories {
            switch self {
            case .all: .all
            case .red: .red
            case .blue: .blue
            }
        }
    }

    static let dotCount = 150
    static let ringDots = 40

    // Reactions live in the view's `onChange`, not `didSet` (see MazeScene).
    var radius: Float = 90
    var filter = Filter.all
    var paused = false
    var showsTree = false
    private(set) var summary = "drag to move the probe"

    @ObservationIgnored private let probe = Entity(
        name: "probe",
        components: SpriteComponent(color: .white, size: [12, 12]), SpatialProbeComponent()
    )
    @ObservationIgnored private let ring = Entity(name: "ring")
    @ObservationIgnored private let treeLayer = Entity(name: "tree")
    @ObservationIgnored private var treeTiles: [Entity] = []
    @ObservationIgnored private var dots: [Entity] = []
    @ObservationIgnored private var world: World?
    @ObservationIgnored private var subscription: EventSubscription?
    @ObservationIgnored private var bounds = BoundingBox(center: .zero, size: [360, 560])

    init() {
        var rng = SeededGenerator(seed: 2024)
        for i in 0..<Self.dotCount {
            let isRed = i.isMultiple(of: 3)
            let base: Color = isRed ? .red : .cyan
            let angle = Float.random(in: 0..<(2 * .pi), using: &rng)
            let speed = Float.random(in: 15...60, using: &rng)
            let dot = Entity(
                name: "dot \(i)",
                components: SpriteComponent(color: base.opacity(0.55), size: [8, 8]),
                WanderComponent(velocity: [cos(angle), sin(angle)] * speed, baseColor: base),
                SpatialIndexComponent(categories: isRed ? .red : .blue)
            )
            dot.position = [
                Float.random(in: bounds.min.x...bounds.max.x, using: &rng),
                Float.random(in: bounds.min.y...bounds.max.y, using: &rng),
            ]
            dot.transform.zPosition = 1
            dots.append(dot)
        }
        probe.transform.rotation = .pi / 4
        probe.transform.zPosition = 3
        ring.transform.zPosition = 2
        for _ in 0..<Self.ringDots {
            ring.addChild(Entity(components: SpriteComponent(color: .white.opacity(0.6), size: [3, 3])))
        }
        layoutRing()
    }

    func build(in content: GameViewContent) {
        let world = content.world
        self.world = world
        world.spatialCellSize = 48
        // Order matters: move, then index, then query.
        world.addSystem(WanderSystem.self)
        world.addSystem(SpatialIndexSystem.self)
        world.addSystem(ProbeSystem.self)

        content.add(treeLayer)
        for dot in dots { content.add(dot) }
        content.add(probe)
        content.add(ring)
        applyControls()
        subscription = content.subscribe(to: SpatialProbeEvents.Scanned.self) { [weak self] event in
            self?.scanned(event)
        }
    }

    func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        bounds = BoundingBox(center: .zero, size: [Float(size.width) - 16, Float(size.height) - 16])
        probe.components[SpatialProbeComponent.self]?.bounds = bounds
    }

    func moveProbe(to point: SIMD2<Float>) {
        probe.position = point
        ring.position = point
    }

    func applyControls() {
        probe.components[SpatialProbeComponent.self]?.radius = radius
        probe.components[SpatialProbeComponent.self]?.categories = filter.categories
        probe.components[SpatialProbeComponent.self]?.paused = paused
        layoutRing()
    }

    func clearTreeIfHidden() {
        if !showsTree { for tile in treeTiles { tile.components[SpriteComponent.self]?.opacity = 0 } }
    }

    private func layoutRing() {
        for (i, dot) in ring.children.enumerated() {
            let angle = Float(i) / Float(Self.ringDots) * 2 * .pi
            dot.position = [cos(angle), sin(angle)] * radius
        }
    }

    private func scanned(_ event: SpatialProbeEvents.Scanned) {
        let nearest = event.nearestDistance.map { String(format: "%.0f", $0) } ?? "–"
        let text = "\(event.inRange) in range · nearest \(nearest) pt"
        if text != summary { summary = text }
        if showsTree { drawTree() }
    }

    /// Builds a quadtree from this frame's index and shows its leaves.
    private func drawTree() {
        guard let world else { return }
        var tree = QuadTree<Entity.ID>(bounds: bounds, nodeCapacity: 4, maxDepth: 6)
        for (id, position) in world.spatialIndex.elements { tree.insert(id, at: position) }
        let leaves = tree.leafBounds

        while treeTiles.count < leaves.count {
            let tile = Entity(components: SpriteComponent(color: Color(white: 0.16), size: [1, 1]))
            treeLayer.addChild(tile)
            treeTiles.append(tile)
        }
        for (i, tile) in treeTiles.enumerated() {
            guard i < leaves.count else {
                tile.components[SpriteComponent.self]?.opacity = 0
                continue
            }
            let leaf = leaves[i]
            // Inset so the gaps between tiles read as the tree's grid lines.
            let size = SIMD2(max(leaf.size.x - 2, 1), max(leaf.size.y - 2, 1))
            if tile.position != leaf.center { tile.position = leaf.center }
            if tile.components[SpriteComponent.self]?.size != size {
                tile.components[SpriteComponent.self]?.size = size
            }
            if tile.components[SpriteComponent.self]?.opacity != 1 {
                tile.components[SpriteComponent.self]?.opacity = 1
            }
        }
    }
}
