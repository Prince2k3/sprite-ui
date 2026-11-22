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

// MARK: - Renderer support

extension SpriteRenderer {
    static let loopNodeName = "__audio"
    static let oneShotAudioNodeName = "__sound"

    static let audioBinding = Binding<AudioComponent>(
        apply: { new, old, node, _ in
            let existing = node.childNode(withName: loopNodeName) as? SKAudioNode
            guard let sound = new, let url = sound.url else {
                existing?.removeFromParent()
                return
            }

            if sound.isLooping {
                if existing == nil || old?.url != sound.url || old?.isLooping != true {
                    existing?.removeFromParent()
                    let loop = SKAudioNode(url: url)
                    loop.name = loopNodeName
                    loop.autoplayLooped = true
                    loop.isPositional = sound.isPositional
                    node.addChild(loop)
                    loop.run(.changeVolume(to: sound.volume, duration: 0))
                    if !sound.isPlaying { loop.run(.pause()) }
                    return
                }
                guard let loop = existing else { return }
                loop.isPositional = sound.isPositional
                if old?.volume != sound.volume { loop.run(.changeVolume(to: sound.volume, duration: 0)) }
                if old?.isPlaying != sound.isPlaying { loop.run(sound.isPlaying ? .play() : .pause()) }
                return
            }

            existing?.removeFromParent()
            let isNewPlay = old.map { $0.playCount != sound.playCount } ?? (sound.playCount != 0)
            guard isNewPlay else { return }
            let shot = SKAudioNode(url: url)
            shot.name = oneShotAudioNodeName
            shot.autoplayLooped = false
            shot.isPositional = sound.isPositional
            node.addChild(shot)
            shot.run(.sequence([
                .changeVolume(to: sound.volume, duration: 0),
                .play(),
                .wait(forDuration: TimeInterval(sound.duration ?? 1) + 0.1),
                .removeFromParent(),
            ]))
        }
    )
}
