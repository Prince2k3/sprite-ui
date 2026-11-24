import Foundation
import Observation
import SpriteUI
import SwiftUI

@MainActor
struct InputReplayDemoView: View {
    @State private var model = ReplayDemoModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            ReplayDemoArena(model: model).frame(height: 250)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Record once. Replay every tick.").font(.title2.bold())
                    Text("Move the cyan actor, then fire to score and draw a new orange target from the seeded random stream. A quick press/release is preserved between ticks.")
                        .font(.caption).foregroundStyle(.secondary)
                    ReplayDemoControls(model: model)
                    ReplayDemoReadout(model: model)
                    Text("The arena is always 360 × 200 world units. Resizing or folding only reframes the camera. Checksums cover game state and the full random stream, independent of entity IDs, pixels, and camera zoom.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("New recordings use custom fixed rules at 60 Hz; loaded archives use their saved rate. This does not promise native physics determinism. Root resources need a custom state provider in games that save them.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(12)
            }
        }
        .background(.black).preferredColorScheme(.dark).tint(.cyan)
        .onAppear { model.setVisible(true, sceneActive: scenePhase == .active) }
        .onChange(of: scenePhase) { _, phase in model.setSceneActive(phase == .active) }
        .onDisappear { model.setVisible(false, sceneActive: scenePhase == .active) }
    }
}

/// Presentation preferences never change the canonical simulation bounds.
@MainActor
private struct ReplayDemoArena: View {
    let model: ReplayDemoModel

    var body: some View {
        GameView(viewports: [.init(id: "main", region: .largestUsable)],
                 rendering: GameRenderConfiguration(preferredFramesPerSecond: model.renderRate)) {
            model.install(in: $0)
        }
        .gameInput(model.input, isActive: model.canUseLiveInput)
        .onGameSurfaceChange { model.surfaceDidChange($0) }
        .clipped()
        .accessibilityLabel("Cyan player below an orange random target in a fixed logical arena")
        .accessibilityIdentifier("input-replay-arena")
    }
}

@MainActor
private struct ReplayDemoControls: View {
    @Bindable var model: ReplayDemoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Live movement", selection: Binding(get: { model.direction }, set: { model.move($0) })) {
                Text("Left").tag(-1)
                Text("Neutral").tag(0)
                Text("Right").tag(1)
            }.pickerStyle(.segmented).disabled(!model.canUseLiveInput)
            HStack {
                Button("Fire once") { model.fire() }
                Button("Release all") { model.releaseInput() }
            }.disabled(!model.canUseLiveInput)
            Text("Arena keyboard: A / D or arrows to move; Space to fire.")
                .font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack { recordButtons }
                VStack(alignment: .leading) { recordButtons }
            }
            ViewThatFits(in: .horizontal) {
                HStack { playbackButtons }
                VStack(alignment: .leading) { playbackButtons }
            }
            Picker("Playback speed", selection: Binding(get: { model.speed }, set: { model.setSpeed($0) })) {
                Text("½×").tag(0.5)
                Text("1×").tag(1.0)
                Text("2×").tag(2.0)
                Text("4×").tag(4.0)
            }.pickerStyle(.segmented).disabled(!model.canControlPlayback)
            Picker("Target render rate", selection: $model.renderRate) {
                ForEach([30, 60, 120], id: \.self) { Text("\($0) FPS").tag($0) }
            }.pickerStyle(.segmented)
            Text("Replay the same archive at 30 / 60 / 120 FPS and compare the final checksum. Render rate is a preference; fixed ticks and recorded input stay the same.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Alter score to prove divergence") { model.provokeDivergence() }
                .disabled(!model.canControlPlayback)
                .accessibilityIdentifier("input-replay-diverge")
            HStack {
                Button("Save in Documents") { model.save() }.disabled(!model.canSave)
                Button("Load & validate") { model.load() }.disabled(!model.canStart)
            }
            Text("File: Documents/input-replay-demo.json. Loading validates the archive; Replay restores its initial entities and random state. Stop keeps the current world and resumes neutral live input.")
                .font(.caption).foregroundStyle(.secondary)
        }.buttonStyle(.bordered)
    }

    @ViewBuilder private var recordButtons: some View {
        Button("Record") { model.startRecording() }.disabled(!model.canStart)
            .accessibilityIdentifier("input-replay-record")
        Button("Stop / Live") { model.stop() }.disabled(model.controller == nil || !model.isAvailable)
            .accessibilityIdentifier("input-replay-stop")
    }

    @ViewBuilder private var playbackButtons: some View {
        Button("Replay") { model.startPlayback() }.disabled(!model.canReplay)
            .accessibilityIdentifier("input-replay-play")
        Button(model.isPlaying ? "Pause" : "Play") { model.togglePlayback() }
            .disabled(!model.canControlPlayback)
        Button("One fixed tick") { model.step() }.disabled(!model.canStep)
            .accessibilityIdentifier("input-replay-step")
    }
}

