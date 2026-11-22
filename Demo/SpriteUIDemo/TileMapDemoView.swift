import simd
import SpriteUI
import SwiftUI

/// The Tile maps milestone: `Dungeon.sks` holds a tile map painted the way Xcode's tile
/// editor would, with `walkable` and `cost` in the tile definitions' User Data. It loads
/// as a `TileMapComponent`, which turns straight into a `GridGraph`.
///
/// Tap to send the hero there: walls and water block it, and it goes around mud, which
/// costs 4. In Build mode a tap raises or knocks down a wall, and the hero re-plans.
struct TileMapDemoView: View {
    @State private var scene = DungeonScene()

    var body: some View {
        VStack(spacing: 0) {
            GameView { content in
                scene.build(in: content)
            }
            .gesture(SpatialTapGesture().onEnded { value in
                scene.tapped(atView: value.location)
            })
            .overlay(alignment: .top) {
                Text(scene.summary)
                    .font(.caption.bold().monospacedDigit())
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: .capsule)
                    .padding(.top, 8)
            }

            HStack {
                Picker("Tool", selection: $scene.tool) {
                    ForEach(DungeonScene.Tool.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Diagonal", isOn: $scene.allowsDiagonals)
                    .toggleStyle(.button)
                    .buttonStyle(.bordered)
                    .tint(.orange)
                Button("Reload") { scene.reload() }
                    .buttonStyle(.bordered)
                    .tint(.orange)
            }
            .font(.footnote)
            .padding()
        }
        .onChange(of: scene.allowsDiagonals) { scene.replan() }
        .background(scene.background)
        .preferredColorScheme(.dark)
    }
}

@MainActor
@Observable
final class DungeonScene {
    enum Tool: String, CaseIterable { case walk = "Walk", build = "Build" }

    var tool = Tool.walk
    var allowsDiagonals = false
    private(set) var summary = "loading"
    private(set) var background = Color.black

    @ObservationIgnored private var world: World?
    @ObservationIgnored private var renderer: SpriteRenderer?
    @ObservationIgnored private var level: Entity?
    @ObservationIgnored private var dungeon: Entity?
    @ObservationIgnored private var hero: Entity?
    @ObservationIgnored private var trail: Entity?
    @ObservationIgnored private var subscriptions: [EventSubscription] = []

    /// The cells still to walk through, next one first.
    @ObservationIgnored private var waypoints: [GridPoint] = []
    @ObservationIgnored private var goal: GridPoint?
    @ObservationIgnored private var foundTreasure = false

    private static let heroSpeed: Float = 110
    private static let disc = SpriteImage.disc(diameter: 64)

    func build(in content: GameViewContent) {
        world = content.world
        renderer = content.renderer
        subscriptions.append(content.world.subscribe(to: WorldEvents.Update.self) { [weak self] update in
            self?.walk(Float(update.deltaTime))
        })
        reload()
    }

    func reload() {
        if let level { world?.removeEntity(level) }
        waypoints = []
        goal = nil
        foundTreasure = false
        do {
            let level = try Entity.load(named: "Dungeon")
            if let scene = level.components[SceneComponent.self] { background = scene.backgroundColor }
            world?.addEntity(level)
            self.level = level
            dungeon = level.findEntity(named: "dungeon")

            let trail = Entity(name: "trail")
            trail.transform.zPosition = 2
            level.addChild(trail)
            self.trail = trail

            let hero = Entity(name: "hero", components: SpriteComponent(
                image: Self.disc, size: [22, 22], tint: .mint, tintAmount: 1
            ))
            hero.transform.zPosition = 3
            hero.position = level.findEntity(named: "start")?.position ?? .zero
            level.addChild(hero)
            self.hero = hero
        } catch {
            summary = "couldn't load Dungeon.sks: \(error)"
            return
        }
        updateSummary(cost: nil)
    }

