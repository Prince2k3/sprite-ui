import ECSCore
import Foundation
import SpriteKit
import SwiftUI

/// How the sprite's premultiplied color combines with the scene behind it.
public enum SpriteBlendMode: String, CaseIterable, Codable, Sendable {
    case alpha, add, subtract, multiply, multiplyX2, screen, replace

    var native: SKBlendMode {
        switch self {
        case .alpha: .alpha
        case .add: .add
        case .subtract: .subtract
        case .multiply: .multiply
        case .multiplyX2: .multiplyX2
        case .screen: .screen
        case .replace: .replace
        }
    }

    init(_ mode: SKBlendMode) {
        self = Self.allCases.first { $0.native == mode } ?? .alpha
    }
}

/// A per-sprite shader attribute. Types cannot change after a resource is made.
/// Color parameters use a straight sRGB RGBA `vector4`; shader output must be premultiplied.
public enum ShaderValue: Hashable, Codable, Sendable {
    case float(Float), vector2(SIMD2<Float>), vector3(SIMD3<Float>), vector4(SIMD4<Float>)

    public static func color(_ color: Color) -> Self {
        let c = ColorCoding.components(of: color)
        return .vector4([c[0], c[1], c[2], c[3]])
    }

    var type: SKAttributeType {
        switch self {
        case .float: .float
        case .vector2: .vectorFloat2
        case .vector3: .vectorFloat3
        case .vector4: .vectorFloat4
        }
    }
    var isFinite: Bool {
        switch self {
        case .float(let v): v.isFinite
        case .vector2(let v): v.x.isFinite && v.y.isFinite
        case .vector3(let v): v.x.isFinite && v.y.isFinite && v.z.isFinite
        case .vector4(let v): v.x.isFinite && v.y.isFinite && v.z.isFinite && v.w.isFinite
        }
    }
    @MainActor var native: SKAttributeValue {
        switch self {
        case .float(let v): SKAttributeValue(float: v)
        case .vector2(let v): SKAttributeValue(vectorFloat2: v)
        case .vector3(let v): SKAttributeValue(vectorFloat3: v)
        case .vector4(let v): SKAttributeValue(vectorFloat4: v)
        }
    }
}

public enum ShaderError: Error, Equatable, Sendable {
    case emptySource, invalidName(String), unknownParameter(String), typeMismatch(String), nonFiniteValue(String)
}

/// A value material. Copies share immutable shader code and textures, but own their parameters.
/// The legacy sprite `color`, `colorBlendFactor`, and `opacity` properties forward here.
///
/// ```swift
/// var material = SpriteMaterial(shader: .spriteEffects)
/// try material.setParameter(.float(1), named: "a_flash")
/// hero.components[SpriteComponent.self]?.material = material
/// ```
public struct SpriteMaterial: Hashable, Codable, Sendable {
    public var tint: Color
    public var tintAmount: Float
    public var opacity: Float
    public var blendMode: SpriteBlendMode
    /// A tangent-space RGB normal map, using the same texture coordinates as the sprite.
    /// Load it through ResourceLibrary.texture or make a TextureResource from pixels.
    /// No map uses SpriteKit's flat surface normals. Frame animations keep this map
    /// until you replace it; supply a matching map when a frame needs different normals.
    public var normalMap: TextureResource?
    /// Lights whose categories overlap this mask illuminate the sprite. Zero opts out.
    /// Custom fragment shaders take precedence over built-in illumination; removing
    /// the shader restores this mask. Shadow masks remain independent.
    public var lightingBitMask: UInt32
    /// Lights occluded by this sprite. Zero casts no shadows.
    public var shadowCastBitMask: UInt32
    /// Lights whose shadows darken this sprite. Zero receives no shadows.
    public var shadowedBitMask: UInt32
    /// Changing the shader clears overrides; the new resource supplies its defaults.
    public var shader: ShaderResource? {
        didSet { if oldValue != shader { parameters = [:] } }
    }
    public private(set) var parameters: [String: ShaderValue] = [:]

