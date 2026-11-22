import SpriteUI
import SwiftUI

/// The Obstacles and NavigationMesh milestones: a room of polygon walls, with
/// either an `ObstacleGraph` or a `NavigationMesh` around them. Tap anywhere to
/// send the unit there: it plans a path around the padded walls (orange), shown
/// with the corner graph or the mesh's triangles (blue), and steers along it. The
/// radius slider re-pads everything; at larger sizes the narrow gap at the bottom closes.
struct ObstacleDemoView: View {
    @State private var scene = ObstacleScene()
    @State private var size = CGSize(width: 400, height: 600)

    var body: some View {
        VStack(spacing: 0) {
            GameView { content in
                scene.build(in: content)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .gesture(SpatialTapGesture().onEnded { value in
                scene.send(to: [
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
                    Slider(value: $scene.unitRadius, in: 4...24, step: 1)
                    Text("\(Int(scene.unitRadius))").font(.footnote.monospacedDigit()).frame(width: 28)
                }
                Picker("Planner", selection: $scene.planner) {
                    ForEach(ObstacleScene.Planner.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                HStack {
                    Toggle("Show", isOn: $scene.showsGraph)
                    Button("Move crate") { scene.moveCrate() }
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .tint(.orange)
                .font(.footnote)
            }
            .padding()
        }
        .onChange(of: scene.unitRadius) { scene.resizeUnit() }
        .onChange(of: scene.showsGraph) { scene.redraw() }
        .onChange(of: scene.planner) { scene.rebuildGraph() }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}

// MARK: Scene

@MainActor
@Observable
final class ObstacleScene {
    // Reactions live in the view's `onChange`, not `didSet` (see MazeScene).
    enum Planner: String, CaseIterable { case graph = "Obstacle graph", mesh = "Navigation mesh" }

    var unitRadius: Float = 10
    var planner = Planner.graph
    var showsGraph = true
    private(set) var summary = "tap to send the unit"

    @ObservationIgnored private var world: World?
    @ObservationIgnored private var graph = ObstacleGraph()
    @ObservationIgnored private var mesh = NavigationMesh(bounds: ObstacleScene.room)
    @ObservationIgnored private var goal: SIMD2<Float>?
    @ObservationIgnored private var path: [SIMD2<Float>] = []
    @ObservationIgnored private var walls: [Entity] = []
    @ObservationIgnored private let crate = Entity(name: "crate")
    @ObservationIgnored private var crateSpot = 0
    @ObservationIgnored private let lines = Entity(name: "lines")
    @ObservationIgnored private let goalMarker = Entity(
        name: "goal", components: SpriteComponent(color: .yellow, size: [10, 10], opacity: 0)
    )
    @ObservationIgnored private let unit = Entity(name: "unit")

    private static let wallColor = Color(white: 0.55)
    /// The floor inside the outer walls.
    private static let room = BoundingBox(center: .zero, size: [348, 512])
    private static let crateSpots: [(SIMD2<Float>, Float)] = [([90, 30], .pi / 5), ([10, 200], 0), ([-110, -60], .pi / 8)]
    private static let disc = SpriteImage.disc(diameter: 64)

    init() {
        // The room: outer walls, two half walls, an L, two pillars with a narrow gap.
        addWall(center: [0, 262], size: [372, 12])
        addWall(center: [0, -262], size: [372, 12])
        addWall(center: [-180, 0], size: [12, 536])
        addWall(center: [180, 0], size: [12, 536])
        addWall(center: [-67, 130], size: [214, 12])
        addWall(center: [67, -110], size: [214, 12])
        addWall(center: [-130, -195], size: [88, 36])
        addWall(center: [-30, -195], size: [60, 36])   // 32 point gap to its left

        // A concave L, one polygon drawn as two rectangles.
        let l = Entity(name: "L")
        l.position = [-60, 10]
        l.components.set(PolygonObstacleComponent(points: [[-40, -40], [40, -40], [40, -20], [-20, -20], [-20, 40], [-40, 40]]))
        for (center, size) in [(SIMD2<Float>(0, -30), SIMD2<Float>(80, 20)), ([-30, 10], [20, 60])] {
            let piece = Entity(components: SpriteComponent(color: Self.wallColor, size: size))
            piece.position = center
            l.addChild(piece)
        }
        walls.append(l)

        crate.components.set(PolygonObstacleComponent(rectangle: [54, 54]))
        crate.components.set(SpriteComponent(color: .brown, size: [54, 54]))
        walls.append(crate)
        placeCrate()

        unit.position = [140, 220]
        unit.transform.zPosition = 4
        unit.components.set(SpriteComponent(image: Self.disc, size: [20, 20], tint: .cyan, tintAmount: 1))
        unit.components.set(SteeringComponent(maxSpeed: 110, maxForce: 330, radius: unitRadius))
        goalMarker.transform.rotation = .pi / 4
        goalMarker.transform.zPosition = 3
        lines.transform.zPosition = 2
    }

    func build(in content: GameViewContent) {
        world = content.world
        content.world.addSystem(SteeringSystem.self)
        for wall in walls { content.add(wall) }
        content.add(lines)
        content.add(goalMarker)
        content.add(unit)
        resizeUnit()
    }

    func send(to point: SIMD2<Float>) {
        goal = point
        goalMarker.position = point
        goalMarker.components[SpriteComponent.self]?.opacity = 1
        replan()
    }

    func moveCrate() {
        crateSpot = (crateSpot + 1) % Self.crateSpots.count
        placeCrate()
        rebuildGraph()
    }

    func resizeUnit() {
        unit.components[SpriteComponent.self]?.size = [unitRadius * 2, unitRadius * 2]
        unit.components[SteeringComponent.self]?.radius = unitRadius
        rebuildGraph()
    }

    func redraw() {
        var segments: [(SIMD2<Float>, SIMD2<Float>, Color, Float)] = []
        if showsGraph {
            switch planner {
            case .graph: for (a, b) in graph.connections { segments.append((a, b, .blue.opacity(0.45), 1)) }
            case .mesh: for (a, b) in mesh.edges { segments.append((a, b, .blue.opacity(0.6), 1)) }
            }
            for padded in graph.paddedObstacles {
                for (a, b) in padded.edges { segments.append((a, b, .orange.opacity(0.8), 1.5)) }
            }
        }
        for (a, b) in zip(path, path.dropFirst()) { segments.append((a, b, .yellow, 3)) }

        while lines.children.count < segments.count {
            lines.addChild(Entity(components: SpriteComponent(color: .white, size: [1, 1])))
        }
        for (i, line) in lines.children.enumerated() {
            guard i < segments.count else {
                line.components[SpriteComponent.self]?.opacity = 0
                continue
            }
            let (a, b, color, width) = segments[i]
            let offset = b - a
            line.position = (a + b) / 2
            line.transform.rotation = atan2(offset.y, offset.x)
            line.transform.zPosition = width > 2 ? 1 : 0
            line.components[SpriteComponent.self] = SpriteComponent(
                color: color, size: [(offset.x * offset.x + offset.y * offset.y).squareRoot(), width]
            )
        }
    }

    // MARK: Private

    private func addWall(center: SIMD2<Float>, size: SIMD2<Float>) {
        let wall = Entity(components: SpriteComponent(color: Self.wallColor, size: size), PolygonObstacleComponent(rectangle: size))
        wall.position = center
        walls.append(wall)
    }

    private func placeCrate() {
        let (position, rotation) = Self.crateSpots[crateSpot]
        crate.position = position
        crate.transform.rotation = rotation
    }

    /// A little more padding than the unit's radius, so steering has room to wobble.
    func rebuildGraph() {
        guard let world else { return }
        let padding = unitRadius + 2
        graph = world.obstacleGraph(bufferRadius: padding)
        if planner == .mesh {
            mesh = world.navigationMesh(bounds: Self.room, bufferRadius: padding)
        }
        replan()
    }

    private func replan() {
        guard let goal else { return redraw() }
        let start = unit.position
        let route = planner == .graph ? graph.findPath(from: start, to: goal) : mesh.findPath(from: start, to: goal)
        guard let route else {
            path = []
            let walkable = planner == .graph ? graph.isWalkable(goal) : mesh.isWalkable(goal)
            summary = walkable ? "no way there" : "too close to a wall"
            setGoals([.init(.arrive(.point(start), slowingRadius: 30))])
            return redraw()
        }
        path = route
        let length = zip(route, route.dropFirst()).reduce(Float(0)) { total, pair in
            let d = pair.1 - pair.0
            return total + (d.x * d.x + d.y * d.y).squareRoot()
        }
        let size = planner == .graph ? "\(graph.nodes.count) nodes" : "\(mesh.triangles.count) triangles"
        summary = "\(max(route.count - 2, 0)) corners · \(Int(length)) pt · \(size)"
        setGoals([
            .init(.follow(SteeringPath(points: route, radius: 4), lookAhead: 0.25)),
            .init(.avoidObstacles(lookAhead: 0.4), weight: 1.5),
        ])
        redraw()
    }

    private func setGoals(_ goals: [SteeringGoal]) {
        unit.components[SteeringComponent.self]?.goals = goals
    }
}
