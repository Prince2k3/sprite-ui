import ECSCore
import Foundation

/// A frozen entity hierarchy that creates independent instances. Capturing a live
/// hierarchy does not detach or change it. Internal entity references are remapped
/// per instance; references outside the captured hierarchy stay external.
/// Immutable texture/audio resources remain shared. Active playback, actions,
/// subscriptions and backend caches are not part of an instance.
///
/// ```swift
/// let prefab = try await ResourceLibrary.shared.prefab(named: "Pendulum.prefab")
/// let instance = prefab.instantiate()
/// instance.position = [100, 0]
/// scene.addEntity(instance)
/// ```
@MainActor
public final class PrefabResource: Identifiable {
    public nonisolated let id = UUID()
    public let name: String?
    public let entityCount: Int
    private let prototype: Entity

    /// Captures all copyable components, including unregistered/non-Codable ones.
    /// Custom mutable reference storage must implement Component.cloned().
    public init(root: Entity, name: String? = nil) {
        prototype = root.clone()
        self.name = name ?? (root.name.isEmpty ? nil : root.name)
        var count = 0; prototype.visit { _ in count += 1 }; entityCount = count
    }

    private init(file: PrefabFile, name: String) {
        prototype = file.root.makeEntity(); self.name = name
        var count = 0; prototype.visit { _ in count += 1 }; entityCount = count
    }

    /// Creates a detached hierarchy with fresh IDs and local transforms. Mutating
    /// an instance never edits the private template or another value component.
    public func instantiate() -> Entity { prototype.clone() }

    /// Writes a versioned `.prefab` JSON file atomically. As with snapshots, only
    /// registered Codable components persist; custom types must register before
    /// writing/reading. In-memory instances do not have that restriction.
    public func write(to url: URL) throws {
        SpriteRenderer.registerComponents()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        try encoder.encode(PrefabFile(version: 1, root: prototype.snapshot())).write(to: url, options: .atomic)
    }

    static func read(_ data: Data, from url: URL) throws -> PrefabResource {
        do {
            SpriteRenderer.registerComponents()
            let decoder = JSONDecoder()
            decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
            let file = try decoder.decode(PrefabFile.self, from: data)
            guard file.version == 1 else { throw ResourceLoadingError.unreadable(url) }
            var ids: Set<Entity.ID> = []
            func validate(_ entity: EntitySnapshot) throws {
                guard ids.insert(entity.id).inserted else { throw ResourceLoadingError.unreadable(url) }
                for child in entity.children { try validate(child) }
            }
            try validate(file.root)
            return PrefabResource(file: file, name: url.lastPathComponent)
        } catch { throw ResourceLoadingError.unreadable(url) }
    }
}

private struct PrefabFile: Codable {
    let version: Int
    let root: EntitySnapshot
}

extension ResourceLibrary {
    /// Loads and caches a versioned prefab JSON file or a `.sks` hierarchy once.
    /// Scenes use the default SceneLoader; custom User Data makers can instead
    /// load a scene themselves and pass its root to PrefabResource(root:).
    public func prefab(contentsOf url: URL) async throws -> PrefabResource {
        let url = url.standardizedFileURL
        return try await prefabs.value(for: url.absoluteString) {
            if url.pathExtension.lowercased() == "sks" {
                do { return PrefabResource(root: try SceneLoader().load(contentsOf: url), name: url.lastPathComponent) }
                catch { throw ResourceLoadingError.unreadable(url) }
            }
            let data: Data
            do { data = try await Task.detached { try Data(contentsOf: url) }.value }
            catch { throw ResourceLoadingError.unreadable(url) }
            return try PrefabResource.read(data, from: url)
        }
    }

    /// Loads a named `.prefab`, `.json` or `.sks` file from a bundle.
    public func prefab(named name: String, in bundle: Bundle = .main) async throws -> PrefabResource {
        let path = name as NSString
        if !path.pathExtension.isEmpty {
            guard let url = bundle.url(forResource: path.deletingPathExtension, withExtension: path.pathExtension) else { throw ResourceLoadingError.notFound(name) }
            return try await prefab(contentsOf: url)
        }
        for ext in ["prefab", "json", "sks"] {
            if let url = bundle.url(forResource: name, withExtension: ext) { return try await prefab(contentsOf: url) }
        }
        throw ResourceLoadingError.notFound(name)
    }
}
