import ECSCore
import SpriteKit
import SwiftUI

/// Alpha-only mask artwork. Shapes are filled white; use a path with opposite
/// contour winding for holes. Texture pixels retain their alpha, regardless of
/// RGB. A group combines its layers with ordinary source-over alpha (a union).
public indirect enum MaskContent: Equatable, Codable, Sendable {
    case shape(ShapeGeometry)
    case texture(TextureResource, size: SIMD2<Float>, anchorPoint: SIMD2<Float> = [0.5, 0.5])
    case group([MaskLayer])
    /// Clips everything. Unlike a disabled mask, empty artwork never reveals content.
    case empty
}

/// One independently placed part of a compound mask. Nested layer edits are
/// immediate; the root MaskComponent transform and opacity support withAnimation.
public struct MaskLayer: Equatable, Codable, Sendable {
    public var content: MaskContent
    public var transform: Transform
    public var opacity: Float
    public init(_ content: MaskContent, transform: Transform = .identity, opacity: Float = 1) {
        self.content = content; self.transform = transform; self.opacity = opacity
    }
}

/// Clips an entity's visuals and descendants, including targeted input, without
/// changing transforms, physics bodies or model-space physics queries. Nested
/// entity masks intersect. Masks use SpriteKit's alpha cutoff of 0.05, not a fade;
/// use visual opacity or RenderGroupComponent for translucent content.
///
/// Mask transforms are local to the entity and independent of its content. Root
/// translation, rotation, scale and opacity animate with withAnimation, and
/// presentation values and hit tests use the displayed pose. Invalid artwork or
/// a singular/nonfinite transform clips everything. isEnabled bypasses clipping.
/// At antialiased shape boundaries input uses the geometric path; textures use
/// their nearest/linear sampling mode. Filter halos do not enlarge input regions.
///
/// On the same entity, clipping precedes render-group filters. Put the mask on a
/// parent entity to also clip a child's blur/glow. Keep cameras outside masked
/// content. SwiftUI overlays and attachments are hosted separately and are not
/// clipped; their input regions remain independent. Masks add offscreen rendering
/// work, so keep large/nested animated masks limited to content that needs them.
///
/// ```swift
/// viewport.components.set(MaskComponent(shape: .circle(radius: 90)))
/// withAnimation(.easeInOut(duration: 0.4)) {
///     viewport.components[MaskComponent.self]?.transform.translation = [20, 0]
/// }
/// ```
public struct MaskComponent: Component, Equatable, Codable, Sendable {
    public var content: MaskContent
    public var transform: Transform
    public var opacity: Float
    public var isEnabled: Bool
    public init(_ content: MaskContent, transform: Transform = .identity, opacity: Float = 1, isEnabled: Bool = true) {
        self.content = content; self.transform = transform; self.opacity = opacity; self.isEnabled = isEnabled
    }
    public init(shape: ShapeGeometry, transform: Transform = .identity, opacity: Float = 1, isEnabled: Bool = true) {
        self.init(.shape(shape), transform: transform, opacity: opacity, isEnabled: isEnabled)
    }
    public init(texture: TextureResource, size: SIMD2<Float>? = nil, anchorPoint: SIMD2<Float> = [0.5, 0.5],
                transform: Transform = .identity, opacity: Float = 1, isEnabled: Bool = true) {
        self.init(.texture(texture, size: size ?? texture.size, anchorPoint: anchorPoint), transform: transform, opacity: opacity, isEnabled: isEnabled)
    }
}

private func maskOpacity(_ value: Float) -> Float { value.isFinite ? min(1, max(0, value)) : 0 }
private func validMaskTransform(_ value: Transform) -> Bool {
    [value.translation.x, value.translation.y, value.rotation, value.scale.x, value.scale.y, value.zPosition].allSatisfy(\.isFinite)
}

/// The mask tree is detached from the scene graph, as required by SKCropNode.
/// Immutable artwork is shared; each instance owns its nodes and presented pose.
@MainActor final class MaskDrawingNode: SKNode {
    var content = MaskContent.empty
    var validTransform = true
    private var outline: CGPath?

