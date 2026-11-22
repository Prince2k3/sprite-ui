@_spi(Backend) import ECSCore
import AVFoundation
import Foundation
import SpriteKit

/// A sound played from the entity, in place of `SKAudioNode`.
///
/// A short sound plays each time you call ``play()``, and several can overlap, so a coin
/// pickup can chime as fast as coins are collected. A looping sound, such as an engine
/// hum or music, plays while ``isPlaying`` is on.
///
/// ```swift
/// coin.components.set(AudioComponent(named: "coin.wav"))
/// coin.components[AudioComponent.self]?.play()                       // on pickup
///
/// engine.components.set(AudioComponent(named: "hum.wav", isLooping: true, volume: 0.4))
/// engine.components[AudioComponent.self]?.isPlaying = false           // stop it
/// ```
///
/// With ``isPositional`` on, the sound pans and fades with the entity's distance from the
/// active camera, which is the scene's listener.
public struct AudioComponent: Component, Hashable, Sendable {
    /// The file the sound plays, or `nil` when it couldn't be found.
    public var url: URL?
    /// From 0 (silent) to 1.
    public var volume: Float
    /// Whether the sound pans and fades with distance from the camera.
    public var isPositional: Bool
    /// Whether the sound repeats while ``isPlaying``, rather than playing once per ``play()``.
    public var isLooping: Bool
    /// Whether a looping sound is playing. Ignored for one-shot sounds.
    public var isPlaying: Bool
    /// The file's length in seconds, `nil` if it couldn't be read.
    public let duration: Float?

    /// Counts calls to ``play()``. The renderer starts the sound when it changes.
    public private(set) var playCount: Int = 0

    /// A sound file in a bundle, such as `"coin.wav"` or `"coin"` (any audio extension).
    public init(
        named name: String,
        bundle: Bundle = .main,
        volume: Float = 1,
        isPositional: Bool = false,
        isLooping: Bool = false,
        isPlaying: Bool = true
    ) {
        self.init(url: Self.find(name, in: bundle), volume: volume, isPositional: isPositional,
                  isLooping: isLooping, isPlaying: isPlaying)
    }

    public init(
        url: URL?,
        volume: Float = 1,
        isPositional: Bool = false,
        isLooping: Bool = false,
        isPlaying: Bool = true
    ) {
        self.url = url
        self.volume = volume
        self.isPositional = isPositional
        self.isLooping = isLooping
        self.isPlaying = isPlaying
        self.duration = url.flatMap(Self.length(of:))
    }

    /// Plays the sound once more, over any copies still playing.
    public mutating func play() {
        playCount &+= 1
    }

    private static let extensions = ["wav", "caf", "m4a", "mp3", "aif", "aiff"]

    static func find(_ name: String, in bundle: Bundle) -> URL? {
        let url = URL(fileURLWithPath: name)
        if !url.pathExtension.isEmpty {
            return bundle.url(forResource: url.deletingPathExtension().lastPathComponent, withExtension: url.pathExtension)
        }
        return extensions.lazy.compactMap { bundle.url(forResource: name, withExtension: $0) }.first
    }

    private static func length(of url: URL) -> Float? {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return nil }
        return Float(Double(file.length) / file.fileFormat.sampleRate)
    }
}

// MARK: - Compatibility adapter

// The component trigger API shares the same playback clock and pause behavior as
// explicit controllers. Resource-library users avoid this synchronous legacy path.
@MainActor
final class LegacyAudioPlaybackState: Component {
    var loop: AudioPlaybackController?
    var shots: [AudioPlaybackController] = []
    var resource: AudioResource?
    var url: URL?
    func cloned() -> Self? { nil }
}

extension SpriteRenderer {
    static let audioBinding = Binding<AudioComponent>(
        apply: { new, old, _, animator in
            guard let entity = animator.renderer.world.entity(withID: animator.entityID) else { return }
            let state = entity.components[LegacyAudioPlaybackState.self] ?? LegacyAudioPlaybackState()
            entity._setWithoutNotifying(state)
            state.shots.removeAll { $0.isTerminal }
            guard let sound = new, let url = sound.url else {
                state.loop?.stop(); state.loop = nil
                for shot in state.shots { shot.stop() }
                state.shots = []; state.resource = nil; state.url = nil
                return
            }
            if state.url != url || state.resource == nil {
                state.loop?.stop(); state.loop = nil
                state.url = url
                if let data = try? Data(contentsOf: url), let file = try? AVAudioFile(forReading: url),
                   file.fileFormat.sampleRate > 0, file.length > 0 {
                    state.resource = AudioResource(name: url.lastPathComponent, duration: Double(file.length) / file.fileFormat.sampleRate, data: data)
                } else { state.resource = nil }
            }
            guard let resource = state.resource else { return }
            if sound.isLooping {
                if state.loop == nil || state.loop?.isTerminal == true {
                    state.loop = try? entity.playAudio(resource, options: .init(repeatMode: .forever, startsPaused: !sound.isPlaying), volume: sound.volume, isPositional: sound.isPositional)
                }
                state.loop?.volume = sound.volume; state.loop?.isPositional = sound.isPositional
                if sound.isPlaying { state.loop?.resume() } else { state.loop?.pause() }
            } else {
                state.loop?.stop(); state.loop = nil
                let changed = old.map { $0.playCount != sound.playCount } ?? (sound.playCount != 0)
                if changed, let shot = try? entity.playAudio(resource, volume: sound.volume, isPositional: sound.isPositional) { state.shots.append(shot) }
            }
        }
    )
}

// Configuration is copied; previous one-shot requests belong to the source.
extension AudioComponent {
    public func cloned() -> Self? { var copy = self; copy.playCount = 0; return copy }
}
