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
    /// Changing the shader clears overrides; the new resource supplies its defaults.
    public var shader: ShaderResource? {
        didSet { if oldValue != shader { parameters = [:] } }
    }
    public private(set) var parameters: [String: ShaderValue] = [:]

    public init(tint: Color = .white, tintAmount: Float = 0, opacity: Float = 1,
                blendMode: SpriteBlendMode = .alpha, shader: ShaderResource? = nil) {
        self.tint = tint; self.tintAmount = tintAmount; self.opacity = opacity
        self.blendMode = blendMode; self.shader = shader
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

    private enum CodingKeys: String, CodingKey { case tint, tintAmount, opacity, blendMode, shader, parameters }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(tint: try c.decodeColor(forKey: .tint), tintAmount: try c.decode(Float.self, forKey: .tintAmount),
                  opacity: try c.decode(Float.self, forKey: .opacity), blendMode: try c.decode(SpriteBlendMode.self, forKey: .blendMode),
                  shader: try c.decodeIfPresent(ShaderResource.self, forKey: .shader))
        for (name, value) in try c.decode([String: ShaderValue].self, forKey: .parameters) {
            try setParameter(value, named: name)
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(color: tint, forKey: .tint); try c.encode(tintAmount, forKey: .tintAmount)
        try c.encode(opacity, forKey: .opacity); try c.encode(blendMode, forKey: .blendMode)
        try c.encodeIfPresent(shader, forKey: .shader); try c.encode(parameters, forKey: .parameters)
    }

    @MainActor func apply(to node: SKSpriteNode, previous: SpriteMaterial?) {
        if previous?.blendMode != blendMode { node.blendMode = blendMode.native }
        let changed = previous == nil || previous?.shader != shader
        if changed {
            node.shader = shader?.nativeShader
            node.attributeValues = [:]
        }
        guard let shader else { return }
        for name in shader.parameters.keys.sorted() {
            let value = parameter(named: name)!
            if changed || previous?.parameter(named: name) != value {
                node.setValue(value.native, forAttribute: name)
            }
        }
    }
}