@MainActor
private struct ReplayDemoReadout: View {
    let model: ReplayDemoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("State: \(model.stateLabel) · Relative frame \(model.relativeFrame) / \(model.totalFrames)")
            Text("World lifetime tick \(model.lifetimeTick) · \(model.fixedRate, specifier: "%.0f") Hz · Playback \(model.speed, specifier: "%.1f")×")
            Text("x \(model.game.playerX, specifier: "%.2f") · Target \(model.game.targetX, specifier: "%.2f")")
            Text("Score \(model.game.score) · Shots \(model.game.shots) · Random draw \(model.game.lastDraw, specifier: "%.6f")")
            Text("Current checksum: \(model.currentChecksum)")
            Text("\(model.checksumCount) archived frame checksums · \(model.matchStatus)")
            if let divergence = model.controller?.divergence {
                Text("Diverged at relative tick \(divergence.tick)").foregroundStyle(.orange)
                Text("Expected \(divergence.expected.description)\nActual   \(divergence.actual.description)")
                    .foregroundStyle(.orange).textSelection(.enabled)
            }
            if let error = model.controller?.lastError {
                Text("Replay error: \(String(describing: error))").foregroundStyle(.orange)
            }
            Text(model.status).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .font(.caption.monospacedDigit())
        .accessibilityIdentifier("input-replay-statistics")
    }
}

/// Every canonical value is saved on an ENTITY, not in the root runtime resource.
private struct ReplayDemoGameState: Component, Codable {
    var playerX: Float = 0
    var targetX: Float = 60
    var shotX: Float = 0
    var shotTicks = 0
    var score = 0
    var shots = 0
    var lastDraw = 0.0
    var ticks: UInt64 = 0
}

private struct ReplayDemoRuntimeReference: Component {
    let model: ReplayDemoModel
    @MainActor func cloned() -> Self? { nil }
}

private enum ReplayDemoError: LocalizedError {
    case missingWorld, missingGameState, notReady, invalidGameState
    var errorDescription: String? {
        switch self {
        case .missingWorld: "The demo world is no longer available."
        case .missingGameState: "The recording is missing the demo's player or game-state component."
        case .notReady: "The replay controller is not ready."
        case .invalidGameState: "The recording contains invalid demo game state."
        }
    }
}

@MainActor
private struct ReplayDemoSystem: System {
    static var phase: SystemPhase { .fixedSimulation }
    init(world: World) {}

    func update(context: UpdateContext) {
        guard let model = context.world.resources[ReplayDemoRuntimeReference.self]?.model,
              let controller = model.controller else { return }
        // One owner samples BEFORE every owned rule. No input consumption per entity.
        do {
            let sample = try controller.sample(for: context)
            // Finished controllers can return neutral; terminal worlds must not run rules.
            guard controller.state == .live || controller.state == .recording
                    || controller.state == .playing || controller.state == .paused else { return }
            try ReplayDemoModel.applyRules(sample, context: context)
            // Marks the owned rules complete. Core checksums after ALL fixed systems,
            // then handles divergence / EOF before another catch-up tick can begin.
            try controller.finishTick(context)
        } catch {
            context.world.isPaused = true
            model.report(error)
        }
    }
}

@MainActor @Observable
private final class ReplayDemoModel {
    static let moveAction = InputAction("replay-demo-move", kind: .axis)
    static let fireAction = InputAction("replay-demo-fire")
    private static let playerName = "Replay player"
    private static let targetName = "Replay target"
    private static let shotName = "Replay shot"
    private static let cameraName = "Replay camera"
    private static let moveDevice = InputDevice.virtual("replay-demo-move")
    private static let fireDevice = InputDevice.virtual("replay-demo-fire")

