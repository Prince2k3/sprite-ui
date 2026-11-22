@_spi(Backend) import ECSCore
import Foundation

/// A named instant within one iteration of an animation, measured in seconds.
public struct AnimationMarker: Hashable, Sendable {
    public let name: String
    public let time: TimeInterval
    public init(_ name: String, at time: TimeInterval) { self.name = name; self.time = time }
}

enum AnimationChannel: Hashable, Sendable { case position, rotation, scale, opacity, texture }
enum AnimationValue: Sendable {
    case vector(SIMD2<Float>), scalar(Float), texture(TextureResource?)
    var isFinite: Bool {
        switch self {
        case .vector(let v): v.x.isFinite && v.y.isFinite
        case .scalar(let v): v.isFinite
        case .texture: true
        }
    }
}
struct AnimationTrack: Sendable {
    var start: TimeInterval
    let duration: TimeInterval
    let channel: AnimationChannel
    var from: AnimationValue?
    let to: AnimationValue
    let curve: ActionAnimation.Curve
    var frames: [TextureResource] = []
    var framesPerSecond: Double = 0
    var end: TimeInterval { start + duration }
}

extension AnimationResource {
    // Property clips use the same resource/controller API as atlas clips:
    // let run = try AnimationResource.move(to: [120, 0], duration: 1)
    // let action = try AnimationResource.sequence([run, .fade(to: 0, duration: 0.3)])
    // let playback = try actor.playAnimation(action)
    // playback.pause(); try playback.seek(to: 0.5)
    /// Parent-relative translation. A nil source captures the presented value on
    /// play, or the preceding segment's endpoint in a sequence. Rotation is in
    /// unwrapped radians; clips never implicitly choose a shorter arc.
    public static func move(from: SIMD2<Float>? = nil, to: SIMD2<Float>, duration: TimeInterval,
                            curve: ActionAnimation.Curve = .linear) throws -> Self {
        try property(.position, from: from.map(AnimationValue.vector), to: .vector(to), duration: duration, curve: curve)
    }
    public static func rotate(from: Float? = nil, to: Float, duration: TimeInterval,
                              curve: ActionAnimation.Curve = .linear) throws -> Self {
        try property(.rotation, from: from.map(AnimationValue.scalar), to: .scalar(to), duration: duration, curve: curve)
    }
    public static func scale(from: SIMD2<Float>? = nil, to: SIMD2<Float>, duration: TimeInterval,
                             curve: ActionAnimation.Curve = .linear) throws -> Self {
        try property(.scale, from: from.map(AnimationValue.vector), to: .vector(to), duration: duration, curve: curve)
    }
    /// Sprite opacity, clamped to 0...1 even when a spring overshoots. Requires a sprite.
    public static func fade(from: Float? = nil, to: Float, duration: TimeInterval,
                            curve: ActionAnimation.Curve = .linear) throws -> Self {
        guard (0...1).contains(to), from.map({ (0...1).contains($0) }) ?? true else { throw ResourceLoadingError.invalidAnimation }
        return try property(.opacity, from: from.map(AnimationValue.scalar), to: .scalar(to), duration: duration, curve: curve)
    }
    private static func property(_ channel: AnimationChannel, from: AnimationValue?, to: AnimationValue,
                                 duration: TimeInterval, curve: ActionAnimation.Curve) throws -> Self {
        guard duration.isFinite, duration > 0, to.isFinite, from?.isFinite != false else { throw ResourceLoadingError.invalidAnimation }
        return Self(name: nil, tracks: [.init(start: 0, duration: duration, channel: channel, from: from, to: to, curve: curve)], duration: duration)
    }
    /// A gap that holds the previous pose. Combine with sequence or add markers.
    public static func wait(_ duration: TimeInterval) throws -> Self {
        guard duration.isFinite, duration > 0 else { throw ResourceLoadingError.invalidAnimation }
        return Self(name: nil, tracks: [], duration: duration)
    }
    /// Plays each resource in order. Nil sources chain from previous endpoints,
    /// so sampling after a seek produces the same pose as normal playback.
    public static func sequence(_ resources: [Self], name: String? = nil) throws -> Self {
        try compose(resources, sequential: true, name: name)
    }
    /// Plays resources together. Overlapping intervals on the same property are
    /// rejected rather than depending on array order. A shorter track holds its
    /// last value until the group ends. Independent properties may overlap.
    public static func group(_ resources: [Self], name: String? = nil) throws -> Self {
        try compose(resources, sequential: false, name: name)
    }
    private static func compose(_ resources: [Self], sequential: Bool, name: String?) throws -> Self {
        guard !resources.isEmpty else { throw ResourceLoadingError.invalidAnimation }
        var tracks: [AnimationTrack] = [], markers: [AnimationMarker] = [], duration: Double = 0
        for resource in resources {
            let offset = sequential ? duration : 0
            tracks += resource.tracks.map { var track = $0; track.start += offset; return track }
            markers += resource.markers.map { AnimationMarker($0.name, at: $0.time + offset) }
            duration = sequential ? duration + resource.duration : max(duration, resource.duration)
            guard duration.isFinite, tracks.count <= 100_000, markers.count <= 100_000 else { throw ResourceLoadingError.invalidAnimation }
        }
        let ordered = tracks.enumerated().sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }.map(\.element)
        var ends: [AnimationChannel: Double] = [:]
        for track in ordered {
            if let end = ends[track.channel], track.start < end { throw ResourceLoadingError.invalidAnimation }
            ends[track.channel] = track.end
        }
        return Self(name: name, tracks: ordered, duration: duration, markers: markers)
    }
    public func delayed(by delay: TimeInterval) throws -> Self {
        guard delay.isFinite, delay >= 0 else { throw ResourceLoadingError.invalidAnimation }
        return delay == 0 ? self : try .sequence([.wait(delay), self], name: name)
    }
    /// Finite repetition inside another composition. Expanded resources are
    /// limited to 100,000 tracks/markers and 10,000 copies. Use PlaybackOptions
    /// repeatMode for whole-clip loops without expanding a resource.
    public func repeated(_ count: Int) throws -> Self {
        guard count > 0, count <= 10_000, tracks.count <= 100_000 / count,
              markers.count <= 100_000 / count else { throw ResourceLoadingError.invalidAnimation }
        return try .sequence(Array(repeating: self, count: count), name: name)
    }
    /// Adds a marker, including at either endpoint. Equal-time markers retain
    /// insertion order; composed resources preserve their child marker order.
    public func addingMarker(_ name: String, at time: TimeInterval) throws -> Self {
        guard !name.isEmpty, time.isFinite, time >= 0, time <= duration, markers.count < 100_000 else { throw ResourceLoadingError.invalidAnimation }
        return Self(name: self.name, tracks: tracks, duration: duration, markers: markers + [AnimationMarker(name, at: time)], frames: frames, framesPerSecond: framesPerSecond)
    }
}

