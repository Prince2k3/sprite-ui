import ECSCore
import SpriteKit
import SwiftUI

/// A value from a node's User Data in Xcode's scene editor.
public enum SceneValue: Hashable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    public var bool: Bool? {
        switch self {
        case .bool(let value): value
        case .int(let value): value != 0
        default: nil
        }
    }

    public var int: Int? {
        switch self {
        case .int(let value): value
        case .double(let value): Int(exactly: value.rounded())
        case .bool(let value): value ? 1 : 0
        case .string(let value): Int(value)
        }
    }

    public var double: Double? {
        switch self {
        case .double(let value): value
        case .int(let value): Double(value)
        case .string(let value): Double(value)
        case .bool: nil
        }
    }

    public var float: Float? { double.map(Float.init) }

    public var string: String? {
        switch self {
        case .string(let value): value
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .bool(let value): String(value)
        }
    }
}

/// The User Data a node had in the scene editor, kept on the entity loaded from it.
public struct SceneUserDataComponent: Component, Equatable, Sendable {
    public var values: [String: SceneValue]

    public init(_ values: [String: SceneValue] = [:]) {
        self.values = values
    }

    public subscript(key: String) -> SceneValue? {
        get { values[key] }
        set { values[key] = newValue }
    }
}

/// What the root entity of a loaded scene knows about the scene it came from.
public struct SceneComponent: Component, Equatable {
    /// The scene's size in the editor, in points.
    public var size: SIMD2<Float>
    public var backgroundColor: Color

    public init(size: SIMD2<Float>, backgroundColor: Color = .black) {
        self.size = size
        self.backgroundColor = backgroundColor
    }
}

public enum SceneLoadingError: Error, Equatable {
    /// There's no `<name>.sks` in the bundle.
    case notFound(String)
    /// The file isn't a SpriteKit scene.
    case unreadable(URL)
}

/// Loads `.sks` files made in Xcode's scene editor as entities, in place of
/// `GKScene` and `GKSKNodeComponent`.
///
/// Every node becomes an entity with the same name, place in the hierarchy and
/// ``ECSCore/Transform``. Sprites become a ``SpriteComponent``, physics bodies a
/// ``PhysicsBodyComponent``, and User Data a ``SceneUserDataComponent``. Other kinds
/// of node (labels, shapes, emitters, lights) become plain entities, and their children
/// still load.
///
/// The root entity stands for the scene. It's placed so the scene looks the way it
/// did in the editor in a view centered on the origin, whatever the scene's anchor point.
///
/// ```swift
/// let level = try Entity.load(named: "Level")
/// content.add(level)
/// let player = level.findEntity(named: "player")
/// ```
///
/// To build your own components from User Data, in the way `GKScene` adds the
/// `GKComponent`s set in the editor, register a maker for a key:
///
/// ```swift
/// var loader = SceneLoader()
/// loader.register("hp") { Health(hp: $0.int ?? 1) }
/// let level = try loader.load(named: "Level")
/// ```
///
/// Physics bodies don't report their shape, so it's worked out from the body's area:
/// a sprite's body is a rectangle of the sprite's size or a circle that fits it,
/// whichever matches, and any other body is a circle of the same area. Alpha mask
/// bodies come back as rectangles.
@MainActor
public struct SceneLoader {
    public typealias Maker = @MainActor (SceneValue) -> (any Component)?

    public var bundle: Bundle
    private var makers: [String: Maker] = [:]

    public init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// Adds the component `make` returns to every entity whose node has `key` in its
    /// User Data. Returning `nil` adds nothing.
    public mutating func register(_ key: String, _ make: @escaping Maker) {
        makers[key] = make
    }

    /// Loads `<name>.sks` from the loader's bundle.
    public func load(named name: String) throws -> Entity {
        let file = name.hasSuffix(".sks") ? String(name.dropLast(4)) : name
        guard let url = bundle.url(forResource: file, withExtension: "sks") else {
            throw SceneLoadingError.notFound(name)
        }
        return try load(contentsOf: url)
    }

