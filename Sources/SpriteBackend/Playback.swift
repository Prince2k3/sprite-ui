import AVFoundation
@_spi(Backend) import ECSCore
import Foundation
import Observation

/// The requested state of one voice or clip. Scene pause preserves this state.
public enum PlaybackState: String, Sendable { case playing, paused, stopped, completed, failed }
/// How many complete iterations to play. A count includes the first iteration.
public enum PlaybackRepeatMode: Hashable, Sendable { case once, count(Int), forever }
/// Why a playback stopped before reaching its end.
public enum PlaybackStopReason: Sendable { case user, replaced, removed }
/// A rejected playback configuration or unavailable audio device.
public enum PlaybackError: Error, Equatable, Sendable {
    case invalidOptions
    case audioUnavailable
    /// The audio backend supports combined controller × scene rates from 0.5 to 2.
    /// Unsupported rates fail explicitly, rather than silently losing clock sync.
    case unsupportedAudioRate(Double)
}

/// Looping and speed for a new clip or audio voice. Invalid options throw before
/// replacing an existing animation or starting a voice.
public struct PlaybackOptions: Sendable {
    public var repeatMode: PlaybackRepeatMode
    public var speed: Double
    public var startsPaused: Bool
    public init(repeatMode: PlaybackRepeatMode = .once, speed: Double = 1, startsPaused: Bool = false) {
        self.repeatMode = repeatMode; self.speed = speed; self.startsPaused = startsPaused
    }
    func validate(duration: Double) throws {
        guard speed.isFinite, speed > 0, duration.isFinite, duration > 0 else { throw PlaybackError.invalidOptions }
        if case .count(let count) = repeatMode {
            guard count > 0, (duration * Double(count)).isFinite else { throw PlaybackError.invalidOptions }
        }
    }
}

/// Typed playback events, also available without a rendering backend.
public enum PlaybackEvents {
    public struct Completed: Event { public let entity: Entity; public let controller: PlaybackController }
    public struct Stopped: Event { public let entity: Entity; public let controller: PlaybackController; public let reason: PlaybackStopReason }
    public struct Failed: Event { public let entity: Entity; public let controller: PlaybackController; public let error: PlaybackError }
}

/// A handle to one playback instance. Discarding the handle does not stop playback;
/// its entity owns it until it finishes. Stopped, completed, and failed handles are
/// terminal: play the resource again to create a fresh instance. Runtime controllers
/// are not saved in world snapshots; sprite snapshots keep the displayed texture.
@MainActor @Observable
public class PlaybackController {
    public let id = UUID()
    public let duration: TimeInterval
    public let repeatMode: PlaybackRepeatMode
    public private(set) var state = PlaybackState.playing
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var completedIterations: Int = 0
    public private(set) var error: PlaybackError?
    @ObservationIgnored weak var entity: Entity?
    private var elapsed: TimeInterval = 0
    private var sceneSuspended = true
    private var storedSpeed: Double
    public var speed: Double {
        get { storedSpeed }
        set { guard newValue.isFinite, newValue > 0 else { return }; storedSpeed = newValue; synchronize() }
    }
    public var isPlaying: Bool {
        state == .playing && !sceneSuspended && entity?.world != nil
    }
    var isTerminal: Bool { state == .stopped || state == .completed || state == .failed }

    init(entity: Entity, duration: TimeInterval, options: PlaybackOptions) {
        self.entity = entity; self.duration = duration; repeatMode = options.repeatMode; storedSpeed = options.speed
        state = options.startsPaused ? .paused : .playing
    }
    public func pause() { guard state == .playing else { return }; state = .paused; synchronize() }
    public func resume() { guard state == .paused else { return }; state = .playing; synchronize() }
    public func stop() { stop(reason: .user) }
    func stop(reason: PlaybackStopReason) {
        guard !isTerminal else { return }
        state = .stopped; terminate()
        if let entity, let world = entity.world { world.publish(PlaybackEvents.Stopped(entity: entity, controller: self, reason: reason), from: entity) }
    }
    func fail(_ error: PlaybackError) {
        guard !isTerminal else { return }
        self.error = error; state = .failed; terminate()
        if let entity, let world = entity.world { world.publish(PlaybackEvents.Failed(entity: entity, controller: self, error: error), from: entity) }
    }
    func synchronize() {
        guard !isTerminal else { return }
        let suspended = entity?.isActive != true || entity?.world?.isPaused != false || (entity?.world?.timeScale ?? 0) == 0
        if sceneSuspended != suspended { sceneSuspended = suspended }
        do { try apply() } catch { fail((error as? PlaybackError) ?? .audioUnavailable) }
    }
    func apply() throws {}
    func terminate() {}