    let input = InputController(contexts: [InputActionMap(name: "Replay demo", bindings: [
        InputBinding(ReplayDemoModel.moveAction, control: .virtual("move")),
        InputBinding(ReplayDemoModel.moveAction, control: .key("a"), scale: [-1, 0]),
        InputBinding(ReplayDemoModel.moveAction, control: .key("left"), scale: [-1, 0]),
        InputBinding(ReplayDemoModel.moveAction, control: .key("d"), scale: [1, 0]),
        InputBinding(ReplayDemoModel.moveAction, control: .key("right"), scale: [1, 0]),
        InputBinding(ReplayDemoModel.fireAction, control: .virtual("fire")),
        InputBinding(ReplayDemoModel.fireAction, control: .key("space")),
        InputBinding(ReplayDemoModel.fireAction, control: .gamepadButton(.south))
    ])])
    private(set) var controller: InputReplayController?
    private(set) var archive: InputRecording?
    private(set) var checksumCount = 0
    private(set) var game = ReplayDemoGameState()
    private(set) var direction = 0
    private(set) var speed = 1.0
    var renderRate = 60
    private(set) var relativeFrame = 0
    private(set) var lifetimeTick: UInt64 = 0
    private(set) var fixedRate = 60.0
    private(set) var currentChecksum = "—"
    private(set) var status = "Record movement and a few shots, stop, then replay."
    private(set) var isAvailable = false
    @ObservationIgnored private weak var world: World?
    @ObservationIgnored private var subscriptions: [EventSubscription] = []
    @ObservationIgnored private var surface: GameSurfaceGeometry?
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var sceneActive = true
    @ObservationIgnored private var resumeLiveClock = false
    @ObservationIgnored private var recordingSession = false
    @ObservationIgnored private var trackingPlayback = false
    @ObservationIgnored private var sessionStartTick: UInt64 = 0

    var stateLabel: String { controller.map { String(describing: $0.state) } ?? "preparing" }
    var isPlaying: Bool { controller?.state == .playing }
    var canUseLiveInput: Bool {
        isAvailable && (controller?.state == .live || controller?.state == .recording)
    }
    var canStart: Bool { isAvailable && controller != nil && controller?.state != .recording }
    var canReplay: Bool { canStart && !(archive?.frames.isEmpty ?? true) }
    var canControlPlayback: Bool {
        isAvailable && (controller?.state == .playing || controller?.state == .paused)
    }
    var canStep: Bool { isAvailable && controller?.state == .paused }
    var canSave: Bool { archive != nil && controller?.state != .recording }
    var totalFrames: Int {
        recordingSession ? (controller?.recording?.frames.count ?? relativeFrame) : (archive?.frames.count ?? 0)
    }
    var matchStatus: String {
        if controller?.state == .diverged { return "checksum mismatch" }
        if controller?.state == .finished {
            return checksumCount > 0 ? "all recorded checksums matched" : "finished · archive has no checksums"
        }
        return "checksums checked at fixed-tick completion"
    }

    func install(in content: GameViewContent) {
        guard world !== content.world else { return }
        world = content.world
        let world = content.world
        content.renderer.backgroundColor = .black
        ReplayDemoGameState.registerComponent(named: "replay-demo-game-state-v1")
        world.fixedStep = FixedStepConfiguration(stepsPerSecond: 60, maximumCatchUpSteps: 8,
                                                maximumFrameDeltaTime: 0.25)
        world.random = SeededGenerator(seed: 2026)
        world.resources.set(ReplayDemoRuntimeReference(model: self))
        let floor = Entity(name: "Replay track", components: SpriteComponent(color: .white.opacity(0.25), size: [320, 2]))
        floor.position = [0, -60]
        world.addEntity(floor)
        let player = Entity(name: Self.playerName, components:
            SpriteComponent(color: .cyan, size: [22, 22]), ReplayDemoGameState())
        world.addEntity(player)
        world.addEntity(Entity(name: Self.targetName, components: SpriteComponent(color: .orange, size: [24, 24])))
        world.addEntity(Entity(name: Self.shotName, components: SpriteComponent(color: .yellow, size: [4, 70])))
        world.addEntity(Entity(name: Self.cameraName, components: CameraComponent(smoothing: 0)))
        Self.syncSprites(in: world, game: game)
        // The root keeps runtime references across restore. Its controller must
        // never retain the world through the application's checksum closure.
        controller = InputReplayController(world: world, input: input, maximumFrames: 36_000,
            checksum: { [weak world] in
                guard let world else { throw ReplayDemoError.missingWorld }
                return try Self.checksumData(in: world)
            })
        do { try world.systems.add(ReplayDemoSystem.self) }
        catch { report(error); world.isPaused = true }
        subscriptions = [content.subscribe(to: RenderingEvents.DidUpdate.self) { [weak self] _ in
            // Core has committed the checksum, divergence and EOF by this point.
            self?.refreshReadout()
        }]
        surfaceDidChange(content.surfaceGeometry)
        updateAvailability()
        refreshReadout()
    }

