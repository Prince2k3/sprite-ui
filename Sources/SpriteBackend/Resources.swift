import AVFoundation
import Foundation
import ImageIO
import SpriteKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A resource that could not be located or decoded.
public enum ResourceLoadingError: Error, Equatable, Sendable {
    case notFound(String)
    case unreadable(URL)
    case emptyAtlas(String)
    case invalidAnimation
}

// Only the backend touches the lazily-created GPU object. The immutable handle
// and its pixel data can safely cross tasks and participate in snapshots.
final class TextureStorage: Sendable {
    @MainActor var texture: SKTexture? = nil
    nonisolated init() {}
}

/// An immutable, reusable texture. Copies share their backend texture.
/// Load files through ``ResourceLibrary``; procedural images need no file I/O.
public struct TextureResource: Hashable, Sendable, Codable {
    public let id: UUID
    public let name: String?
    public let image: SpriteImage
    public var size: SIMD2<Float> { [Float(image.width), Float(image.height)] }
    private let storage = TextureStorage()

    public init(image: SpriteImage, name: String? = nil) {
        id = UUID(); self.name = name; self.image = image
    }
    private enum CodingKeys: String, CodingKey { case id, name, image }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    @MainActor var nativeTexture: SKTexture? {
        if let texture = storage.texture { return texture }
        storage.texture = SpriteRenderer.makeTexture(image)
        return storage.texture
    }
}

/// Named textures that can be reused in several animation clips.
public struct TextureAtlasResource: Sendable {
    public let name: String
    private let textures: [String: TextureResource]
    public var textureNames: [String] { textures.keys.sorted() }

    public init(name: String, textures: [String: TextureResource]) throws {
        guard !textures.isEmpty else { throw ResourceLoadingError.emptyAtlas(name) }
        self.name = name; self.textures = textures
    }
    public func texture(named name: String) throws -> TextureResource {
        guard let texture = textures[name] else { throw ResourceLoadingError.notFound(name) }
        return texture
    }
    /// Creates a clip in explicitly supplied frame order (never dictionary order).
    public func animation(named name: String? = nil, frames: [String], framesPerSecond: Double = 12) throws -> AnimationResource {
        try AnimationResource(name: name, frames: frames.map { try texture(named: $0) }, framesPerSecond: framesPerSecond)
    }
}

/// An immutable sprite animation clip. Playback state belongs to a controller.
public struct AnimationResource: Hashable, Sendable {
    public let id: UUID
    public let name: String?
    public let frames: [TextureResource]
    public let framesPerSecond: Double
    public var duration: TimeInterval { Double(frames.count) / framesPerSecond }