    private func iterationCount(_ count: Double) -> Int {
        // Double(Int.max) rounds above the last representable Int on 64-bit.
        // Saturate before conversion, including enormous forever-loop steps.
        count >= Double(Int.max) ? Int.max : Int(max(0, count))
    }

    func advance(by delta: TimeInterval) {
        guard state == .playing, delta.isFinite, delta >= 0 else { return }
        guard let entity, entity.world != nil else { stop(reason: .removed); return }
        guard entity.isActive else { synchronize(); return }
        let next = elapsed + delta * speed
        guard next.isFinite else { fail(.invalidOptions); return }
        elapsed = next
        let iterations: Double
        switch repeatMode { case .once: iterations = 1; case .count(let n): iterations = Double(n); case .forever: iterations = .infinity }
        if elapsed >= duration * iterations {
            currentTime = duration; completedIterations = iterationCount(iterations)
            synchronize() // present the last sprite frame before delivering completion
            guard !isTerminal else { return }
            state = .completed; terminate()
            if let world = entity.world { world.publish(PlaybackEvents.Completed(entity: entity, controller: self), from: entity) }
        } else {
            completedIterations = iterationCount(floor(elapsed / duration))
            currentTime = elapsed.truncatingRemainder(dividingBy: duration)
            synchronize()
        }
    }
}

/// Controls one entity's sprite clip. Starting another clip on that entity
/// replaces it; clips on other entities keep independent playback positions.
@MainActor
public final class AnimationPlaybackController: PlaybackController {
    public let resource: AnimationResource
    init(entity: Entity, resource: AnimationResource, options: PlaybackOptions) {
        self.resource = resource
        super.init(entity: entity, duration: resource.duration, options: options)
    }
    override func apply() throws {
        guard let entity, var sprite = entity.components[SpriteComponent.self] else { stop(reason: .removed); return }
        let frame = min(Int(min(currentTime * resource.framesPerSecond, Double(resource.frames.count - 1))), resource.frames.count - 1)
        let texture = resource.frames[frame]
        if sprite.texture != texture {
            sprite.texture = texture
            entity.components.set(sprite)
        }
    }
}

@MainActor
protocol AudioVoice: AnyObject {
    func synchronize(time: Double, playing: Bool, rate: Double, volume: Float, pan: Float, looping: Bool) throws
    func stop()
}

@MainActor
final class PlayerAudioVoice: AudioVoice {
    let player: AVAudioPlayer
    init(resource: AudioResource) throws {
        player = try AVAudioPlayer(data: resource.data)
        player.enableRate = true
    }
    func synchronize(time: Double, playing: Bool, rate: Double, volume: Float, pan: Float, looping: Bool) throws {
        player.volume = volume; player.pan = pan; player.numberOfLoops = looping ? -1 : 0
        guard playing else { player.pause(); return }
        guard rate >= 0.5, rate <= 2 else { throw PlaybackError.unsupportedAudioRate(rate) }
        player.rate = Float(rate)
        // Correct drift after a suspended app or a large headless/manual time step.
        if abs(player.currentTime - time) > 0.15 { player.currentTime = min(time, player.duration) }
        if !player.isPlaying, !player.play() { throw PlaybackError.audioUnavailable }
    }
    func stop() { player.stop() }
}

/// Controls one sound, independently of other sounds on the same entity.
@MainActor
public final class AudioPlaybackController: PlaybackController {
    public let resource: AudioResource
    public var volume: Float { didSet { synchronize() } }
    public var isPositional: Bool { didSet { synchronize() } }
    /// Points over which pan and distance attenuation become pronounced.
    public var spatialRange: Float { didSet { synchronize() } }
    @ObservationIgnored let voice: any AudioVoice

    init(entity: Entity, resource: AudioResource, options: PlaybackOptions, volume: Float, isPositional: Bool, voice: any AudioVoice) {
        self.resource = resource; self.volume = volume; self.isPositional = isPositional; spatialRange = 600; self.voice = voice
        super.init(entity: entity, duration: resource.duration, options: options)
    }
    override func apply() throws {
        var gain = volume.isFinite ? min(1, max(0, volume)) : 0
        var pan: Float = 0
        if isPositional, let entity, let world = entity.world {
            let delta = entity.scenePosition - (world.activeCamera?.scenePosition ?? .zero)
            let range = spatialRange.isFinite ? max(1, spatialRange) : 600
            pan = min(1, max(-1, delta.x / range))
            gain /= 1 + (delta * delta).sum().squareRoot() / range
        }
        let rate = speed * (entity?.world?.timeScale ?? 1)
        if isPlaying && !(0.5...2).contains(rate) { throw PlaybackError.unsupportedAudioRate(rate) }
        try voice.synchronize(time: currentTime, playing: isPlaying, rate: rate, volume: gain, pan: pan, looping: repeatMode != .once)
    }
    override func terminate() { voice.stop() }
}