    /// Loads an `.sks` file.
    public func load(contentsOf url: URL) throws -> Entity {
        guard let data = try? Data(contentsOf: url),
              let node = try? NSKeyedUnarchiver.unarchivedObject(ofClass: SKNode.self, from: data)
        else { throw SceneLoadingError.unreadable(url) }
        let root = entity(from: node)
        if root.name.isEmpty { root.name = url.deletingPathExtension().lastPathComponent }
        return root
    }

    /// Converts a node tree. The node is left as it was.
    func entity(from node: SKNode) -> Entity {
        let entity = Entity()
        entity.name = node.name ?? ""

        if let scene = node as? SKScene {
            let size = SIMD2(Float(scene.size.width), Float(scene.size.height))
            let anchor = SIMD2(Float(scene.anchorPoint.x), Float(scene.anchorPoint.y))
            entity.position = size * (anchor - 0.5)
            entity.components.set(SceneComponent(size: size, backgroundColor: Color(scene.backgroundColor)))
        } else {
            entity.transform = Transform(
                translation: [Float(node.position.x), Float(node.position.y)],
                rotation: Float(node.zRotation),
                scale: [Float(node.xScale), Float(node.yScale)],
                zPosition: Float(node.zPosition)
            )
            if let sprite = node as? SKSpriteNode {
                entity.components.set(Self.spriteComponent(from: sprite))
            }
            if let body = node.physicsBody {
                entity.components.set(Self.physicsComponent(from: body, on: node))
            }
        }

        if let userData = node.userData, userData.count > 0 {
            var values: [String: SceneValue] = [:]
            for (key, value) in userData {
                guard let key = key as? String, let value = Self.sceneValue(value) else { continue }
                values[key] = value
            }
            entity.components.set(SceneUserDataComponent(values))
            for (key, value) in values.sorted(by: { $0.key < $1.key }) {
                if let make = makers[key], let component = make(value) {
                    entity.components.set([component])
                }
            }
        }

        for child in node.children {
            entity.addChild(self.entity(from: child))
        }
        return entity
    }

    // MARK: Conversions

    /// A sprite's size before its scale. SpriteKit reports `size` already scaled, while
    /// the entity's transform applies the scale again.
    static func unscaledSize(of node: SKSpriteNode) -> SIMD2<Float> {
        let scale = SIMD2(Float(node.xScale), Float(node.yScale))
        let size = SIMD2(Float(node.size.width), Float(node.size.height))
        return SIMD2(scale.x == 0 ? size.x : size.x / abs(scale.x), scale.y == 0 ? size.y : size.y / abs(scale.y))
    }

    static func spriteComponent(from node: SKSpriteNode) -> SpriteComponent {
        let size = unscaledSize(of: node)
        let anchor = SIMD2(Float(node.anchorPoint.x), Float(node.anchorPoint.y))
        let opacity = node.isHidden ? 0 : Float(node.alpha)
        let color = Color(node.color)

        let sprite: SpriteComponent
        if let texture = node.texture {
            if let name = textureName(texture) {
                sprite = SpriteComponent(imageName: name, size: size, tint: color,
                                         tintAmount: Float(node.colorBlendFactor),
                                         anchorPoint: anchor, opacity: opacity)
            } else if let image = spriteImage(texture) {
                sprite = SpriteComponent(image: image, size: size, tint: color,
                                         tintAmount: Float(node.colorBlendFactor),
                                         anchorPoint: anchor, opacity: opacity)
            } else {
                sprite = SpriteComponent(color: color, size: size, anchorPoint: anchor, opacity: opacity)
            }
        } else {
            sprite = SpriteComponent(color: color, size: size, anchorPoint: anchor, opacity: opacity)
        }
        return sprite
    }

