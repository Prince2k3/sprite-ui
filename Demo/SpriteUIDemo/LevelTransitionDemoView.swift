import Observation
import SpriteUI
import SwiftUI

/// One game surface, replaceable physics rooms, and a persistent player and camera.
@MainActor
struct LevelTransitionDemoView: View {
    @State private var model = LevelTransitionDemoModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("One world · two levels").font(.headline)
                GameView(viewports: []) { await model.install(in: $0) }
                    .frame(height: 260).clipped()
                    .accessibilityLabel("Cyan persistent player and a bouncing ball in the current level")
                    .accessibilityIdentifier("levels-game")
                LevelTransitionActivity(model: model)
                Picker("Transition", selection: $model.style) {
                    ForEach(LevelTransitionDemoModel.Style.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.loading)
                .accessibilityIdentifier("levels-style")
                Toggle("Fail next preparation", isOn: $model.failNext)
                    .disabled(model.loading)
                    .accessibilityIdentifier("levels-fail")
                HStack {
                    Button("Load \(model.nextID)") { model.loadNext() }
                        .disabled(model.loading || model.levels == nil)
                        .accessibilityIdentifier("levels-load")
                    // Cancel remains outside the game surface's automatic input gate.
                    Button("Cancel", role: .cancel) { model.cancel() }
                        .disabled(!model.loading)
                        .accessibilityIdentifier("levels-cancel")
                }
                HStack {
                    Button("Move player") { model.movePlayer() }
                    Button("Score +1") { model.addScore() }
                }
                .disabled(model.levels == nil || model.levels?.blocksInput == true)
                .accessibilityIdentifier("levels-player-controls")
                Text(model.message).font(.callout)
                    .accessibilityIdentifier("levels-result")
                Text("Preparation waits one second while the old room keeps running. Move or score during preparation. Fade takes 1.6 seconds total; crossfade blends one captured outgoing frame over the live incoming room. Cancel before installation keeps the old room; afterward it keeps the new room.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.bordered)
            .padding()
        }
        .background(.black).preferredColorScheme(.dark)
        .onDisappear { model.cancel() }
    }
}

/// Per-frame observation stays out of the game surface's configuration closure.
@MainActor
private struct LevelTransitionActivity: View {
    let model: LevelTransitionDemoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Level: \(model.levels?.currentID ?? "none") · \(model.phaseLabel)")
            Text("Player #\(model.player.id) · score \(model.score) · x \(model.playerX, specifier: "%.0f")")
            Text("Room updates: \(model.levelTicks) · disposed preparations/levels: \(model.disposals)")
        }
        .font(.caption.monospacedDigit())
        .accessibilityIdentifier("levels-state")
    }
}

private struct LevelDemoPlayerState: Component, Codable { var score = 0 }
private struct LevelDemoCounter: Component, Codable { var ticks = 0 }
private enum LevelDemoFailure: LocalizedError {
    case requested
    var errorDescription: String? { "Requested preparation failure; the outgoing level is unchanged." }
}

@MainActor @Observable
private final class LevelTransitionDemoModel {
    enum Style: String, CaseIterable {
        case instant = "Instant", fade = "Fade", crossFade = "Crossfade"
        var transition: LevelTransition {
            switch self {
            case .instant: .instant
            case .fade: .fade(duration: 1.6)
            case .crossFade: .crossFade(duration: 1.6)
            }
        }
    }

    var style = Style.fade
    var failNext = false
    private(set) var levels: LevelCoordinator?
    private(set) var message = "Preparing the first room…"
    private(set) var score = 0
    private(set) var playerX: Float = 0
    private(set) var levelTicks = 0
    private(set) var disposals = 0
    private(set) var requestPending = false
    @ObservationIgnored let player = Entity(name: "Persistent player", components:
        SpriteComponent(color: .cyan, size: [28, 28]), LevelDemoPlayerState())
    @ObservationIgnored private let camera = Entity(name: "Persistent camera", components:
        CameraComponent(smoothing: 0))
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var request = UUID()

    var nextID: String { levels?.currentID == "Garden" ? "Workshop" : "Garden" }
    var loading: Bool { requestPending || levels?.isLoading == true }
    var phaseLabel: String {
        guard let levels else { return "starting" }
        switch levels.phase {
        case .idle: return "idle"
        case .preparing: return "preparing · gameplay active"
        case .fadingOut: return "fading out · input blocked"
        case .installing: return "installing · input blocked"
        case .fadingIn: return "fading in · input blocked"
        case .crossFading: return "crossfading · input blocked"
        }
    }