@MainActor
struct AnimationPose {
    let transform: Transform
    let sprite: SpriteComponent?
    func value(for channel: AnimationChannel) -> AnimationValue {
        switch channel {
        case .position: .vector(transform.translation)
        case .rotation: .scalar(transform.rotation)
        case .scale: .vector(transform.scale)
        case .opacity: .scalar(sprite?.opacity ?? 1)
        case .texture: .texture(sprite?.texture)
        }
    }
}

extension AnimationTrack {
    func value(at time: TimeInterval) throws -> AnimationValue {
        let local = min(duration, max(0, time - start))
        if !frames.isEmpty {
            let index = Int(min(Double(frames.count - 1), local * framesPerSecond))
            return .texture(frames[index])
        }
        guard let from else { throw PlaybackError.invalidAnimationValue }
        if local >= duration { return to }
        let progress = local == 0 ? 0 : curve.progress(local / duration)
        guard progress.isFinite else { throw PlaybackError.invalidAnimationValue }
        func interpolate(_ a: Float, _ b: Float) -> Float { Float(Double(a) + (Double(b) - Double(a)) * progress) }
        let value: AnimationValue
        switch (from, to) {
        case (.vector(let a), .vector(let b)): value = .vector([interpolate(a.x, b.x), interpolate(a.y, b.y)])
        case (.scalar(let a), .scalar(let b)): value = .scalar(interpolate(a, b))
        default: throw PlaybackError.invalidAnimationValue
        }
        guard value.isFinite else { throw PlaybackError.invalidAnimationValue }
        return value
    }
}