    public init(name: String? = nil, frames: [TextureResource], framesPerSecond: Double = 12) throws {
        guard !frames.isEmpty, framesPerSecond.isFinite, framesPerSecond > 0,
              (Double(frames.count) / framesPerSecond).isFinite else { throw ResourceLoadingError.invalidAnimation }
        id = UUID(); self.name = name; self.frames = frames; self.framesPerSecond = framesPerSecond
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Immutable, validated audio data. Loading reads the file once; voices can overlap.
public struct AudioResource: Hashable, Sendable {
    public let id: UUID
    public let name: String?
    public let duration: TimeInterval
    let data: Data
    init(name: String?, duration: TimeInterval, data: Data) {
        id = UUID(); self.name = name; self.duration = duration; self.data = data
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Shares completed and in-flight loads. Cancelling one waiter does not cancel a
/// shared load. Clearing the cache does not invalidate resources already in use.
@MainActor
final class ResourceCache<Value: Sendable> {
    private var values: [String: Value] = [:]
    private var pending: [String: Task<Value, Error>] = [:]
    private var generation = 0
    var count: Int { values.count }

    func value(for key: String, load: @escaping @MainActor () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        if let value = values[key] { return value }
        let task: Task<Value, Error>
        if let existing = pending[key] { task = existing }
        else {
            let epoch = generation
            task = Task { @MainActor in
                defer { if generation == epoch { pending[key] = nil } }
                let value = try await load()
                if generation == epoch { values[key] = value }
                return value
            }
            pending[key] = task
        }
        let value = try await task.value
        try Task.checkCancellation()
        return value
    }
    func removeAll() { generation &+= 1; values.removeAll(); pending.removeAll() }
}

/// Async resource loading and caching, scoped to an app, level, or test.
///
/// ```swift
/// let library = ResourceLibrary.shared
/// let image = try await library.texture(named: "hero", in: .main)
/// let sound = try await library.audio(named: "coin.wav")
/// hero.components.set(SpriteComponent(texture: image))
/// let voice = try hero.playAudio(sound)
/// ```
@MainActor
public final class ResourceLibrary {
    public static let shared = ResourceLibrary()
    private let textures = ResourceCache<TextureResource>()
    private let atlases = ResourceCache<TextureAtlasResource>()
    private let sounds = ResourceCache<AudioResource>()
    public init() {}
    public var cachedResourceCount: Int { textures.count + atlases.count + sounds.count }
    public func removeAllCachedResources() { textures.removeAll(); atlases.removeAll(); sounds.removeAll() }

    public func texture(contentsOf url: URL) async throws -> TextureResource {
        let url = url.standardizedFileURL
        return try await textures.value(for: "file:\(url.absoluteString)") {
            let image = try await Task.detached { try Self.readImage(url) }.value
            let resource = TextureResource(image: image, name: url.lastPathComponent)
            guard let native = resource.nativeTexture else { throw ResourceLoadingError.unreadable(url) }
            await native.preload()
            return resource
        }
    }

    /// Loads an image file or a named asset in the supplied bundle.
    public func texture(named name: String, in bundle: Bundle = .main) async throws -> TextureResource {
        if let url = Self.imageURL(name, in: bundle) { return try await texture(contentsOf: url) }
        return try await textures.value(for: "asset:\(bundle.bundleURL.absoluteString):\(name)") {
            #if canImport(UIKit)
            guard let image = UIImage(named: name, in: bundle, compatibleWith: nil), let cg = image.cgImage else {
                throw ResourceLoadingError.notFound(name)
            }
            #else
            let image = bundle.image(forResource: NSImage.Name(name))
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw ResourceLoadingError.notFound(name)
            }
            #endif
            guard let pixels = Self.pixels(cg) else { throw ResourceLoadingError.notFound(name) }
            let resource = TextureResource(image: pixels, name: name)
            guard let native = resource.nativeTexture else { throw ResourceLoadingError.notFound(name) }
            await native.preload()
            return resource
        }
    }

    /// Loads a compiled SpriteKit atlas from the main app bundle without invoking
    /// the throwing Objective-C atlas initializer for a missing name.
    public func atlas(named name: String) async throws -> TextureAtlasResource {
        try await atlases.value(for: "compiled:\(name)") {
            let resource = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TextureAtlasResource, Error>) in
                SKTextureAtlas.preloadTextureAtlasesNamed([name]) { error, atlases in
                    guard error == nil, let atlas = atlases.first else {
                        continuation.resume(throwing: ResourceLoadingError.notFound(name)); return
                    }
                    do {
                        var textures: [String: TextureResource] = [:]
                        for key in atlas.textureNames.sorted() {
                            guard let image = Self.pixels(atlas.textureNamed(key).cgImage()) else { throw ResourceLoadingError.notFound(key) }
                            textures[key] = TextureResource(image: image, name: key)
                        }
                        continuation.resume(returning: try TextureAtlasResource(name: name, textures: textures))
                    } catch { continuation.resume(throwing: error) }
                }
            }
            for key in resource.textureNames {
                guard let native = try resource.texture(named: key).nativeTexture else { throw ResourceLoadingError.notFound(key) }
                await native.preload()
            }
            return resource
        }
    }

    /// Groups named assets from any bundle into a cached atlas. Useful for asset
    /// catalogs and frame manifests exported by an artist's tools.
    public func atlas(named name: String, textureNames: [String], in bundle: Bundle = .main) async throws -> TextureAtlasResource {
        let keys = Array(Set(textureNames)).sorted()
        let key = "assets:\(bundle.bundleURL.absoluteString):\(name):\(keys.joined(separator: "\u{0}"))"
        return try await atlases.value(for: key) {
            var loaded: [String: TextureResource] = [:]
            for key in keys { loaded[key] = try await self.texture(named: key, in: bundle) }
            return try TextureAtlasResource(name: name, textures: loaded)
        }
    }

    public func audio(named name: String, in bundle: Bundle = .main) async throws -> AudioResource {
        guard let url = AudioComponent.find(name, in: bundle) else { throw ResourceLoadingError.notFound(name) }
        return try await audio(contentsOf: url)
    }
    public func audio(contentsOf url: URL) async throws -> AudioResource {
        let url = url.standardizedFileURL
        return try await sounds.value(for: url.absoluteString) {
            try await Task.detached {
                do {
                    let data = try Data(contentsOf: url)
                    let file = try AVAudioFile(forReading: url)
                    guard file.fileFormat.sampleRate > 0, file.length > 0 else { throw ResourceLoadingError.unreadable(url) }
                    return AudioResource(name: url.lastPathComponent, duration: Double(file.length) / file.fileFormat.sampleRate, data: data)
                } catch { throw ResourceLoadingError.unreadable(url) }
            }.value
        }
    }

    private nonisolated static func imageURL(_ name: String, in bundle: Bundle) -> URL? {
        let path = name as NSString
        if !path.pathExtension.isEmpty { return bundle.url(forResource: path.deletingPathExtension, withExtension: path.pathExtension) }
        for ext in ["png", "jpg", "jpeg", "heic", "tiff"] {
            if let url = bundle.url(forResource: name, withExtension: ext) { return url }
        }
        return nil
    }
    private nonisolated static func readImage(_ url: URL) throws -> SpriteImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let pixels = pixels(image) else {
            throw ResourceLoadingError.unreadable(url)
        }
        return pixels
    }
    private nonisolated static func pixels(_ image: CGImage) -> SpriteImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let made = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard made else { return nil }
        for i in stride(from: 0, to: data.count, by: 4) where data[i + 3] > 0 && data[i + 3] < 255 {
            let alpha = Int(data[i + 3])
            for c in 0..<3 { data[i + c] = UInt8(min(255, Int(data[i + c]) * 255 / alpha)) }
        }
        return SpriteImage(width: width, height: height, pixels: data)
    }
}
