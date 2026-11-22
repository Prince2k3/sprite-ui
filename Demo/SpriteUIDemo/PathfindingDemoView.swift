import SpriteUI
import SwiftUI
import simd

/// The Pathfinding milestone: tap a floor tile to send the agent there along an A* path.
/// Switch to Walls or Mud to edit the grid; the agent re-plans if its route is affected.
struct PathfindingDemoView: View {
    @State private var scene = MazeScene()

    var body: some View {
        VStack(spacing: 0) {
            GameView { content in
                scene.build(in: content)
            }
            .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { value in
                scene.tapped(value.entity)
            })
            .overlay(alignment: .top) {
                Text(scene.summary)
                    .font(.caption.bold().monospacedDigit())
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: .capsule)
                    .padding(.top, 8)
            }

            VStack(spacing: 10) {
                Picker("Tool", selection: $scene.tool) {
                    ForEach(MazeScene.Tool.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                HStack {
                    Toggle("Smooth", isOn: $scene.smooths)
                    Toggle("Diagonal", isOn: $scene.allowsDiagonals)
                    Toggle("Heat", isOn: $scene.showsHeat)
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .tint(.orange)
                .font(.footnote)
            }
            .padding()
        }
        .onChange(of: scene.smooths) { scene.replan() }
        .onChange(of: scene.allowsDiagonals) { scene.replan() }
        .onChange(of: scene.showsHeat) { scene.recolor() }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}

@MainActor
@Observable
final class MazeScene {
    enum Tool: String, CaseIterable { case move = "Move", walls = "Walls", mud = "Mud" }

    static let columns = 9, rows = 13
    static let cellSize: Float = 36
    static let mudCost: Float = 5

    var tool = Tool.move
    // Reactions to these live in the view's `onChange`: a `didSet` here would run inside
    // the binding's write and re-read the property, which is an exclusivity violation.
    var smooths = true
    var allowsDiagonals = true
    var showsHeat = false
    private(set) var summary = "tap a tile"

    @ObservationIgnored private var grid = GridGraph(width: columns, height: rows)
    @ObservationIgnored private let space: GridSpace
    @ObservationIgnored private var tiles: [GridPoint: Entity] = [:]
    @ObservationIgnored private var cells: [Entity.ID: GridPoint] = [:]
    @ObservationIgnored private let dots = Entity(name: "dots")
    @ObservationIgnored private var goal: GridPoint?
    @ObservationIgnored private var subscription: EventSubscription?
    @ObservationIgnored let agent = Entity(
        name: "agent",
        components: SpriteComponent(color: .orange, size: [22, 22])
    )

    init() {
        space = GridSpace(cellSize: Self.cellSize, centering: grid)
        // A few walls and a mud pool so the first path has something to route around.
        let walls = [(1, 9), (2, 9), (3, 9), (4, 9), (5, 9), (7, 6), (6, 6), (5, 6), (4, 6), (3, 6),
                     (1, 3), (2, 3), (3, 3), (4, 3), (5, 3)]
        for (x, y) in walls { grid.setWalkable(false, at: GridPoint(x, y)) }
        for x in 3...6 { for y in 10...11 { grid.setCost(Self.mudCost, at: GridPoint(x, y)) } }

        for point in grid.points {
            let tile = Entity(
                name: "tile \(point)",
                components: SpriteComponent(color: .gray, size: [Self.cellSize - 2, Self.cellSize - 2]),
                InputTargetComponent()
            )
            tile.position = space.position(of: point)
            tiles[point] = tile
            cells[tile.id] = point
        }
        dots.transform.zPosition = 1
        agent.transform.zPosition = 2
        agent.position = space.position(of: GridPoint(0, 0))
    }

    func build(in content: GameViewContent) {
        content.world.addSystem(PathFollowSystem.self)
        for tile in tiles.values { content.add(tile) }
        content.add(dots)
        content.add(agent)
        subscription = content.subscribe(to: PathEvents.DidFinish.self) { [weak self] _ in
            self?.clearDots()
            self?.recolor()
        }
        recolor()
    }

    func tapped(_ tile: Entity) {
        guard let point = cells[tile.id] else { return }
        switch tool {
        case .move:
            goal = point
            replan()
        case .walls:
            guard point != agentCell else { return }
            grid.setWalkable(!grid.isWalkable(point), at: point)
            if point == goal { goal = nil; agent.stopFollowingPath(); clearDots() }
            replan()
        case .mud:
            guard grid.isWalkable(point) else { return }
            grid.setCost(grid.cost(at: point) > 1 ? 1 : Self.mudCost, at: point)
            replan()
        }
    }

    /// The cell the agent is in, or the nearest open one if it's clipping a corner.
    private var agentCell: GridPoint {
        let cell = space.point(at: agent.position)
        if grid.isWalkable(cell) { return cell }
        return grid.points
            .filter(grid.isWalkable)
            .min { simd_distance(space.position(of: $0), agent.position) < simd_distance(space.position(of: $1), agent.position) }
            ?? cell
    }

    /// Plans from where the agent is now to `goal`, and starts it moving.
    func replan() {
        grid.allowsDiagonals = allowsDiagonals
        defer { recolor() }
        guard let goal else { return }
        let start = agentCell
        guard grid.isWalkable(goal), let path = grid.findPath(from: start, to: goal) else {
            agent.stopFollowingPath()
            clearDots()
            summary = "no path to \(goal)"
            return
        }
        let route = smooths ? grid.smoothed(path) : path
        let cost = zip(path, path.dropFirst()).reduce(Float(0)) { total, step in
            total + (grid.neighbors(of: step.0).first { $0.to == step.1 }?.cost ?? 0)
        }
        summary = String(format: "%d cells · %d waypoints · cost %.1f", path.count, route.count, cost)

        drawDots(path: path, route: route)
        if route.count > 1 {
            agent.follow(space.positions(along: Array(route.dropFirst())), speed: 150, orientsToPath: true)
        }
    }

    private func drawDots(path: [GridPoint], route: [GridPoint]) {
        clearDots()
        for point in path {
            let dot = Entity(components: SpriteComponent(color: .white.opacity(0.35), size: [6, 6]))
            dot.position = space.position(of: point)
            dots.addChild(dot)
        }
        for point in route.dropFirst() {
            let corner = Entity(components: SpriteComponent(color: .yellow, size: [10, 10]))
            corner.position = space.position(of: point)
            corner.transform.rotation = .pi / 4
            dots.addChild(corner)
        }
    }

    private func clearDots() {
        for dot in dots.children { dot.removeFromParent() }
    }

    /// Floor, walls and mud — or, with Heat on, each floor tile's distance from the agent.
    func recolor() {
        let heat = showsHeat ? grid.costMap(from: agentCell) : nil
        let maxCost = heat?.nodes.compactMap { heat?.cost(to: $0) }.max() ?? 1
        for (point, tile) in tiles {
            let color: Color
            if !grid.isWalkable(point) {
                color = Color(white: 0.08)
            } else if let heat, let cost = heat.cost(to: point) {
                let t = Double(cost / max(maxCost, 1))
                color = Color(hue: 0.62 - 0.62 * t, saturation: 0.75, brightness: 0.55)
            } else if grid.cost(at: point) > 1 {
                color = Color(red: 0.42, green: 0.3, blue: 0.16)
            } else {
                color = Color(white: 0.22)
            }
            tile.components[SpriteComponent.self]?.color = color
        }
    }
}