    func setContent(_ content: MaskContent) {
        self.content = content; outline = nil; removeAllChildren()
        switch content {
        case .empty: break
        case .shape(let geometry):
            if case .roundedRectangle(_, let radius) = geometry, !radius.isFinite || radius < 0 { break }
            outline = geometry.native
            if let outline {
                let shape = SKShapeNode(path: outline); shape.fillColor = .white; shape.strokeColor = .clear; shape.lineWidth = 0
                addChild(shape)
            }
        case .texture(let texture, let size, let anchor):
            guard size.x.isFinite, size.y.isFinite, size.x > 0, size.y > 0, anchor.x.isFinite, anchor.y.isFinite else { break }
            let sprite = SKSpriteNode(texture: texture.nativeTexture)
            sprite.size = CGSize(width: CGFloat(size.x), height: CGFloat(size.y)); sprite.anchorPoint = CGPoint(x: CGFloat(anchor.x), y: CGFloat(anchor.y))
            addChild(sprite)
        case .group(let layers):
            for layer in layers {
                let child = MaskDrawingNode(); child.setContent(layer.content); child.setPose(layer.transform, opacity: layer.opacity); addChild(child)
            }
        }
    }
    func setPose(_ value: Transform, opacity: Float) {
        validTransform = validMaskTransform(value); isHidden = !validTransform
        guard validTransform else { return }
        position = CGPoint(x: CGFloat(value.translation.x), y: CGFloat(value.translation.y)); zRotation = CGFloat(value.rotation)
        xScale = CGFloat(value.scale.x); yScale = CGFloat(value.scale.y); zPosition = CGFloat(value.zPosition); alpha = CGFloat(maskOpacity(opacity))
    }

    func coverage(at parentPoint: SIMD2<Float>, inheritedOpacity: Float = 1) -> Float {
        guard validTransform, !isHidden, parentPoint.x.isFinite, parentPoint.y.isFinite else { return 0 }
        let transform = Transform(translation: [Float(position.x), Float(position.y)], rotation: Float(zRotation), scale: [Float(xScale), Float(yScale)])
        guard let inverse = transform.matrix.inverted() else { return 0 }
        let point = inverse.apply(to: parentPoint)
        let effectiveOpacity = inheritedOpacity * maskOpacity(Float(self.alpha))
        let alpha: Float
        switch content {
        case .empty: alpha = 0
        case .shape: alpha = outline?.contains(CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))) == true ? 1 : 0
        case .texture(let texture, let size, let anchor): alpha = Self.sample(texture.image, size: size, anchor: anchor, point: point)
        case .group:
            var combined: Float = 0
            for case let child as MaskDrawingNode in children {
                let a = child.coverage(at: point, inheritedOpacity: effectiveOpacity); combined = a + combined * (1 - a)
            }
            return combined
        }
        return alpha * effectiveOpacity
    }

    private static func sample(_ image: SpriteImage, size: SIMD2<Float>, anchor: SIMD2<Float>, point: SIMD2<Float>) -> Float {
        guard size.x.isFinite, size.y.isFinite, size.x > 0, size.y > 0 else { return 0 }
        let uv = point / size + anchor
        guard uv.x.isFinite, uv.y.isFinite, uv.x >= 0, uv.y >= 0, uv.x < 1, uv.y < 1 else { return 0 }
        let x = uv.x * Float(image.width), y = (1 - uv.y) * Float(image.height)
        func alpha(_ x: Int, _ y: Int) -> Float {
            let column = min(image.width - 1, max(0, x)), row = min(image.height - 1, max(0, y))
            return Float(image.pixels[(row * image.width + column) * 4 + 3]) / 255
        }
        guard image.smoothsScaling else { return alpha(Int(x), Int(y)) }
        let px = x - 0.5, py = y - 0.5, ix = Int(floor(px)), iy = Int(floor(py)), fx = px - floor(px), fy = py - floor(py)
        return (alpha(ix, iy) * (1 - fx) + alpha(ix + 1, iy) * fx) * (1 - fy)
            + (alpha(ix, iy + 1) * (1 - fx) + alpha(ix + 1, iy + 1) * fx) * fy
    }
}

@MainActor final class MaskCropNode: SKCropNode {
    let artwork = MaskDrawingNode()
}

extension SpriteRenderer {
    static let maskNodeName = "__maskContent"
    static let maskKeys = ["mask.position", "mask.rotation", "mask.scale", "mask.opacity"]
    static func contentRoot(_ node: SKNode) -> SKNode { node.childNode(withName: maskNodeName) as? MaskCropNode ?? node }
    static func bindingRoot(_ type: ObjectIdentifier, node: SKNode) -> SKNode {
        let roots: [any Component.Type] = [Transform.self, PhysicsBodyComponent.self, CollisionComponent.self, CameraComponent.self, RenderGroupComponent.self, MaskComponent.self]
        return roots.contains { ObjectIdentifier($0) == type } ? node : contentRoot(node)
    }