    /// The image name a texture was loaded with. SpriteKit only shows it in the description,
    /// as `<SKTexture> 'name' (w x h)`, or `'<data>'` for textures made from pixels.
    static func textureName(_ texture: SKTexture) -> String? {
        let description = texture.description
        guard let start = description.firstIndex(of: "'"),
              let end = description[description.index(after: start)...].firstIndex(of: "'")
        else { return nil }
        let name = String(description[description.index(after: start)..<end])
        return name.isEmpty || name == "(null)" || name.hasPrefix("<") ? nil : name
    }

    /// A texture's pixels, for textures that weren't loaded by name.
    static func spriteImage(_ texture: SKTexture) -> SpriteImage? {
        let cgImage = texture.cgImage()
        let width = cgImage.width, height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // Un-premultiply, since SpriteImage holds straight alpha.
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[i + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for c in 0..<3 { pixels[i + c] = UInt8(min(255, Int(pixels[i + c]) * 255 / alpha)) }
        }
        return SpriteImage(width: width, height: height, pixels: pixels,
                           smoothsScaling: texture.filteringMode == .linear)
    }

    static func physicsComponent(from body: SKPhysicsBody, on node: SKNode) -> PhysicsBodyComponent {
        PhysicsBodyComponent(
            shape: physicsShape(of: body, on: node),
            isDynamic: body.isDynamic,
            mass: nil,
            density: Float(body.density),
            friction: Float(body.friction),
            restitution: Float(body.restitution),
            linearDamping: Float(body.linearDamping),
            angularDamping: Float(body.angularDamping),
            affectedByGravity: body.affectedByGravity,
            allowsRotation: body.allowsRotation,
            usesPreciseCollisionDetection: body.usesPreciseCollisionDetection,
            categoryBitMask: body.categoryBitMask,
            collisionBitMask: body.collisionBitMask,
            contactTestBitMask: body.contactTestBitMask,
            velocity: [Float(body.velocity.dx), Float(body.velocity.dy)],
            angularVelocity: Float(body.angularVelocity)
        )
    }

    /// SpriteKit measures area in square meters, at 150 points per meter.
    private static let pointsPerMeter: Float = 150

    static func physicsShape(of body: SKPhysicsBody, on node: SKNode) -> PhysicsShape {
        let area = Float(body.area) * pointsPerMeter * pointsPerMeter
        guard let sprite = node as? SKSpriteNode, sprite.size.width > 0, sprite.size.height > 0 else {
            return .circle(radius: (max(area, 0) / .pi).squareRoot())
        }
        // The editor's bodies fit the sprite: a rectangle of its size, or a circle around
        // its longer side. Bodies made in code may have used the scaled size instead.
        let scaled = SIMD2(Float(sprite.size.width), Float(sprite.size.height))
        var candidates: [(shape: PhysicsShape, area: Float)] = []
        for size in [unscaledSize(of: sprite), scaled] {
            let radius = max(size.x, size.y) / 2
            candidates.append((.rectangle(size: size), size.x * size.y))
            candidates.append((.circle(radius: radius), .pi * radius * radius))
        }
        return candidates.min { abs($0.area - area) < abs($1.area - area) }!.shape
    }

    static func sceneValue(_ value: Any) -> SceneValue? {
        switch value {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if CFNumberIsFloatType(number) { return .double(number.doubleValue) }
            return .int(number.intValue)
        default:
            return nil
        }
    }
}

extension Entity {
    /// Loads `<name>.sks`, made in Xcode's scene editor, as an entity tree. See ``SceneLoader``.
    public static func load(named name: String, in bundle: Bundle = .main) throws -> Entity {
        try SceneLoader(bundle: bundle).load(named: name)
    }

    /// Loads an `.sks` file as an entity tree. See ``SceneLoader``.
    public static func load(contentsOf url: URL) throws -> Entity {
        try SceneLoader().load(contentsOf: url)
    }
}

private extension Color {
    init(_ color: SKColor) {
        #if canImport(UIKit)
        self.init(uiColor: color)
        #else
        self.init(nsColor: color)
        #endif
    }
}
