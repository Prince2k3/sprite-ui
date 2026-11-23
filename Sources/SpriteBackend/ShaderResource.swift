import Foundation
import SpriteKit

private final class ShaderStorage: Sendable {
    @MainActor var shader: SKShader?
    nonisolated init() {}
}

/// Immutable SpriteKit fragment source, parameter declarations and shared sampler textures.
/// Float/vector parameters are per-node attributes (`a_…`); texture uniforms (`u_…`)
/// are immutable and shared. Do not declare these variables in the GLSL source.
/// Use `SKDefaultShading()` for the sprite's normal tint/opacity behavior and assign
/// premultiplied RGBA to `gl_FragColor`.
///
/// Construction validates the parameter schema, not GLSL syntax. SpriteKit compiles
/// source when it renders; compiler diagnostics appear in the runtime console.
public struct ShaderResource: Hashable, Sendable, Codable {
    public let id: UUID
    public let name: String?
    public let source: String
    public let parameters: [String: ShaderValue]
    public let textures: [String: TextureResource]
    private let storage = ShaderStorage()

    public init(source: String, parameters: [String: ShaderValue] = [:],
                textures: [String: TextureResource] = [:], name: String? = nil) throws {
        try Self.validate(source: source, parameters: parameters, textures: textures)
        id = UUID(); self.name = name; self.source = source; self.parameters = parameters; self.textures = textures
    }

    private static func validate(source: String, parameters: [String: ShaderValue], textures: [String: TextureResource]) throws {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ShaderError.emptySource }
        func valid(_ name: String, prefix: String) -> Bool {
            name.hasPrefix(prefix) && name.count > 2 && !name.contains("__") && name.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95
            }
        }
        for (name, value) in parameters {
            guard valid(name, prefix: "a_") else { throw ShaderError.invalidName(name) }
            guard value.isFinite else { throw ShaderError.nonFiniteValue(name) }
        }
        let reserved: Set<String> = ["u_texture", "u_time", "u_sprite_size", "u_path_length"]
        for name in textures.keys {
            guard valid(name, prefix: "u_"), !reserved.contains(name) else { throw ShaderError.invalidName(name) }
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.source == rhs.source && lhs.parameters == rhs.parameters && lhs.textures == rhs.textures
    }
    public func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(source); hasher.combine(parameters); hasher.combine(textures) }

    @MainActor var nativeShader: SKShader {
        if let shader = storage.shader { return shader }
        let shader = SKShader(source: source, uniforms: textures.keys.sorted().map {
            SKUniform(name: $0, texture: textures[$0]!.nativeTexture)
        })
        shader.attributes = parameters.keys.sorted().map { SKAttribute(name: $0, type: parameters[$0]!.type) }
        storage.shader = shader
        return shader
    }

    private enum CodingKeys: String, CodingKey { case id, name, source, parameters, textures }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source)
        parameters = try c.decode([String: ShaderValue].self, forKey: .parameters)
        textures = try c.decode([String: TextureResource].self, forKey: .textures)
        try Self.validate(source: source, parameters: parameters, textures: textures)
        id = try c.decode(UUID.self, forKey: .id); name = try c.decodeIfPresent(String.self, forKey: .name)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encodeIfPresent(name, forKey: .name)
        try c.encode(source, forKey: .source); try c.encode(parameters, forKey: .parameters); try c.encode(textures, forKey: .textures)
    }

    /// Damage flash, inner outline and dissolve, usable together on animated textures.
    /// `a_texelSize` is one pixel in normalized texture coordinates. The inner outline
    /// stays within the sprite's geometry. Set `a_dissolve` from 0 (visible) to 1 (gone).
    public static let spriteEffects = try! ShaderResource(source: """
        void main() {
            vec4 base = SKDefaultShading();
            float width = max(a_outlineWidth, 0.0);
            vec2 d = a_texelSize * width;
            float neighbor = min(min(texture2D(u_texture, v_tex_coord + vec2(d.x, 0.0)).a,
                                     texture2D(u_texture, v_tex_coord - vec2(d.x, 0.0)).a),
                                 min(texture2D(u_texture, v_tex_coord + vec2(0.0, d.y)).a,
                                     texture2D(u_texture, v_tex_coord - vec2(0.0, d.y)).a));
            float edge = step(neighbor + 0.01, texture2D(u_texture, v_tex_coord).a) * step(0.01, width);
            base.rgb = mix(base.rgb, a_effectColor.rgb * base.a, edge * a_effectColor.a);
            base.rgb = mix(base.rgb, a_effectColor.rgb * base.a, clamp(a_flash, 0.0, 1.0) * a_effectColor.a);
            vec2 cell = floor(v_tex_coord / max(a_texelSize, vec2(0.0001)));
            float noise = fract(sin(dot(cell, vec2(12.9898, 78.233))) * 43758.5453);
            float amount = clamp(a_dissolve, 0.0, 1.0);
            float visible = step(amount, noise) * (1.0 - step(1.0, amount));
            gl_FragColor = base * visible;
        }
        """, parameters: ["a_flash": .float(0), "a_outlineWidth": .float(0), "a_dissolve": .float(0),
                          "a_texelSize": .vector2([1.0 / 32, 1.0 / 32]), "a_effectColor": .vector4([1, 1, 1, 1])],
        name: "Sprite effects")
}

extension ResourceLibrary {
    /// Loads UTF-8 `.fsh` source. Declarations are part of the cache key, so the same
    /// file can be used with different schemas. Source compilation occurs at render time.
    public func shader(contentsOf url: URL, parameters: [String: ShaderValue] = [:],
                       textures: [String: TextureResource] = [:]) async throws -> ShaderResource {
        try requireOpenLevelScope()
        let url = url.standardizedFileURL
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let key = try encoder.encode(ShaderCacheKey(url: url, parameters: parameters, textures: textures.mapValues(\.id))).base64EncodedString()
        return try await shaders.value(for: key) {
            let data: Data
            do { data = try await Task.detached { try Data(contentsOf: url) }.value }
            catch { throw ResourceLoadingError.unreadable(url) }
            guard let source = String(data: data, encoding: .utf8) else { throw ResourceLoadingError.unreadable(url) }
            return try ShaderResource(source: source, parameters: parameters, textures: textures, name: url.lastPathComponent)
        }
    }

    public func shader(named name: String, in bundle: Bundle = .main,
                       parameters: [String: ShaderValue] = [:], textures: [String: TextureResource] = [:]) async throws -> ShaderResource {
        try requireOpenLevelScope()
        let path = name as NSString
        let ext = path.pathExtension.isEmpty ? "fsh" : path.pathExtension
        let base = path.pathExtension.isEmpty ? name : path.deletingPathExtension
        guard let url = bundle.url(forResource: base, withExtension: ext) else { throw ResourceLoadingError.notFound(name) }
        return try await shader(contentsOf: url, parameters: parameters, textures: textures)
    }
}

private struct ShaderCacheKey: Encodable {
    let url: URL
    let parameters: [String: ShaderValue]
    let textures: [String: UUID]
}
