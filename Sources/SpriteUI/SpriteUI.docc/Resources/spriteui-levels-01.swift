import Observation
import SpriteUI
import SwiftUI

private struct RoomCounter: Component, Codable { var ticks = 0 }

@MainActor @Observable
private final class LevelScene {
    private(set) var levels: LevelCoordinator?
    private(set) var ticks = 0
    private(set) var pending = false
    private(set) var message = "Starting…"
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    var nextID: String { levels?.currentID == "Garden" ? "Workshop" : "Garden" }

    func install(in content: GameViewContent) async {
        RoomCounter.registerComponent()
        content.renderer.backgroundColor = .black
        content.renderer.gravity = [0, -5]
        levels = content.levels
        let task = load("Garden")
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func loadNext() {
        guard !pending else { return }
        load(nextID)
    }

    @discardableResult
    private func load(_ id: String) -> Task<Void, Never> {
        pending = true
        let task = Task { @MainActor [weak self] in
            guard let self, let levels else { return }
            defer { pending = false; loadTask = nil }
            do {
                try await levels.load(id: id, transition: .instant) { [weak self] context in
                    let garden = context.id == "Garden"
                    let root = Entity(name: context.id, components: RoomCounter())
                    let backdrop = Entity(components:
                        SpriteComponent(color: garden ? .green.opacity(0.2) : .orange.opacity(0.2), size: [1600, 1200]))
                    backdrop.zPosition = -10
                    root.addChild(backdrop)
                    let floor = Entity(components:
                        SpriteComponent(color: garden ? .mint : .orange, size: [280, 12]),
                        PhysicsBodyComponent(shape: .rectangle(size: [280, 12]), isDynamic: false))
                    floor.position = [0, -76]
                    root.addChild(floor)
                    let ball = Entity(components:
                        SpriteComponent(image: LevelArtwork.ball(), size: [22, 22], tint: .yellow, tintAmount: 1),
                        PhysicsBodyComponent(shape: .circle(radius: 11), restitution: 0.9))
                    ball.position = [garden ? -64 : 64, 64]
                    root.addChild(ball)
                    // The callback exists while preparing, but only counts an attached room.
                    context.retain(levels.world.subscribe(to: WorldEvents.Update.self) { [weak self, weak root] event in
                        guard let root, root.world === event.world else { return }
                        root.components[RoomCounter.self]?.ticks += 1
                        self?.ticks = root.components[RoomCounter.self]?.ticks ?? 0
                    })
                    context.onActivate { [weak self] _ in self?.ticks = 0 }
                    return root // Do not add it to content yourself.
                }
                message = "\(id) ready"
            } catch is CancellationError {
                message = "Cancelled"
            } catch {
                message = error.localizedDescription
            }
        }
        loadTask = task
        return task
    }

    func stop() {
        loadTask?.cancel()
        levels?.cancel()
    }
}

@MainActor
private struct RoomActivity: View {
    let scene: LevelScene
    var body: some View {
        Text("\(scene.levels?.currentID ?? "none") · room updates \(scene.ticks)")
            .font(.caption.monospacedDigit())
    }
}

@MainActor
struct ContentView: View {
    @State private var scene = LevelScene()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GameView(viewports: []) { await scene.install(in: $0) }
                .frame(height: 260).clipped()
                .accessibilityLabel("Current room with a floor and bouncing ball")
            RoomActivity(scene: scene)
            Button("Load \(scene.nextID)") { scene.loadNext() }
                .buttonStyle(.bordered)
                .disabled(scene.pending || scene.levels == nil)
            Text(scene.message).font(.caption)
        }
        .padding().background(.black).preferredColorScheme(.dark)
        .onDisappear { scene.stop() }
    }
}

/// A small deterministic RGBA disc, with no app-level helpers or assets.
private enum LevelArtwork {
    static func ball() -> SpriteImage {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let dx = Float(x) + 0.5 - Float(side) / 2
                let dy = Float(y) + 0.5 - Float(side) / 2
                let offset = (y * side + x) * 4
                pixels[offset] = 255
                pixels[offset + 1] = 255
                pixels[offset + 2] = 255
                pixels[offset + 3] = dx * dx + dy * dy <= 256 ? 255 : 0
            }
        }
        return SpriteImage(width: side, height: side, pixels: pixels, smoothsScaling: false)
    }
}
