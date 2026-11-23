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
    case invalidSeek, terminalController, missingSprite, dynamicPhysicsBody, invalidAnimationValue
    /// A fade needs a sprite, text or shape; its selected component was absent or removed.
    case missingVisual
    /// A single advance would emit over 4,096 markers; seek instead of simulating that gap.
    case markerEventLimitExceeded
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
    /// Markers crossed by normal playback. Seeking never emits markers. The pose
    /// is sampled at the end of the frame, not at each intermediate marker time.
    /// At a loop boundary, the previous end precedes the next iteration's start.
    /// Pausing, seeking, stopping, or recycling during a callback cancels the
    /// remaining marker/completion deliveries from that advance.
    public struct MarkerReached: Event {
        public let entity: Entity
        public let controller: AnimationPlaybackController
        public let marker: AnimationMarker
        /// Zero-based iteration containing this marker.
        public let iteration: Int
    }
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
    public private(set) var elapsedTime: TimeInterval = 0
    @ObservationIgnored var playbackRevision: UInt64 = 0
    private var sceneSuspended = true
    private var storedSpeed: Double
    public var speed: Double {
        get { storedSpeed }
        set { guard newValue.isFinite, newValue > 0 else { return }; storedSpeed = newValue; playbackRevision &+= 1; synchronize() }
    }
    public var isPlaying: Bool {
        state == .playing && !sceneSuspended && entity?.world != nil
    }
    var isTerminal: Bool { state == .stopped || state == .completed || state == .failed }

    init(entity: Entity, duration: TimeInterval, options: PlaybackOptions) {
        self.entity = entity; self.duration = duration; repeatMode = options.repeatMode; storedSpeed = options.speed
        state = options.startsPaused ? .paused : .playing
    }
    public func pause() { guard state == .playing else { return }; state = .paused; playbackRevision &+= 1; synchronize() }
    public func resume() { guard state == .paused else { return }; state = .playing; playbackRevision &+= 1; synchronize() }
    public func stop() { stop(reason: .user) }
    func stop(reason: PlaybackStopReason) {
        guard !isTerminal else { return }
        state = .stopped; playbackRevision &+= 1; terminate()
        if let entity, let world = entity.world { world.publish(PlaybackEvents.Stopped(entity: entity, controller: self, reason: reason), from: entity) }
    }
    func fail(_ error: PlaybackError) {
        guard !isTerminal else { return }
        self.error = error; state = .failed; playbackRevision &+= 1; terminate()
        if let entity, let world = entity.world { world.publish(PlaybackEvents.Failed(entity: entity, controller: self, error: error), from: entity) }
    }
    func synchronize() {
        guard !isTerminal else { return }
        let suspended = entity?.isActive != true || entity?.world?.isPaused != false || (entity?.world?.timeScale ?? 0) == 0
        if sceneSuspended != suspended { sceneSuspended = suspended; playbackRevision &+= 1 }
        do { try apply() } catch { fail((error as? PlaybackError) ?? .audioUnavailable) }
    }
    func apply() throws {}
    func terminate() {}

    var totalDuration: TimeInterval {
        switch repeatMode { case .once: duration; case .count(let n): duration * Double(n); case .forever: .infinity }
    }
    private func iterationCount(_ count: Double) -> Int {
        count >= Double(Int.max) ? Int.max : Int(max(0, count))
    }
    private func setClock(_ time: TimeInterval) {
        elapsedTime = time
        if time >= totalDuration {
            currentTime = duration
            switch repeatMode {
            case .once: completedIterations = 1
            case .count(let count): completedIterations = count
            case .forever: break
            }
        } else {
            completedIterations = iterationCount(floor(time / duration))
            currentTime = time.truncatingRemainder(dividingBy: duration)
        }
    }
    /// Samples an absolute elapsed time across all iterations, preserving playing/
    /// paused state. No markers or completion fire. Seeking to the finite end
    /// completes on the next playing update (including a zero-delta update).
    /// Terminal handles cannot be restarted; play the resource for a new handle.
    public func seek(to time: TimeInterval) throws {
        guard !isTerminal else { throw PlaybackError.terminalController }
        guard time.isFinite, time >= 0, time <= totalDuration else { throw PlaybackError.invalidSeek }
        playbackRevision &+= 1; setClock(time)
        do {
            try didSeek(); synchronize()
            if let error { throw error }
        } catch {
            let failure = (error as? PlaybackError) ?? .audioUnavailable
            fail(failure); throw failure
        }
    }
    func didSeek() throws {}
    func didAdvance(from: TimeInterval, to: TimeInterval) throws {}

    func advance(by delta: TimeInterval) {
        guard state == .playing, delta.isFinite, delta >= 0 else { return }
        guard let entity, let world = entity.world else { stop(reason: .removed); return }
        guard entity.isActive else { synchronize(); return }
        let next = elapsedTime + delta * speed
        guard next.isFinite else { fail(.invalidOptions); return }
        let previous = elapsedTime, revision = playbackRevision, activation = entity.activationRevision
        setClock(min(next, totalDuration))
        synchronize()
        func unchanged() -> Bool {
            state == .playing && isPlaying && playbackRevision == revision && entity.world === world &&
                entity.isActive && entity.activationRevision == activation
        }
        guard unchanged() else { return }
        do { try didAdvance(from: previous, to: elapsedTime) }
        catch { fail((error as? PlaybackError) ?? .invalidAnimationValue); return }
        guard unchanged() else { return }
        if elapsedTime >= totalDuration {
            state = .completed; playbackRevision &+= 1; terminate()
            world.publish(PlaybackEvents.Completed(entity: entity, controller: self), from: entity)
        }
    }
}