    public init(tint: Color = .white, tintAmount: Float = 0, opacity: Float = 1,
                blendMode: SpriteBlendMode = .alpha, shader: ShaderResource? = nil,
                normalMap: TextureResource? = nil, lightingBitMask: UInt32 = 0,
                shadowCastBitMask: UInt32 = 0, shadowedBitMask: UInt32 = 0) {
        self.tint = tint; self.tintAmount = tintAmount; self.opacity = opacity
        self.blendMode = blendMode; self.shader = shader
        self.normalMap = normalMap; self.lightingBitMask = lightingBitMask
        self.shadowCastBitMask = shadowCastBitMask; self.shadowedBitMask = shadowedBitMask
    }

    /// An override, or the resource's default. Unknown names return nil.
    public func parameter(named name: String) -> ShaderValue? { parameters[name] ?? shader?.parameters[name] }

    /// Sets a finite value of the declared type. Passing nil restores the default.
    public mutating func setParameter(_ value: ShaderValue?, named name: String) throws {
        guard let declared = shader?.parameters[name] else { throw ShaderError.unknownParameter(name) }
        if let value {
            guard value.type == declared.type else { throw ShaderError.typeMismatch(name) }
            guard value.isFinite else { throw ShaderError.nonFiniteValue(name) }
        }
        parameters[name] = value
    }

    private enum CodingKeys: String, CodingKey { case tint, tintAmount, opacity, blendMode, shader, parameters, normalMap, lightingBitMask, shadowCastBitMask, shadowedBitMask }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(tint: try c.decodeColor(forKey: .tint), tintAmount: try c.decode(Float.self, forKey: .tintAmount),
                  opacity: try c.decode(Float.self, forKey: .opacity), blendMode: try c.decode(SpriteBlendMode.self, forKey: .blendMode),
                  shader: try c.decodeIfPresent(ShaderResource.self, forKey: .shader),
                  normalMap: try c.decodeIfPresent(TextureResource.self, forKey: .normalMap),
                  lightingBitMask: try c.decodeIfPresent(UInt32.self, forKey: .lightingBitMask) ?? 0,
                  shadowCastBitMask: try c.decodeIfPresent(UInt32.self, forKey: .shadowCastBitMask) ?? 0,
                  shadowedBitMask: try c.decodeIfPresent(UInt32.self, forKey: .shadowedBitMask) ?? 0)
        for (name, value) in try c.decode([String: ShaderValue].self, forKey: .parameters) {
            try setParameter(value, named: name)
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(color: tint, forKey: .tint); try c.encode(tintAmount, forKey: .tintAmount)
        try c.encode(opacity, forKey: .opacity); try c.encode(blendMode, forKey: .blendMode)
        try c.encodeIfPresent(shader, forKey: .shader); try c.encode(parameters, forKey: .parameters)
        try c.encodeIfPresent(normalMap, forKey: .normalMap); try c.encode(lightingBitMask, forKey: .lightingBitMask)
        try c.encode(shadowCastBitMask, forKey: .shadowCastBitMask); try c.encode(shadowedBitMask, forKey: .shadowedBitMask)
    }

    /// Returns whether SpriteKit's stationary-light shadow cache needs invalidation.
    @MainActor func apply(to node: SKSpriteNode, previous: SpriteMaterial?, isActive: Bool) -> Bool {
        if previous?.blendMode != blendMode { node.blendMode = blendMode.native }
        if previous == nil || previous?.normalMap != normalMap { node.normalTexture = normalMap?.nativeTexture }
        let castMask = isActive ? shadowCastBitMask : 0
        let membershipChanged = node.lightingBitMask != (shader == nil ? lightingBitMask : 0)
            || node.shadowCastBitMask != castMask || node.shadowedBitMask != shadowedBitMask
        node.lightingBitMask = shader == nil ? lightingBitMask : 0
        node.shadowCastBitMask = castMask
        node.shadowedBitMask = shadowedBitMask
        let changed = previous == nil || previous?.shader != shader
        if changed {
            node.shader = shader?.nativeShader
            node.attributeValues = [:]
        }
        guard let shader else { return membershipChanged }
        for name in shader.parameters.keys.sorted() {
            let value = parameter(named: name)!
            if changed || previous?.parameter(named: name) != value {
                node.setValue(value.native, forAttribute: name)
            }
        }
        return membershipChanged
    }
}