struct PlaybackStorage: Component {
    var controllers: [PlaybackController] = []
    func cloned() -> Self? { nil }
}

extension Entity {
    /// Starts a sprite clip and returns its controller. A renderer installs the
    /// playback system automatically; attached headless playback installs it too.
    @discardableResult
    public func playAnimation(_ resource: AnimationResource, options: PlaybackOptions = .init()) throws -> AnimationPlaybackController {
        try options.validate(duration: resource.duration)
        // Snapshot first: stopped-event handlers may start another animation.
        let previous = components[PlaybackStorage.self]?.controllers.compactMap { $0 as? AnimationPlaybackController } ?? []
        if components[SpriteComponent.self] == nil { components.set(SpriteComponent(texture: resource.frames[0])) }
        let controller = AnimationPlaybackController(entity: self, resource: resource, options: options)
        addPlayback(controller)
        controller.synchronize()
        for previous in previous { previous.stop(reason: .replaced) }
        return controller
    }
    /// Starts an independent audio voice. Loading and decoding are handled by
    /// ResourceLibrary. The combined audio speed (controller × scene) is 0.5...2;
    /// setting an unsupported rate fails the voice with a typed failure event.
    @discardableResult
    public func playAudio(_ resource: AudioResource, options: PlaybackOptions = .init(), volume: Float = 1, isPositional: Bool = false) throws -> AudioPlaybackController {
        try options.validate(duration: resource.duration)
        let rate = options.speed * (world?.timeScale ?? 1)
        guard !isActive || world?.isPaused == true || rate == 0 || (0.5...2).contains(rate) else { throw PlaybackError.unsupportedAudioRate(rate) }
        let voice: any AudioVoice
        do { voice = try PlaybackSystem.makeVoice(resource) } catch { throw PlaybackError.audioUnavailable }
        let controller = AudioPlaybackController(entity: self, resource: resource, options: options, volume: volume, isPositional: isPositional, voice: voice)
        addPlayback(controller); controller.synchronize()
        return controller
    }
    /// Stops all explicit clips and audio voices on this entity.
    public func stopAllPlayback() {
        for controller in components[PlaybackStorage.self]?.controllers ?? [] { controller.stop() }
    }
    func addPlayback(_ controller: PlaybackController) {
        var storage = components[PlaybackStorage.self] ?? PlaybackStorage()
        storage.controllers.removeAll { $0.isTerminal }
        storage.controllers.append(controller)
        components.set(storage)
        world?.addSystem(PlaybackSystem.self)
    }
}

/// Advances reusable clips and audio voices on scaled scene time. Detached
/// entities keep their controllers until attached; removal cancels active playback.
public struct PlaybackSystem: System {
    public static var phase: SystemPhase { .presentation }
    static var makeVoice: @MainActor (AudioResource) throws -> any AudioVoice = { try PlayerAudioVoice(resource: $0) }
    private let changes: EventSubscription
    private let removals: EventSubscription
    private let activations: EventSubscription
    private static let query = EntityQuery(where: .has(PlaybackStorage.self))

    public init(world: World) {
        changes = world.subscribe(to: WorldEvents.SimulationDidChange.self) { event in
            for entity in event.world.performQuery(EntityQuery(where: .has(PlaybackStorage.self), includingDisabled: true)) {
                for controller in entity.components[PlaybackStorage.self]?.controllers ?? [] { controller.synchronize() }
            }
        }
        activations = world.subscribe(to: WorldEvents.DidChangeEntityActivation.self) { event in
            for controller in event.entity.components[PlaybackStorage.self]?.controllers ?? [] { controller.synchronize() }
        }
        removals = world.subscribe(to: WorldEvents.WillRemoveEntity.self) { event in
            for controller in event.entity.components[PlaybackStorage.self]?.controllers ?? [] { controller.stop(reason: .removed) }
        }
    }
    public mutating func update(context: UpdateContext) {
        for entity in context.entities(matching: Self.query) {
            let snapshot = entity.components[PlaybackStorage.self]?.controllers ?? []
            for controller in snapshot where entity.world === context.world { controller.advance(by: context.deltaTime) }
            // Read fresh storage: completion handlers may have added another clip.
            if var storage = entity.components[PlaybackStorage.self] {
                storage.controllers.removeAll { $0.isTerminal }
                if storage.controllers.isEmpty { entity.components.remove(PlaybackStorage.self) }
                else { entity._setWithoutNotifying(storage) }
            }
        }
    }
}