    static func applyRules(_ sample: FixedInputSample, context: UpdateContext) throws {
        // Never cache entities: default playback restore replaces their instances.
        guard let player = context.world.root.findEntity(named: playerName),
              var game = player.components[ReplayDemoGameState.self] else { throw ReplayDemoError.missingGameState }
        guard game.playerX.isFinite, abs(game.playerX) <= 150,
              game.targetX.isFinite, abs(game.targetX) <= 140,
              game.shotX.isFinite, game.lastDraw.isFinite,
              (0..<1).contains(game.lastDraw), (0...12).contains(game.shotTicks),
              game.score >= 0, game.score <= Int.max - 10_000,
              game.shots >= 0, game.shots < Int.max - 1_000, game.ticks < UInt64.max else {
            throw ReplayDemoError.invalidGameState
        }
        game.ticks += 1
        game.playerX = min(150, max(-150, game.playerX + sample.value(for: moveAction).scalar * 120 * Float(context.deltaTime)))
        game.shotTicks = max(0, game.shotTicks - 1)
        // Count transitions in order, including multiple quick taps in one tick.
        for event in sample.events where event.action == fireAction && event.phase == .pressed {
            game.shots += 1
            game.score += abs(game.playerX - game.targetX) < 24 ? 10 : 1
            game.shotX = game.playerX
            game.shotTicks = 12
            game.lastDraw = context.world.random.nextUnit()
            game.targetX = Float(game.lastDraw * 280 - 140)
        }
        player.components.set(game)
        syncSprites(in: context.world, game: game)
    }

    private static func syncSprites(in world: World, game: ReplayDemoGameState) {
        world.root.findEntity(named: playerName)?.position = [game.playerX, -46]
        world.root.findEntity(named: targetName)?.position = [game.targetX, 48]
        if let shot = world.root.findEntity(named: shotName) {
            shot.position = [game.shotX, 1]
            shot.components[SpriteComponent.self]?.opacity = game.shotTicks > 0 ? 1 : 0
        }
    }

    private struct ChecksumState: Encodable {
        let game: ReplayDemoGameState
        let random: SeededGenerator
    }