    func install(in content: GameViewContent) async {
        guard levels?.world !== content.world else { return }
        cancel()
        LevelDemoPlayerState.registerComponent()
        LevelDemoCounter.registerComponent()
        content.renderer.backgroundColor = .black
        content.renderer.gravity = [0, -5]
        content.add(player)
        content.add(camera)
        player.position = [playerX, -42]
        player.zPosition = 5
        levels = content.levels
        do {
            // Promote before the first managed root is installed.
            try content.levels.preserve(player)
            try content.levels.preserve(camera)
        } catch {
            message = error.localizedDescription
            return
        }
        let task = startLoad(id: "Garden", transition: .instant, fail: false, delay: false)
        // Forward host cancellation to the model-owned task as well.
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func loadNext() {
        guard !loading else { return }
        let fail = failNext
        failNext = false
        startLoad(id: nextID, transition: style.transition, fail: fail, delay: true)
    }

    @discardableResult
    private func startLoad(id: String, transition: LevelTransition, fail: Bool, delay: Bool) -> Task<Void, Never> {
        loadTask?.cancel()
        let token = UUID()
        request = token
        requestPending = true
        message = "Preparing \(id)…"
        let task = Task { @MainActor [weak self] in
            guard let self, let levels else { return }
            defer {
                if request == token { requestPending = false; loadTask = nil }
            }
            do {
                try await levels.load(id: id, transition: transition) { [weak self] context in
                    guard let self else { throw CancellationError() }
                    context.onUnload { [weak self] in self?.disposals += 1 }
                    // A tiny existing app resource, loaded through this request's cache.
                    let chime = try await context.resources.audio(named: "coin.wav")
                    if delay { try await Task.sleep(for: .seconds(1)) }
                    try Task.checkCancellation()
                    if fail { throw LevelDemoFailure.requested }
                    let root = makeRoom(id: context.id)
                    context.camera = camera
                    context.retain(levels.world.subscribe(to: WorldEvents.Update.self) { [weak self, weak root] event in
                        guard let self, let root, root.world === event.world else { return }
                        root.components[LevelDemoCounter.self]?.ticks += 1
                        levelTicks = root.components[LevelDemoCounter.self]?.ticks ?? 0
                    })
                    context.onActivate { [weak self] root in
                        self?.levelTicks = 0
                        // The audio handle survives cache disposal while a voice uses it.
                        _ = try? root.playAudio(chime, volume: 0.15)
                    }
                    return root // Detached; the coordinator owns installation and removal.
                }
                guard request == token else { return }
                message = "\(levels.currentID ?? id) ready. Player identity and score retained."
            } catch is CancellationError {
                guard request == token else { return }
                message = "Cancelled. Current room: \(levels.currentID ?? "none")."
            } catch {
                guard request == token else { return }
                message = error.localizedDescription
            }
        }
        loadTask = task
        return task
    }

    func cancel() {
        loadTask?.cancel()
        levels?.cancel()
    }

    func movePlayer() {
        guard let levels, !levels.blocksInput else { return }
        playerX = playerX >= 84 ? -84 : playerX + 28
        player.position.x = playerX
    }

    func addScore() {
        guard let levels, !levels.blocksInput else { return }
        player.components[LevelDemoPlayerState.self]?.score += 1
        score = player.components[LevelDemoPlayerState.self]?.score ?? 0
    }

    private func makeRoom(id: String) -> Entity {
        let garden = id == "Garden"
        let root = Entity(name: id, components: LevelDemoCounter())
        let background = Entity(components:
            SpriteComponent(color: garden ? Color(red: 0.05, green: 0.2, blue: 0.16) : Color(red: 0.21, green: 0.1, blue: 0.06), size: [1600, 1200]))
        background.zPosition = -10
        root.addChild(background)
        let floor = Entity(name: "Room floor", components:
            SpriteComponent(color: garden ? .mint : .orange, size: [280, 12]),
            PhysicsBodyComponent(shape: .rectangle(size: [280, 12]), isDynamic: false))
        floor.position = [0, -76]
        root.addChild(floor)
        let ball = Entity(name: "Level-owned bouncing ball", components:
            SpriteComponent(image: LevelDemoArtwork.ball(), size: [22, 22], tint: garden ? .yellow : .pink, tintAmount: 1),
            PhysicsBodyComponent(shape: .circle(radius: 11), restitution: 0.9))
        ball.position = [garden ? -64 : 64, 64]
        root.addChild(ball)
        return root
    }
}

/// A small deterministic RGBA disc, with no app-level helpers or assets.
private enum LevelDemoArtwork {
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
