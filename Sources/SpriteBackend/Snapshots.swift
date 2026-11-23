import ECSCore
import Foundation
import SpriteKit
import SwiftUI

// Save-and-load support for the sprite backend's components. Colors are saved as sRGB
// RGBA, so a SwiftUI `Color` comes back as the same color, though not as the same named
// value (`.red` loads as an sRGB red).

extension SpriteRenderer {
    /// Registers the backend's components with ``ComponentRegistry``, so world snapshots
    /// save them. A renderer does this when it's made; call it yourself to load a
    /// snapshot before there's a renderer.
    ///
    /// Particle emitters and sounds are left out: they're effects of the moment, and their
    /// sounds point at files in an app bundle that may have moved.
    public nonisolated static func registerComponents() {
        SpriteComponent.registerComponent()
        LightComponent.registerComponent()
        PhysicsBodyComponent.registerComponent()
        PhysicsJointComponent.registerComponent()
        CollisionComponent.registerComponent()
        CharacterControllerComponent.registerComponent()
        CameraComponent.registerComponent()
        LifetimeComponent.registerComponent()
        SceneComponent.registerComponent()
        SceneUserDataComponent.registerComponent()
        TileMapComponent.registerComponent()
    }
}

// MARK: - Color

enum ColorCoding {
    /// sRGB red, green, blue and alpha, each 0...1 (wider for extended-range colors).
    static func components(of color: Color) -> [Float] {
        let color = SKColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        (color.usingColorSpace(.sRGB) ?? color).getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        return [r, g, b, a].map { Float($0) }
    }

    static func color(from components: [Float]) throws -> Color {
        guard components.count == 4 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "A color needs 4 components"))
        }
        let c = components.map(Double.init)
        return Color(.sRGB, red: c[0], green: c[1], blue: c[2], opacity: c[3])
    }
}

extension KeyedEncodingContainer {
    mutating func encode(color: Color, forKey key: Key) throws {
        try encode(ColorCoding.components(of: color), forKey: key)
    }
}

extension KeyedDecodingContainer {
    func decodeColor(forKey key: Key) throws -> Color {
        try ColorCoding.color(from: decode([Float].self, forKey: key))
    }

    func decodeColorIfPresent(forKey key: Key) throws -> Color? {
        try decodeIfPresent([Float].self, forKey: key).map(ColorCoding.color(from:))
    }
}

// MARK: - SpriteImage

extension SpriteImage: Codable {
    private enum CodingKeys: String, CodingKey { case width, height, pixels, smoothsScaling }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let width = try container.decode(Int.self, forKey: .width)
        let height = try container.decode(Int.self, forKey: .height)
        let pixels = try container.decode(Data.self, forKey: .pixels)
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard width > 0, height > 0, !pixelOverflow, !byteOverflow, pixels.count == byteCount else {
            throw DecodingError.dataCorruptedError(forKey: .pixels, in: container,
                debugDescription: "Expected \(width) × \(height) × 4 bytes, found \(pixels.count)")
        }
        self.init(width: width, height: height, pixels: Array(pixels),
                  smoothsScaling: try container.decodeIfPresent(Bool.self, forKey: .smoothsScaling) ?? true)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(Data(pixels), forKey: .pixels)   // base64 in JSON
        try container.encode(smoothsScaling, forKey: .smoothsScaling)
    }
}

// MARK: - SpriteComponent

extension SpriteComponent: Codable {
    private enum CodingKeys: String, CodingKey {
        case imageName, image, texture, color, colorBlendFactor, size, anchorPoint, opacity, material
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(color: try container.decodeColor(forKey: .color), size: .zero)
        imageName = try container.decodeIfPresent(String.self, forKey: .imageName)
        image = try container.decodeIfPresent(SpriteImage.self, forKey: .image)
        texture = try container.decodeIfPresent(TextureResource.self, forKey: .texture)
        colorBlendFactor = try container.decode(Float.self, forKey: .colorBlendFactor)
        size = try container.decodeIfPresent(SIMD2<Float>.self, forKey: .size)
        anchorPoint = try container.decode(SIMD2<Float>.self, forKey: .anchorPoint)
        opacity = try container.decode(Float.self, forKey: .opacity)
        if let material = try container.decodeIfPresent(SpriteMaterial.self, forKey: .material) { self.material = material }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(imageName, forKey: .imageName)
        try container.encodeIfPresent(image, forKey: .image)
        try container.encodeIfPresent(texture, forKey: .texture)
        try container.encode(color: color, forKey: .color)
        try container.encode(colorBlendFactor, forKey: .colorBlendFactor)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encode(anchorPoint, forKey: .anchorPoint)
        try container.encode(opacity, forKey: .opacity)
        try container.encode(material, forKey: .material)
    }
}

// MARK: - Scenes and tile maps

extension SceneComponent: Codable {
    private enum CodingKeys: String, CodingKey { case size, backgroundColor }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(size: try container.decode(SIMD2<Float>.self, forKey: .size),
                  backgroundColor: try container.decodeColor(forKey: .backgroundColor))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(size, forKey: .size)
        try container.encode(color: backgroundColor, forKey: .backgroundColor)
    }
}

extension TileMapComponent.Tile: Codable {
    private enum CodingKeys: String, CodingKey { case name, imageName, image, color, userData }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            imageName: try container.decodeIfPresent(String.self, forKey: .imageName),
            image: try container.decodeIfPresent(SpriteImage.self, forKey: .image),
            color: try container.decodeColorIfPresent(forKey: .color) ?? .white,
            userData: try container.decodeIfPresent([String: SceneValue].self, forKey: .userData) ?? [:]
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(imageName, forKey: .imageName)
        try container.encodeIfPresent(image, forKey: .image)
        try container.encode(color: color, forKey: .color)
        if !userData.isEmpty { try container.encode(userData, forKey: .userData) }
    }
}
