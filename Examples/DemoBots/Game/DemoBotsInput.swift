import Observation
import SpriteUI

/// View-owned input policy. Device adapters only supply controls; the match
/// receives synchronous, resolved movement and aiming commands.
@MainActor @Observable
final class DemoBotsInput {
    static let move = InputAction("move", kind: .axis2D)
    static let aim = InputAction("aim", kind: .axis2D)
    static let fire = InputAction("fire", kind: .button)
    static let pause = InputAction("pause", kind: .button)
    static let inspect = InputAction("inspect", kind: .button)
    static let debugPause = InputAction("debug-pause", kind: .button)
    static let closeInspection = InputAction("close-inspection", kind: .button)
    static let confirm = InputAction("confirm", kind: .button)
    static let selectLevel = InputAction("select-level", kind: .axis)

    static let moveDevice = InputDevice.virtual("demobots-move-stick")
    static let aimDevice = InputDevice.virtual("demobots-aim-stick")
    static let hudDevice = InputDevice.virtual("demobots-hud")

    let hub: PlayerInputHub
    let player: PlayerInputSession
    /// Compatibility access for existing action-level callers and tests.
    var input: InputController { player.input }
    var selectedLevel = 1
    /// Replaces only the touch controls, ending their captured gestures while
    /// the GameView, world, and player input session retain their identity.
    private(set) var surfaceInputRevision: UInt64 = 0
    @ObservationIgnored private let game: DemoBotsSession
    @ObservationIgnored private let toggleDebugPause: @MainActor () -> Void
    @ObservationIgnored private var subscription: InputSubscription?
    @ObservationIgnored private var deviceSubscription: InputDeviceSubscription?
    @ObservationIgnored private var previousFeedbackState: FeedbackState?
    @ObservationIgnored private var isInputActive = true
    @ObservationIgnored private var phase: DemoBotsPhase?
    @ObservationIgnored private var inspecting = false
    @ObservationIgnored private var lastMove = SIMD2<Float>.zero
    @ObservationIgnored private var lastAim = SIMD2<Float>.zero
    @ObservationIgnored private var lastFiring = false
    @ObservationIgnored private var lastSelectionDirection = 0
    @ObservationIgnored private var surfaceState: DemoBotsSurfaceLayout.SurfaceState?

    init(game: DemoBotsSession, hub: PlayerInputHub = PlayerInputHub(),
         toggleDebugPause: @escaping @MainActor () -> Void = {}) {
        self.game = game
        self.toggleDebugPause = toggleDebugPause
        self.hub = hub
        player = hub.addPlayer(named: "Player")
        for device in [InputDevice.keyboard, .pointer] {
            try? hub.assign(device, to: player)
        }
        for (device, name, presentations) in [
            (Self.moveDevice, "Move stick", [InputControl.virtual("move"): InputControlPresentation(label: "Move stick")]),
            (Self.aimDevice, "Aim stick", [.virtual("aim"): .init(label: "Aim stick"), .virtual("fire"): .init(label: "Aim + Debug", symbolName: "bolt.fill")]),
            (Self.hudDevice, "HUD", [.virtual("pause"): .init(label: "Pause", symbolName: "pause.fill"),
                                    .virtual("confirm"): .init(label: "Confirm", symbolName: "checkmark"),
                                    .virtual("inspect"): .init(label: "Scene tools", symbolName: "ladybug")]),
        ] {
            hub.connect(.init(id: device, name: name, presentations: presentations))
            try? hub.assign(device, to: player)
        }
        // Single-player policy belongs to the example, not the native adapter.
        deviceSubscription = hub.observe { [weak self] event in
            guard case .connected(let info) = event else { return }
            self?.assignControllerIfUnclaimed(info.id)
        }
        for info in hub.devices { assignControllerIfUnclaimed(info.id) }
        synchronizeContext()
        subscription = input.observe { [weak self] event in self?.receive(event) }
    }

    private static let shortcuts = [
        InputBinding(pause, control: .key("p")),
        InputBinding(pause, control: .key("escape")),
        InputBinding(pause, control: .gamepadButton(.menu)),
        InputBinding(pause, control: .virtual("pause")),
        InputBinding(inspect, control: .key("i")),
        InputBinding(inspect, control: .virtual("inspect")),
    ]

