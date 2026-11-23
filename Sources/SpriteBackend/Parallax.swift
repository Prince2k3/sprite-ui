import ECSCore
import Foundation
import SpriteKit

/// Camera-relative translation of an entity's own sprite artwork.
/// A factor of one scrolls normally; zero follows camera translation. Children,
/// entity transforms, physics, and attachment anchors remain in world space.
/// Enabled background artwork is decorative and excluded from displayed picking.
public struct ParallaxComponent: Component, Hashable, Codable, Sendable {
    public var scrollFactor: SIMD2<Float>
    public var referencePosition: SIMD2<Float>
    public var isEnabled: Bool

    public init(scrollFactor: SIMD2<Float> = [0.5, 0.5],
                referencePosition: SIMD2<Float> = .zero, isEnabled: Bool = true) {
        self.scrollFactor = scrollFactor; self.referencePosition = referencePosition
        self.isEnabled = isEnabled
    }

    /// Scene-space displacement, including the selected camera's presented shake.
    /// Finite factors outside zero through one are supported. Invalid inputs give zero.
    public func offset(forCameraPosition position: SIMD2<Float>) -> SIMD2<Float> {
        guard isEnabled else { return .zero }
        let result = (position - referencePosition) * (SIMD2<Float>(repeating: 1) - scrollFactor)
        return result.x.isFinite && result.y.isFinite ? result : .zero
    }
}

/// Repeats an entity's own sprite to cover the selected camera's view.
/// The sprite's presented size determines the tile period. Tiles share its
/// texture and material, without creating entities or physics bodies. Other
/// drawings, children and attachment anchors are not repeated. Empty axes or a
/// disabled component retain the ordinary sprite. Enabled artwork is decorative.
public struct RepeatingBackgroundComponent: Component, Hashable, Codable, Sendable {
    public struct Axes: OptionSet, Hashable, Codable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let horizontal = Self(rawValue: 1)
        public static let vertical = Self(rawValue: 2)
        public static let both: Self = [.horizontal, .vertical]
    }
    public var axes: Axes
    /// A tile budget per camera. Counts above this budget omit the artwork;
    /// a hard ceiling of 16,384 also applies. Increase tile size for wide views.
    public var maximumTileCount: Int
    public var isEnabled: Bool

    public init(axes: Axes = .both, maximumTileCount: Int = 1024, isEnabled: Bool = true) {
        self.axes = axes; self.maximumTileCount = maximumTileCount; self.isEnabled = isEnabled
    }
}

extension SpriteRenderer {
    struct BackgroundPresentation {
        let sprite: SKSpriteNode
        let position: CGPoint
        let hidden: Bool
    }
    struct BackgroundContext {
        let camera: SKCameraNode?
        let size: CGSize
    }
    @MainActor final class BackgroundTiles {
        let container = SKNode()
        var sprites: [SKSpriteNode] = []
        init() { container.name = "__repeatingBackground"; container.isHidden = true }
    }

    static let repeatingBackgroundBinding = Binding<RepeatingBackgroundComponent>(apply: { value, _, _, animator in
        if value == nil { animator.renderer.removeBackgroundTiles(for: animator.entityID) }
    })

    func removeBackgroundTiles(for id: Entity.ID) {
        backgroundTiles.removeValue(forKey: id)?.container.removeFromParent()
    }

    func updateBackgroundMembership(_ entity: Entity) {
        if entity.components.has(ParallaxComponent.self) || entity.components.has(RepeatingBackgroundComponent.self) {
            backgroundEntities.insert(entity.id)
        } else { backgroundEntities.remove(entity.id) }
    }

    func restoreBackgroundPresentation() {
        guard backgroundContext != nil || !backgroundPresentations.isEmpty else { return }
        for value in backgroundPresentations {
            value.sprite.position = value.position; value.sprite.isHidden = value.hidden
        }
        backgroundPresentations.removeAll(keepingCapacity: true)
        for pool in backgroundTiles.values { pool.container.isHidden = true }
        backgroundContext = nil
    }