    private func prepareMaskReparent(_ id: Entity.ID) {
        var ids: Set<Entity.ID> = []
        world.entity(withID: id)?.visit { ids.insert($0.id) }
        removePhysicsJoints(involving: ids); needsLightingRefresh = true
    }
    static let maskBinding = Binding<MaskComponent>(apply: { new, old, node, animator in
        let existing = node.childNode(withName: maskNodeName) as? MaskCropNode
        guard let value = new else {
            guard let existing else { return }
            for key in maskKeys { animator.cancel(key, on: existing.artwork) }
            animator.renderer.prepareMaskReparent(animator.entityID)
            for child in existing.children { child.removeFromParent(); node.addChild(child) }
            existing.removeFromParent(); return
        }
        let crop: MaskCropNode
        if let existing { crop = existing }
        else {
            animator.renderer.prepareMaskReparent(animator.entityID)
            crop = MaskCropNode(); crop.name = maskNodeName
            let children = node.children
            node.addChild(crop)
            for child in children where !(child is SKCameraNode) { child.removeFromParent(); crop.addChild(child) }
        }
        let mask = crop.artwork
        if existing == nil || old?.content != value.content { mask.setContent(value.content) }
        crop.maskNode = value.isEnabled ? mask : nil
        let previous = existing == nil ? nil : old
        let animator = previous == nil || !value.isEnabled
            ? Animator(renderer: animator.renderer, entityID: animator.entityID, transaction: nil) : animator
        let valid = validMaskTransform(value.transform)
        mask.validTransform = valid; mask.isHidden = !valid
        guard valid else { for key in maskKeys { animator.cancel(key, on: mask) }; return }
        if !value.isEnabled {
            for key in maskKeys { animator.cancel(key, on: mask) }
            mask.setPose(value.transform, opacity: value.opacity); return
        }
        if previous?.transform.translation != value.transform.translation || old.map({ !validMaskTransform($0.transform) }) == true {
            let to = CGPoint(x: CGFloat(value.transform.translation.x), y: CGFloat(value.transform.translation.y)), start = mask.position
            animator.update("mask.position", on: mask, to: { .move(to: to, duration: $0) }, from: { .move(to: start, duration: $0) }, set: { mask.position = to })
        }
        if previous?.transform.rotation != value.transform.rotation || old.map({ !validMaskTransform($0.transform) }) == true {
            let to = CGFloat(value.transform.rotation), start = mask.zRotation
            animator.update("mask.rotation", on: mask, to: { .rotate(toAngle: to, duration: $0) }, from: { .rotate(toAngle: start, duration: $0) }, set: { mask.zRotation = to })
        }
        if previous?.transform.scale != value.transform.scale || old.map({ !validMaskTransform($0.transform) }) == true {
            let to = value.transform.scale, start = SIMD2(Float(mask.xScale), Float(mask.yScale))
            animator.update("mask.scale", on: mask, to: { .scaleX(to: CGFloat(to.x), y: CGFloat(to.y), duration: $0) },
                from: { .scaleX(to: CGFloat(start.x), y: CGFloat(start.y), duration: $0) }, set: { mask.xScale = CGFloat(to.x); mask.yScale = CGFloat(to.y) })
        }
        mask.zPosition = CGFloat(value.transform.zPosition)
        if previous?.opacity != value.opacity || old.map({ !validMaskTransform($0.transform) }) == true {
            animateDrawingOpacity(maskOpacity(value.opacity), on: mask, key: "mask.opacity", animator: animator)
        }
    }, present: { node, model in
        guard let crop = node.childNode(withName: maskNodeName) as? MaskCropNode, model.isEnabled, validMaskTransform(model.transform) else { return model }
        var value = model; let mask = crop.artwork
        value.transform = Transform(translation: [Float(mask.position.x), Float(mask.position.y)], rotation: Float(mask.zRotation),
                                    scale: [Float(mask.xScale), Float(mask.yScale)], zPosition: Float(mask.zPosition))
        value.opacity = Float(mask.alpha); return value
    })

    func maskAllows(_ scenePoint: CGPoint, node: SKNode) -> Bool {
        guard scenePoint.x.isFinite, scenePoint.y.isFinite else { return false }
        guard let crop = node.childNode(withName: Self.maskNodeName) as? MaskCropNode, crop.maskNode != nil else { return true }
        let point = crop.convert(scenePoint, from: self)
        return crop.artwork.coverage(at: [Float(point.x), Float(point.y)]) >= 0.05
    }

    /// Tests only the displayed masks on this entity and its ancestors. It does
    /// not check collision shapes, activation, viewport bounds or visual opacity.
    public func isPointVisible(_ scenePoint: SIMD2<Float>, throughMasksOf entity: Entity) -> Bool {
        guard entity.world === world, scenePoint.x.isFinite, scenePoint.y.isFinite else { return false }
        var current: Entity? = entity
        while let value = current {
            guard let node = node(for: value), maskAllows(CGPoint(x: CGFloat(scenePoint.x), y: CGFloat(scenePoint.y)), node: node) else { return false }
            current = value.parent
        }
        return true
    }
}
