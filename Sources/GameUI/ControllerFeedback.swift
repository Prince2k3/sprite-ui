import CoreHaptics
import ECSCore
import Foundation
import GameController

/// Internal seam keeps controller hardware out of both public APIs and tests.
@MainActor
protocol ControllerFeedbackPlayback: AnyObject {
    func play(_ feedback: ControllerFeedback) throws
    func stop()
}

@MainActor
final class NativeControllerFeedback: InputFeedbackProvider {
    typealias Factory = @MainActor (GCController) -> (any ControllerFeedbackPlayback)?
    private let factory: Factory
    private var controllers: [InputDevice: GCController] = [:]
    private var playback: [InputDevice: any ControllerFeedbackPlayback] = [:]
    private var active = false

    init(factory: @escaping Factory = { controller in
        guard let engine = controller.haptics?.createEngine(withLocality: .default) else { return nil }
        return CoreHapticsControllerPlayback(engine: engine)
    }) { self.factory = factory }

    func register(_ controller: GCController, device: InputDevice) { controllers[device] = controller }

    func setActive(_ active: Bool) {
        self.active = active
        if !active { stopAll() }
    }

    func unregister(_ device: InputDevice) {
        controllers.removeValue(forKey: device)
        stop(for: device)
    }

    func play(_ feedback: ControllerFeedback, on device: InputDevice) -> InputFeedbackResult {
        guard case .controller = device else { return .unsupported }
        guard active, let controller = controllers[device] else { return .unavailable }
        stop(for: device)
        guard let player = factory(controller) else { return .unsupported }
        playback[device] = player
        do {
            try player.play(feedback)
            return .accepted
        } catch {
            stop(for: device)
            return .failed
        }
    }

    func stop(for device: InputDevice) { playback.removeValue(forKey: device)?.stop() }

    func stopAll() {
        let players = Array(playback.values)
        playback.removeAll()
        for player in players { player.stop() }
    }
}

@MainActor
private final class CoreHapticsControllerPlayback: ControllerFeedbackPlayback {
    private let engine: CHHapticEngine
    private var player: (any CHHapticPatternPlayer)?
    private var stopped = false

    init(engine: CHHapticEngine) {
        self.engine = engine
        engine.playsHapticsOnly = true
        engine.isAutoShutdownEnabled = true
        // These callbacks may run off the main thread. Never replay an old
        // request after interruption or reset; a subsequent request starts fresh.
        engine.stoppedHandler = { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        engine.resetHandler = { [weak self] in
            Task { @MainActor in self?.stop() }
        }
    }

    func play(_ feedback: ControllerFeedback) throws {
        guard !stopped else { return }
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: feedback.intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: feedback.sharpness)
        ], relativeTime: 0, duration: feedback.duration)
        let pattern = try CHHapticPattern(events: [event], parameters: [])
        try engine.start()
        let player = try engine.makePlayer(with: pattern)
        self.player = player
        try player.start(atTime: CHHapticTimeImmediate)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        engine.stop(completionHandler: nil)
    }
}