    func applyBackgroundPresentation(camera: SKCameraNode?, size: CGSize) {
        restoreBackgroundPresentation()
        backgroundContext = .init(camera: camera, size: size)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        guard camera == nil || camera?.scene === self else { return }
        let cameraPoint = camera?.convert(CGPoint.zero, to: self) ?? CGPoint.zero
        let cameraPosition = SIMD2(Float(cameraPoint.x), Float(cameraPoint.y))
        let corners = [CGPoint(x: -size.width / 2, y: -size.height / 2),
                       CGPoint(x: size.width / 2, y: -size.height / 2),
                       CGPoint(x: size.width / 2, y: size.height / 2),
                       CGPoint(x: -size.width / 2, y: size.height / 2)]
            .map { camera?.convert($0, to: self) ?? $0 }
        for id in backgroundEntities {
            guard let entity = world.entity(withID: id), entity.isActive else { continue }
            let parallax = entity.components[ParallaxComponent.self]
            let repeating = entity.components[RepeatingBackgroundComponent.self]
            let repeats = repeating.map { $0.isEnabled && !$0.axes.intersection(.both).isEmpty } ?? false
            guard parallax?.isEnabled == true || repeats,
                  let node = node(for: entity),
                  let sprite = Self.contentRoot(node).childNode(withName: Self.spriteNodeName) as? SKSpriteNode,
                  sprite.physicsBody == nil, !sprite.isHidden, let parent = sprite.parent else { continue }
            backgroundPresentations.append(.init(sprite: sprite, position: sprite.position, hidden: sprite.isHidden))
            let offset = parallax?.offset(forCameraPosition: cameraPosition) ?? .zero
            let origin = parent.convert(CGPoint.zero, from: self)
            let shifted = parent.convert(CGPoint(x: CGFloat(offset.x), y: CGFloat(offset.y)), from: self)
            let position = CGPoint(x: sprite.position.x + shifted.x - origin.x,
                                   y: sprite.position.y + shifted.y - origin.y)
            guard position.x.isFinite, position.y.isFinite else { sprite.isHidden = true; continue }
            if repeats, let repeating {
                sprite.isHidden = true
                let points = corners.map { parent.convert($0, from: self) }
                drawBackground(sprite, at: position, in: points, component: repeating, owner: entity.id, parent: parent)
            } else { sprite.position = position }
        }
    }

    private func drawBackground(_ source: SKSpriteNode, at position: CGPoint, in corners: [CGPoint],
                                component: RepeatingBackgroundComponent, owner: Entity.ID, parent: SKNode) {
        let width = source.size.width, height = source.size.height
        let budget = min(component.maximumTileCount, 16_384)
        guard budget > 0, width.isFinite, height.isFinite, width > 0, height > 0,
              source.anchorPoint.x.isFinite, source.anchorPoint.y.isFinite,
              source.xScale == 1, source.yScale == 1, source.zRotation == 0,
              corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
              let horizontal = Self.backgroundAxis(origin: position.x, minimum: minX, maximum: maxX,
                  period: width, anchor: source.anchorPoint.x, repeats: component.axes.contains(.horizontal), budget: budget),
              let vertical = Self.backgroundAxis(origin: position.y, minimum: minY, maximum: maxY,
                  period: height, anchor: source.anchorPoint.y, repeats: component.axes.contains(.vertical), budget: budget),
              horizontal.count <= budget / vertical.count else { return }
        let count = horizontal.count * vertical.count
        let pool = backgroundTiles[owner] ?? BackgroundTiles()
        backgroundTiles[owner] = pool
        if pool.container.parent !== parent { pool.container.removeFromParent(); parent.addChild(pool.container) }
        // Match the original sprite's sibling position as well as its z ordering.
        if let index = parent.children.firstIndex(where: { $0 === source }),
           parent.children.firstIndex(where: { $0 === pool.container }) != index + 1 {
            pool.container.removeFromParent()
            if let sourceIndex = parent.children.firstIndex(where: { $0 === source }) {
                parent.insertChild(pool.container, at: sourceIndex + 1)
            }
        }
        pool.container.zPosition = source.zPosition
        pool.container.isHidden = false
        while pool.sprites.count < count {
            let tile = SKSpriteNode(); pool.sprites.append(tile); pool.container.addChild(tile)
        }
        for (index, tile) in pool.sprites.enumerated() {
            guard index < count else { tile.isHidden = true; continue }
            tile.isHidden = false
            tile.texture = source.texture; tile.normalTexture = source.normalTexture
            tile.size = source.size; tile.anchorPoint = source.anchorPoint
            tile.color = source.color; tile.colorBlendFactor = source.colorBlendFactor
            tile.alpha = source.alpha; tile.blendMode = source.blendMode
            tile.shader = source.shader; tile.attributeValues = source.attributeValues
            tile.centerRect = source.centerRect
            tile.lightingBitMask = source.lightingBitMask
            tile.shadowCastBitMask = source.shadowCastBitMask; tile.shadowedBitMask = source.shadowedBitMask
            tile.position = CGPoint(x: horizontal.start + CGFloat(index % horizontal.count) * width,
                                    y: vertical.start + CGFloat(index / horizontal.count) * height)
        }
    }

    /// Wrap phase near the view before making integer counts. Double remainder
    /// avoids enumerating enormous positive or negative world-space tile indexes.
    static func backgroundAxis(origin: CGFloat, minimum: CGFloat, maximum: CGFloat,
                               period: CGFloat, anchor: CGFloat, repeats: Bool, budget: Int) -> (start: CGFloat, count: Int)? {
        guard repeats else { return (origin, 1) }
        var phase = (origin - anchor * period - minimum).truncatingRemainder(dividingBy: period)
        if phase < 0 { phase += period }
        let left = minimum + phase - period
        let extent = ceil((maximum - left) / period) + 1
        guard extent.isFinite, extent > 0, extent <= CGFloat(budget) else { return nil }
        return (left + anchor * period, Int(extent))
    }

    func hasDecorativeBackground(_ entity: Entity) -> Bool {
        entity.components[ParallaxComponent.self]?.isEnabled == true
            || entity.components[RepeatingBackgroundComponent.self].map { $0.isEnabled && !$0.axes.intersection(.both).isEmpty } == true
    }
}