    func tapped(atView point: CGPoint) {
        guard let renderer, let map, let space else { return }
        let cell = space.point(at: renderer.scenePoint(fromView: point))
        guard map.contains(column: cell.x, row: cell.y) else { return }
        switch tool {
        case .walk:
            goal = cell
            replan()
        case .build:
            toggleWall(at: cell)
        }
    }

    /// Finds a new path to the goal from wherever the hero is now.
    func replan() {
        guard let goal, let hero, let map, let space else { return }
        let graph = map.gridGraph(allowsDiagonals: allowsDiagonals)
        let start = space.point(at: hero.scenePosition)
        guard let path = graph.findPath(from: start, to: goal) else {
            waypoints = []
            drawTrail([])
            summary = "no way through to \(goal)"
            return
        }
        waypoints = Array(path.dropFirst())
        drawTrail(path)
        updateSummary(cost: path.dropFirst().reduce(0) { $0 + graph.cost(at: $1) })
    }

    // MARK: Private

    private var map: TileMapComponent? { dungeon?.components[TileMapComponent.self] }

    private var space: GridSpace? {
        guard let dungeon, let map else { return nil }
        return map.gridSpace(at: dungeon.scenePosition)
    }

    /// Raises a wall on floor, or knocks a wall down to floor. The outer wall stays.
    private func toggleWall(at cell: GridPoint) {
        guard let dungeon, var map = dungeon.components[TileMapComponent.self] else { return }
        guard cell.x > 0, cell.y > 0, cell.x < map.columns - 1, cell.y < map.rows - 1 else { return }
        guard let hero, let space, space.point(at: hero.scenePosition) != cell else { return }
        let isWall = map[cell.x, cell.y]?.name == "Wall"
        map.setTile(named: isWall ? "Floor" : "Wall", column: cell.x, row: cell.y)
        dungeon.components.set(map)
        if goal != nil { replan() }
    }

    /// Moves the hero toward the next waypoint, slower on tiles that cost more.
    private func walk(_ deltaTime: Float) {
        guard let hero, let space, let map, let next = waypoints.first else { return }
        let here = space.point(at: hero.scenePosition)
        let cost = map[here.x, here.y]?["cost"]?.float ?? 1
        var step = Self.heroSpeed / max(cost, 1) * deltaTime
        while step > 0, let next = waypoints.first {
            let target = space.position(of: next) - (hero.scenePosition - hero.position)
            let offset = target - hero.position
            let distance = simd_length(offset)
            if distance <= step {
                hero.position = target
                step -= distance
                waypoints.removeFirst()
                trail?.children.first?.removeFromParent()
            } else {
                hero.position += offset / distance * step
                step = 0
            }
        }
        _ = next
        if waypoints.isEmpty { arrived() }
    }

    private func arrived() {
        guard let hero, let space, let level, let treasure = level.findEntity(named: "treasure") else { return }
        if !foundTreasure, space.point(at: hero.scenePosition) == space.point(at: treasure.scenePosition) {
            foundTreasure = true
            withAnimation(.easeOut(duration: 0.4)) {
                treasure.transform.scale = [1.8, 1.8]
                treasure.components[SpriteComponent.self]?.opacity = 0
            }
        }
        updateSummary(cost: nil)
    }

    /// Small dots on each cell of the path still ahead.
    private func drawTrail(_ path: [GridPoint]) {
        guard let trail, let space, let level else { return }
        for dot in trail.children { dot.removeFromParent() }
        for cell in path.dropFirst() {
            let dot = Entity(components: SpriteComponent(image: Self.disc, size: [7, 7], tint: .yellow, tintAmount: 1, opacity: 0.8))
            dot.position = space.position(of: cell) - level.scenePosition
            trail.addChild(dot)
        }
    }

    private func updateSummary(cost: Float?) {
        guard let map else { return }
        let walls = map.cells.compactMap { $0 }.filter { map.tiles[$0].name == "Wall" }.count
        var text = "\(map.columns)×\(map.rows) tiles · \(map.tiles.count) kinds · \(walls) walls"
        if let cost { text += " · path cost \(Int(cost))" }
        if foundTreasure { text += " · treasure found!" }
        summary = text
    }
}