/// Controls a reusable sprite/property timeline. Clips on independent properties
/// coexist. Starting an overlapping clip replaces the entire older controller.
/// Parent-relative transforms and opacity are sampled directly into components;
/// `withAnimation` never adds a second easing pass on owned properties. External
/// edits to an owned property are overwritten on the next sample; stop first to
/// hand that property back. Dynamic physics bodies reject transform tracks.
@MainActor
public final class AnimationPlaybackController: PlaybackController {
    public let resource: AnimationResource
    let baseline: AnimationPose
    let resolvedTracks: [AnimationTrack]
    private var initialMarkersPending = true

    init(entity: Entity, resource: AnimationResource, options: PlaybackOptions, baseline: AnimationPose) {
        self.resource = resource; self.baseline = baseline
        var last: [AnimationChannel: AnimationValue] = [:]
        resolvedTracks = resource.tracks.map { original in
            var track = original
            track.from = original.from ?? last[track.channel] ?? baseline.value(for: track.channel)
            last[track.channel] = track.to
            return track
        }
        super.init(entity: entity, duration: resource.duration, options: options)
    }
    override func apply() throws {
        guard let entity else { return }
        let transformChannels: Set<AnimationChannel> = [.position, .rotation, .scale]
        if !resource.channels.isDisjoint(with: transformChannels), entity.components[PhysicsBodyComponent.self]?.isDynamic == true {
            throw PlaybackError.dynamicPhysicsBody
        }
        var values = Dictionary(uniqueKeysWithValues: resource.channels.map { ($0, baseline.value(for: $0)) })
        for track in resolvedTracks where currentTime >= track.start { values[track.channel] = try track.value(at: currentTime) }
        var transform = entity.transform
        var sprite = entity.components[SpriteComponent.self]
        var text = entity.components[TextComponent.self]
        var shape = entity.components[ShapeComponent.self]
        for (channel, value) in values {
            switch (channel, value) {
            case (.position, .vector(let v)): transform.translation = v
            case (.rotation, .scalar(let v)): transform.rotation = v
            case (.scale, .vector(let v)): transform.scale = v
            case (.opacity, .scalar(let v)):
                let opacity = min(1, max(0, v))
                switch baseline.opacityTarget {
                case .sprite: guard sprite != nil else { throw PlaybackError.missingVisual }; sprite?.opacity = opacity
                case .text: guard text != nil else { throw PlaybackError.missingVisual }; text?.opacity = opacity
                case .shape: guard shape != nil else { throw PlaybackError.missingVisual }; shape?.opacity = opacity
                case nil: throw PlaybackError.missingVisual
                }
            case (.texture, .texture(let texture)):
                guard sprite != nil else { throw PlaybackError.missingSprite }
                sprite?.texture = texture
                if texture == nil { sprite?.image = baseline.sprite?.image; sprite?.imageName = baseline.sprite?.imageName }
            default: throw PlaybackError.invalidAnimationValue
            }
        }
        // Sampling must remain direct even when play/seek is called inside an
        // outer withAnimation transaction. Untouched component fields are kept.
        ActionTransaction.perform(nil, completion: nil) {
            if transform != entity.transform { entity.transform = transform }
            if let sprite, sprite != entity.components[SpriteComponent.self] { entity.components.set(sprite) }
            if let text, text != entity.components[TextComponent.self] { entity.components.set(text) }
            if let shape, shape != entity.components[ShapeComponent.self] { entity.components.set(shape) }
        }
    }
    override func didSeek() { initialMarkersPending = false }
    override func didAdvance(from lower: TimeInterval, to upper: TimeInterval) throws {
        let includeZero = initialMarkersPending; initialMarkersPending = false
        guard !resource.markers.isEmpty, let entity, let world = entity.world else { return }
        let first = floor(lower / duration), last = floor(upper / duration)
        guard last < Double(Int.max), last - first <= 4096 else { throw PlaybackError.markerEventLimitExceeded }
        let lastIteration: Int
        switch repeatMode {
        case .once: lastIteration = min(Int(last), 0)
        case .count(let count): lastIteration = min(Int(last), count - 1)
        case .forever: lastIteration = Int(last)
        }
        var events: [(Double, Int, Int, AnimationMarker)] = []
        if Int(first) <= lastIteration {
            for iteration in Int(first)...lastIteration {
                for (index, marker) in resource.markers.enumerated() {
                    let time = Double(iteration) * duration + marker.time
                    if (time > lower || (includeZero && time == 0)) && time <= upper {
                        events.append((time, iteration, index, marker))
                        guard events.count <= 4096 else { throw PlaybackError.markerEventLimitExceeded }
                    }
                }
            }
        }
        events.sort { a, b in a.0 == b.0 ? (a.1 == b.1 ? a.2 < b.2 : a.1 < b.1) : a.0 < b.0 }
        let revision = playbackRevision, activation = entity.activationRevision
        for (_, iteration, _, marker) in events {
            guard state == .playing, isPlaying, playbackRevision == revision, entity.isActive,
                  entity.world === world, entity.activationRevision == activation else { return }
            world.publish(PlaybackEvents.MarkerReached(entity: entity, controller: self, marker: marker, iteration: iteration), from: entity)
        }
    }
}