    static let gameplay = InputActionMap(name: "gameplay", bindings: [
        InputBinding(move, control: .key("w"), scale: [0, 1]),
        InputBinding(move, control: .key("up"), scale: [0, 1]),
        InputBinding(move, control: .key("s"), scale: [0, -1]),
        InputBinding(move, control: .key("down"), scale: [0, -1]),
        InputBinding(move, control: .key("a"), scale: [-1, 0]),
        InputBinding(move, control: .key("left"), scale: [-1, 0]),
        InputBinding(move, control: .key("d"), scale: [1, 0]),
        InputBinding(move, control: .key("right"), scale: [1, 0]),
        InputBinding(move, control: .gamepadAxis(.leftStick), deadZone: 0.15),
        InputBinding(move, control: .gamepadAxis(.dpad), deadZone: 0),
        InputBinding(move, control: .virtual("move")),
        InputBinding(aim, control: .gamepadAxis(.rightStick), deadZone: 0.15),
        InputBinding(aim, control: .virtual("aim")),
        InputBinding(fire, control: .key("f")),
        InputBinding(fire, control: .key("space")),
        InputBinding(fire, control: .gamepadButton(.south)),
        InputBinding(fire, control: .gamepadAxis(.rightTrigger), deadZone: 0.1),
        InputBinding(fire, control: .virtual("fire")),
    ] + shortcuts)

    private static let menu = InputActionMap(name: "menu", bindings: shortcuts + [
        InputBinding(confirm, control: .gamepadButton(.south)),
        InputBinding(confirm, control: .key("return")),
        InputBinding(confirm, control: .virtual("confirm")),
    ])
    private static let homeMenu = InputActionMap(name: "home", bindings: menu.bindings + [
        InputBinding(selectLevel, control: .key("left"), scale: [-1, 0]),
        InputBinding(selectLevel, control: .key("right"), scale: [1, 0]),
        InputBinding(selectLevel, control: .gamepadAxis(.dpad), scale: [1, 0]),
    ])
    private static let inspection = InputActionMap(name: "inspection", bindings: [
        InputBinding(inspect, control: .key("i")),
        InputBinding(inspect, control: .virtual("inspect")),
        InputBinding(closeInspection, control: .key("escape")),
        InputBinding(debugPause, control: .key("p")),
        InputBinding(debugPause, control: .gamepadButton(.menu)),
    ])

    /// Called immediately after UI match transitions, and on externally observed
    /// phase changes. Context replacement gates held sources until neutral.
    func synchronizeContext(reset: Bool = false) {
        guard reset || phase != game.phase || inspecting != game.isInspecting else { return }
        if reset { hub.cancelAll() }
        phase = game.phase
        inspecting = game.isInspecting
        let context = inspecting ? Self.inspection : (phase == .playing ? Self.gameplay : (phase == .home ? Self.homeMenu : Self.menu))
        input.setContexts([context])
        lastMove = .zero
        lastAim = .zero
        lastFiring = false
        lastSelectionDirection = 0
        synchronizeFeedback(reset: reset)
    }

    func moveStick(_ vector: SIMD2<Float>) {
        hub.submit([(.virtual("move"), .axis2D(vector))], device: Self.moveDevice)
    }

    func aimStick(_ vector: SIMD2<Float>, pressed: Bool) {
        hub.submit([
            (.virtual("aim"), .axis2D(vector)),
            (.virtual("fire"), .button(pressed)),
        ], device: Self.aimDevice)
    }

    func togglePause() { tap(.virtual("pause")) }
    func toggleInspection() { tap(.virtual("inspect")) }
    func confirmSelection() { tap(.virtual("confirm")) }

    func start(level: Int) { game.start(level: level); synchronizeContext(reset: true) }
    func loadCheckpoint() {
        player.stopFeedback()
        game.loadCheckpoint()
        synchronizeContext()
        synchronizeFeedback(reset: true)
    }
    func home() { game.home(); synchronizeContext() }

    func suspend() {
        player.stopFeedback()
        hub.cancelAll()
        game.pause()
        synchronizeContext()
    }

    /// Geometry invalidates held controls without changing match playback.
    /// Scale-only and inactive-reservation updates keep the same point space.
    func surfaceDidChange(_ surface: GameSurfaceGeometry) {
        let state = DemoBotsSurfaceLayout.SurfaceState(surface)
        if let previous = surfaceState, previous != state { cancelSurfaceInput() }
        surfaceState = state
        game.resize(surface.largestUsableRegion.size)
    }

