import ECSCore
import SpriteKit
import SwiftUI

/// A value from a node's User Data in Xcode's scene editor.
public enum SceneValue: Hashable, Sendable, Codable {
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
public struct SceneUserDataComponent: Component, Equatable, Sendable, Codable {
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
    /// Mask artwork cannot be represented with matching alpha coverage.
    case unsupportedMask(String)
}

/// Loads `.sks` files made in Xcode's scene editor as entities, in place of
/// `GKScene` and `GKSKNodeComponent`.
///
/// Every node becomes an entity with the same name, place in the hierarchy and
/// ``ECSCore/Transform``. Sprites become a ``SpriteComponent``, physics bodies a
/// ``PhysicsBodyComponent``, lights a ``LightComponent``, tile maps a ``TileMapComponent``
/// and User Data a ``SceneUserDataComponent``. Sprite materials keep normal maps and
/// lighting/shadow masks. Enabled effect nodes become ``RenderGroupComponent`` values;
/// Gaussian blur, bloom and color controls are supported. Unknown filters retain
/// compositing but their filter effect is omitted. Labels and shapes become
/// TextComponent and ShapeComponent, including curves, fill and stroke. Attributed
/// strings load as plain text with the label's base style; shape textures and
/// custom shape shaders are not imported. Emitters become plain entities, and
/// their children still load.
/// Crop nodes import masks made from plain node containers, textured or solid
/// sprites, and shape fills and strokes. Mask RGB is ignored; alpha is preserved.
/// A crop without a mask passes its children through. Unsupported mask artwork
/// throws ``SceneLoadingError/unsupportedMask(_:)`` before the loaded tree is returned:
/// labels, emitters, tile maps, lights, active effects, nested crops, custom shaders,
/// shape glow or textures, nine-slice textures, non-alpha blends, and textured sprites tinted with
/// translucent colors are unsupported.
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
        let root = try entity(from: node)
        if root.name.isEmpty { root.name = url.deletingPathExtension().lastPathComponent }
        return root
    }

    /// Converts a node tree. The node is left as it was.
    func entity(from node: SKNode) throws -> Entity {
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
            if let label = node as? SKLabelNode { entity.components.set(Self.textComponent(from: label)) }
            if let shape = node as? SKShapeNode { entity.components.set(Self.shapeComponent(from: shape)) }
            if let light = node as? SKLightNode {
                entity.components.set(LightComponent(color: Color(light.lightColor), ambientColor: Color(light.ambientColor),
                    shadowColor: Color(light.shadowColor), falloff: Float(light.falloff), categoryBitMask: light.categoryBitMask,
                    isEnabled: light.isEnabled && !light.isHidden))
            }
            if let map = node as? SKTileMapNode {
                entity.components.set(Self.tileMapComponent(from: map))
            }
            if let body = node.physicsBody {
                entity.components.set(Self.physicsComponent(from: body, on: node))
            }
        }

        if let effect = node as? SKEffectNode, effect.shouldEnableEffects {
            let effects = (effect.filter as? RenderGroupFilter)?.effects
                ?? effect.filter.flatMap(PostProcessEffect.init(filter:)).map { [$0] } ?? []
            entity.components.set(RenderGroupComponent(effects: effects, opacity: Float(effect.alpha), blendMode: SpriteBlendMode(effect.blendMode)))
        }

        if let crop = node as? SKCropNode {
            if let mask = crop.maskNode {
                entity.components.set(MaskComponent(.group([try Self.maskLayer(from: mask)])))
            }
            if crop.alpha != 1 || crop.isHidden {
                entity.components.set(RenderGroupComponent(opacity: crop.isHidden ? 0 : Float(crop.alpha)))
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
            if let crop = node as? SKCropNode, child === crop.maskNode { continue }
            entity.addChild(try self.entity(from: child))
        }
        return entity
    }

    // MARK: Conversions

    static func textComponent(from node: SKLabelNode) -> TextComponent {
        let horizontal: TextComponent.HorizontalAlignment = switch node.horizontalAlignmentMode {
        case .left: .left; case .right: .right; default: .center
        }
        let vertical: TextComponent.VerticalAlignment = switch node.verticalAlignmentMode {
        case .baseline: .baseline; case .top: .top; case .bottom: .bottom; default: .center
        }
        let lineBreak: TextComponent.LineBreak = switch node.lineBreakMode {
        case .byCharWrapping: .characterWrap; case .byClipping: .clip; case .byTruncatingHead: .truncateHead
        case .byTruncatingTail: .truncateTail; case .byTruncatingMiddle: .truncateMiddle; default: .wordWrap
        }
        let base = ColorCoding.components(of: Color(node.fontColor ?? .white))
        let tint = ColorCoding.components(of: Color(node.color ?? .white))
        let fraction = Float(node.colorBlendFactor)
        let color = (try? ColorCoding.color(from: zip(base, tint).map { $0 + ($1 - $0) * fraction })) ?? .white
        return TextComponent(node.attributedText?.string ?? node.text ?? "",
            font: node.fontName.map { .named($0, size: Float(node.fontSize)) } ?? .system(size: Float(node.fontSize)), color: color,
            horizontalAlignment: horizontal, verticalAlignment: vertical,
            maxWidth: node.preferredMaxLayoutWidth > 0 ? Float(node.preferredMaxLayoutWidth) : nil,
            numberOfLines: node.numberOfLines, lineBreak: lineBreak, opacity: node.isHidden ? 0 : Float(node.alpha),
            blendMode: SpriteBlendMode(node.blendMode))
    }

    static func shapeComponent(from node: SKShapeNode) -> ShapeComponent {
        let cap: ShapeComponent.LineCap = switch node.lineCap { case .round: .round; case .square: .square; default: .butt }
        let join: ShapeComponent.LineJoin = switch node.lineJoin { case .round: .round; case .bevel: .bevel; default: .miter }
        return ShapeComponent(.path(node.path.map(VectorPath.init) ?? VectorPath()), fill: Color(node.fillColor), stroke: Color(node.strokeColor),
            lineWidth: Float(node.lineWidth), glowWidth: Float(node.glowWidth), lineCap: cap, lineJoin: join, miterLimit: Float(node.miterLimit),
            isAntialiased: node.isAntialiased, opacity: node.isHidden ? 0 : Float(node.alpha), blendMode: SpriteBlendMode(node.blendMode))
    }

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

        var sprite: SpriteComponent
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
        sprite.material.blendMode = SpriteBlendMode(node.blendMode)
        sprite.material.lightingBitMask = node.lightingBitMask
        sprite.material.shadowCastBitMask = node.shadowCastBitMask
        sprite.material.shadowedBitMask = node.shadowedBitMask
        if let normal = node.normalTexture, let image = spriteImage(normal) {
            sprite.material.normalMap = TextureResource(image: image, name: textureName(normal))
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

    /// A tile map's cells and tiles. Every tile definition in the tile set becomes a
    /// tile, named after its group, so variants of a group stay apart.
    static func tileMapComponent(from node: SKTileMapNode) -> TileMapComponent {
        let tileSize = SIMD2(Float(node.tileSize.width), Float(node.tileSize.height))
        var map = TileMapComponent(
            columns: node.numberOfColumns, rows: node.numberOfRows, tileSize: tileSize,
            anchorPoint: [Float(node.anchorPoint.x), Float(node.anchorPoint.y)]
        )
        var indices: [ObjectIdentifier: Int] = [:]
        func index(of definition: SKTileDefinition, in group: SKTileGroup?) -> Int {
            if let index = indices[ObjectIdentifier(definition)] { return index }
            map.tiles.append(tile(from: definition, groupName: group?.name))
            indices[ObjectIdentifier(definition)] = map.tiles.count - 1
            return map.tiles.count - 1
        }
        for group in node.tileSet.tileGroups {
            for rule in group.rules {
                for definition in rule.tileDefinitions { _ = index(of: definition, in: group) }
            }
        }
        for row in 0..<map.rows {
            for column in 0..<map.columns {
                guard let definition = node.tileDefinition(atColumn: column, row: row) else { continue }
                map[tileIndexAt: column, row] = index(of: definition,
                                                      in: node.tileGroup(atColumn: column, row: row))
            }
        }
        return map
    }

    static func tile(from definition: SKTileDefinition, groupName: String?) -> TileMapComponent.Tile {
        var tile = TileMapComponent.Tile(name: groupName ?? definition.name ?? "")
        if let texture = definition.textures.first {
            if let name = textureName(texture) {
                tile.imageName = name
            } else {
                tile.image = spriteImage(texture)
            }
        } else {
            tile.color = .clear
        }
        for (key, value) in definition.userData ?? [:] {
            guard let key = key as? String, let value = sceneValue(value) else { continue }
            tile.userData[key] = value
        }
        return tile
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