@MainActor
protocol AudioVoice: AnyObject {
    func synchronize(time: Double, playing: Bool, rate: Double, volume: Float, pan: Float, looping: Bool) throws
    func stop()
    func seek(to time: Double)
}

extension AudioVoice { func seek(to time: Double) {} }

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
    func seek(to time: Double) { player.currentTime = min(time, player.duration) }
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
    override func didSeek() { voice.seek(to: currentTime) }
    override func terminate() { voice.stop() }
}

struct PlaybackStorage: Component {
    var controllers: [PlaybackController] = []
    func cloned() -> Self? { nil }
}

extension Entity {
    /// Starts a sprite or composed property clip and returns its controller. A renderer installs the
    /// playback system automatically; attached headless playback installs it too.
    @discardableResult
    public func playAnimation(_ resource: AnimationResource, options: PlaybackOptions = .init()) throws -> AnimationPlaybackController {
        try options.validate(duration: resource.duration)
        let channels = resource.channels
        if !channels.isDisjoint(with: [.position, .rotation, .scale]), components[PhysicsBodyComponent.self]?.isDynamic == true {
            throw PlaybackError.dynamicPhysicsBody
        }
        let firstFrame = resource.tracks.first(where: { $0.channel == .texture })?.frames.first
        var sprite = presentation[SpriteComponent.self]
        if sprite == nil, let firstFrame { sprite = SpriteComponent(texture: firstFrame) }
        if channels.contains(.texture), sprite == nil { throw PlaybackError.missingSprite }
        let baseline = AnimationPose(transform: presentation.transform, sprite: sprite,
                                     text: presentation[TextComponent.self], shape: presentation[ShapeComponent.self])
        if channels.contains(.opacity), baseline.opacityTarget == nil { throw PlaybackError.missingVisual }
        guard channels.allSatisfy({ baseline.value(for: $0).isFinite }) else { throw PlaybackError.invalidAnimationValue }
        let previous = components[PlaybackStorage.self]?.controllers.compactMap { $0 as? AnimationPlaybackController }
            .filter { !$0.resource.channels.isDisjoint(with: channels) } ?? []
        if components[SpriteComponent.self] == nil, let sprite { components.set(sprite) }
        let controller = AnimationPlaybackController(entity: self, resource: resource, options: options, baseline: baseline)
        addPlayback(controller)
        (world?.observer as? SpriteRenderer)?.cancelAnimationActions(channels, for: self, opacityTarget: baseline.opacityTarget)
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
    private let additions: EventSubscription
    private static let query = EntityQuery(where: .has(PlaybackStorage.self))

    public init(world: World) {
        additions = world.subscribe(to: WorldEvents.DidAddEntity.self) { event in
            for controller in event.entity.components[PlaybackStorage.self]?.controllers ?? [] { controller.synchronize() }
        }
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