    private func cancelSurfaceInput() {
        player.stopFeedback()
        hub.cancelAll()
        game.move(.zero)
        game.aim(.zero, firing: false)
        lastMove = .zero; lastAim = .zero; lastFiring = false
        surfaceInputRevision &+= 1
    }

    private func tap(_ control: InputControl) {
        hub.submit([(control, .button(true))], device: Self.hudDevice)
        hub.submit([(control, .button(false))], device: Self.hudDevice)
    }

    private func assignControllerIfUnclaimed(_ device: InputDevice) {
        guard case .controller = device, hub.owner(of: device) == nil else { return }
        try? hub.assign(device, to: player)
    }

    func prompt(for action: InputAction) -> InputPrompt? { player.prompt(for: action) }

    /// Read by SwiftUI observation; excludes beam depletion and frame timers.
    struct FeedbackState: Equatable {
        let phase: DemoBotsPhase
        let inspecting: Bool
        let playerID: Entity.ID?
        let badBots: Int
        let charge: Float
    }

    var feedbackState: FeedbackState {
        .init(phase: game.phase, inspecting: game.isInspecting, playerID: game.player?.id,
              badBots: game.badBots, charge: game.charge)
    }

    func setInputActive(_ active: Bool) {
        guard isInputActive != active else { return }
        isInputActive = active
        if !active { hub.cancelAll(); player.stopFeedback() }
        synchronizeFeedback(reset: true)
    }

    /// One pulse per observed event, with terminal outcomes taking precedence
    /// over repairs/damage published in the same HUD update. No per-frame loop.
    func synchronizeFeedback(reset: Bool = false) {
        let current = feedbackState
        let previous = previousFeedbackState
        previousFeedbackState = current
        guard !reset, isInputActive, hub.isEnabled, player.isEnabled,
              !current.inspecting, current.phase != .paused, current.phase != .home else {
            player.stopFeedback()
            return
        }
        guard let previous, previous.playerID == current.playerID,
              previous.phase == .playing, !previous.inspecting else { return }
        let feedback: ControllerFeedback?
        if current.phase == .won { feedback = .success }
        else if current.phase == .lost { feedback = .failure }
        else if current.charge < previous.charge { feedback = .impact }
        else if current.badBots < previous.badBots { feedback = .selection }
        else { feedback = nil }
        if let feedback { _ = player.playFeedback(feedback) }
    }

    private func receive(_ event: InputActionEvent) {
        if event.phase == .cancelled { player.stopFeedback() }

        if event.action == Self.move {
            let vector = input.value(for: Self.move).vector
            guard vector != lastMove else { return }
            lastMove = vector
            game.move(vector)
        } else if event.action == Self.aim || event.action == Self.fire {
            let vector = input.value(for: Self.aim).vector
            // Right-stick aiming fires automatically, like the touch aim stick.
            let firing = input.value(for: Self.fire).isPressed || vector != .zero
            guard vector != lastAim || firing != lastFiring else { return }
            lastAim = vector
            lastFiring = firing
            game.aim(vector, firing: firing)
        } else if event.action == Self.selectLevel {
            let scalar = input.value(for: Self.selectLevel).scalar
            let direction = scalar > 0.5 ? 1 : (scalar < -0.5 ? -1 : 0)
            if game.phase == .home, direction != 0, direction != lastSelectionDirection {
                selectedLevel = min(max(selectedLevel + direction, 1), 3)
            }
            lastSelectionDirection = direction
        } else if event.phase == .pressed, input.value(for: event.action).isPressed {
            switch event.action {
            case Self.confirm:
                switch game.phase {
                case .home: start(level: selectedLevel)
                case .paused: game.resume()
                case .won: start(level: game.levelNumber < 3 ? game.levelNumber + 1 : game.levelNumber)
                case .lost: start(level: game.levelNumber)
                case .playing: break
                }
            case Self.pause:
                game.phase == .playing ? game.pause() : game.resume()
            case Self.inspect:
                game.isInspecting ? game.endInspection() : game.beginInspection()
            case Self.closeInspection:
                game.endInspection()
            case Self.debugPause:
                toggleDebugPause()
            default: return
            }
            synchronizeContext()
        }
    }
}