    private static func checksumData(in world: World) throws -> Data {
        guard let game = world.root.findEntity(named: playerName)?.components[ReplayDemoGameState.self] else {
            throw ReplayDemoError.missingGameState
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(ChecksumState(game: game, random: world.random))
    }

    private func refreshReadout() {
        guard let world else { return }
        if let state = world.root.findEntity(named: Self.playerName)?.components[ReplayDemoGameState.self] { game = state }
        lifetimeTick = world.fixedStepState.tick
        fixedRate = world.fixedStep?.stepsPerSecond ?? 60
        if recordingSession {
            relativeFrame = controller?.recording?.frames.count ?? 0
        } else if trackingPlayback {
            let elapsed = lifetimeTick >= sessionStartTick ? lifetimeTick - sessionStartTick : 0
            relativeFrame = Int(min(UInt64(archive?.frames.count ?? 0), elapsed))
        }
        do { currentChecksum = InputRecordingChecksum(data: try Self.checksumData(in: world)).description }
        catch { report(error) }
    }

    func surfaceDidChange(_ geometry: GameSurfaceGeometry) {
        surface = geometry
        fitCamera()
    }

    private func fitCamera() {
        guard let size = surface?.largestUsableRegion.size, size.width > 0, size.height > 0 else { return }
        world?.root.findEntity(named: Self.cameraName)?.components[CameraComponent.self]?.zoom =
            Float(min(size.width / 360, size.height / 200))
    }

    func move(_ direction: Int) {
        guard canUseLiveInput else { return }
        self.direction = direction
        input.setValue(.axis(Float(direction)), for: .virtual("move"), device: Self.moveDevice)
    }

    func fire() {
        guard canUseLiveInput else { return }
        input.setValue(.button(true), for: .virtual("fire"), device: Self.fireDevice)
        input.setValue(.button(false), for: .virtual("fire"), device: Self.fireDevice)
    }

    func releaseInput() {
        input.setValue(.axis(0), for: .virtual("move"), device: Self.moveDevice)
        input.setValue(.button(false), for: .virtual("fire"), device: Self.fireDevice)
        input.cancelAll()
        direction = 0
    }

    func startRecording() {
        perform {
            let controller = try requireController()
            try finalizeAndStop()
            releaseInput()
            world?.fixedStep = FixedStepConfiguration(stepsPerSecond: 60, maximumCatchUpSteps: 8,
                                                      maximumFrameDeltaTime: 0.25)
            try controller.startRecording()
            recordingSession = true
            trackingPlayback = false
            relativeFrame = 0
            status = "Recording at 60 Hz. Stop finalizes every completed tick; limit 36,000 frames."
        }
    }

    func stop() {
        perform {
            try finalizeAndStop()
            releaseInput()
            speed = 1
            status = "Live input resumed. The current world was kept."
        }
    }

    func startPlayback() {
        perform {
            guard let archive, !archive.frames.isEmpty else { throw ReplayDemoError.notReady }
            let controller = try requireController()
            try finalizeAndStop()
            try controller.setPlaybackSpeed(1)
            releaseInput()
            try controller.startPlayback(archive, paused: true)
            sessionStartTick = world?.fixedStepState.tick ?? 0
            trackingPlayback = true
            relativeFrame = 0
            speed = 1
            fitCamera() // Restored camera adopts THIS surface; game bounds stay fixed.
            status = "Initial state restored. Use Play or One fixed tick; live input is suppressed."
        }
    }

    func togglePlayback() {
        perform {
            let controller = try requireController()
            if controller.state == .playing { try controller.pause() }
            else { try controller.play() }
        }
    }

    func step() {
        perform { try requireController().step() }
    }

    func setSpeed(_ speed: Double) {
        perform {
            let controller = try requireController()
            try controller.setPlaybackSpeed(speed)
            self.speed = controller.playbackSpeed
        }
    }

    func provokeDivergence() {
        perform {
            guard let player = world?.root.findEntity(named: Self.playerName),
                  var game = player.components[ReplayDemoGameState.self] else { throw ReplayDemoError.missingGameState }
            let (score, overflow) = game.score.addingReportingOverflow(1)
            guard !overflow else { throw ReplayDemoError.invalidGameState }
            game.score = score
            player.components.set(game)
            status = "Score altered. The next completed playback tick should pause with a checksum mismatch."
        }
    }

    private func recordingURL() throws -> URL {
        let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        return directory.appendingPathComponent("input-replay-demo.json")
    }

    func save() {
        perform {
            guard let archive else { throw ReplayDemoError.notReady }
            let url = try recordingURL()
            try archive.write(to: url)
            status = "Saved \(archive.frames.count) frames: \(url.path)"
        }
    }

    func load() {
        perform {
            let loaded = try InputRecording(contentsOf: recordingURL())
            try finalizeAndStop()
            setArchive(loaded)
            relativeFrame = 0
            status = "Validated \(loaded.frames.count) frames (\(loaded.duration) seconds). Replay restores the loaded initial state."
        }
    }

    func setVisible(_ visible: Bool, sceneActive: Bool) {
        self.visible = visible
        self.sceneActive = sceneActive
        updateAvailability()
    }

    func setSceneActive(_ active: Bool) {
        sceneActive = active
        updateAvailability()
    }

    private func updateAvailability() {
        isAvailable = visible && sceneActive
        releaseInput()
        input.isEnabled = isAvailable
        guard let world else { return }
        if !isAvailable {
            // App owns inactivity policy. Never release the playback suppression lease.
            if controller?.state == .playing {
                do { try controller?.pause() } catch { report(error) }
            }
            if recordingSession {
                do {
                    try finalizeAndStop()
                    status = "Recording finalized on inactivity. Replay is ready when you return."
                } catch { report(error) }
            }
            if controller?.state == .live {
                resumeLiveClock = !world.isPaused || resumeLiveClock
                world.isPaused = true
            }
        } else if resumeLiveClock {
            world.isPaused = false
            resumeLiveClock = false
        }
    }

    private func requireController() throws -> InputReplayController {
        guard let controller else { throw ReplayDemoError.notReady }
        return controller
    }

    private func setArchive(_ recording: InputRecording?) {
        archive = recording
        checksumCount = recording?.frames.filter { $0.checksum != nil }.count ?? 0
    }

    private func finalizeAndStop() throws {
        let controller = try requireController()
        try controller.stop()
        if recordingSession {
            setArchive(controller.recording)
            relativeFrame = archive?.frames.count ?? 0
        }
        recordingSession = false
        trackingPlayback = false
        speed = controller.playbackSpeed
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { report(error) }
        refreshReadout()
    }

    func report(_ error: any Error) { status = "Error: \(error.localizedDescription)" }
}
