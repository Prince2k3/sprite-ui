import ECSCore
import SpriteKit

func drawingSize(_ value: Float) -> CGFloat { value.isFinite ? CGFloat(max(0, value)) : 0 }

@MainActor func animateDrawingOpacity(_ opacity: Float, on node: SKNode, key: String, animator: Animator) {
    let target = CGFloat(opacity.isFinite ? min(1, max(0, opacity)) : 0), start = node.alpha
    animator.update(key, on: node, to: { .fadeAlpha(to: target, duration: $0) },
                    from: { .fadeAlpha(to: start, duration: $0) }, set: { node.alpha = target })
}

extension ShapeComponent.LineCap {
    var native: CGLineCap { switch self { case .butt: .butt; case .round: .round; case .square: .square } }
}
extension ShapeComponent.LineJoin {
    var native: CGLineJoin { switch self { case .miter: .miter; case .round: .round; case .bevel: .bevel } }
}

extension SpriteRenderer {
    static let shapeNodeName = "__shape"
    static let shapeBinding = Binding<ShapeComponent>(apply: { new, old, node, animator in
        let existing = node.childNode(withName: shapeNodeName) as? SKShapeNode
        guard let value = new else {
            if let existing { animator.cancel("shape.opacity", on: existing); existing.removeFromParent() }; return
        }
        let shape = existing ?? SKShapeNode()
        if existing == nil { shape.name = shapeNodeName; node.addChild(shape) }
        let previous = existing == nil ? nil : old
        if previous?.geometry != value.geometry { shape.path = value.geometry.native }
        if previous?.fill != value.fill { shape.fillColor = SKColor(value.fill) }
        if previous?.stroke != value.stroke { shape.strokeColor = SKColor(value.stroke) }
        if previous?.lineWidth != value.lineWidth { shape.lineWidth = drawingSize(value.lineWidth) }
        if previous?.glowWidth != value.glowWidth { shape.glowWidth = drawingSize(value.glowWidth) }
        if previous?.lineCap != value.lineCap { shape.lineCap = value.lineCap.native }
        if previous?.lineJoin != value.lineJoin { shape.lineJoin = value.lineJoin.native }
        if previous?.miterLimit != value.miterLimit { shape.miterLimit = max(1, drawingSize(value.miterLimit)) }
        if previous?.isAntialiased != value.isAntialiased { shape.isAntialiased = value.isAntialiased }
        if previous?.blendMode != value.blendMode { shape.blendMode = value.blendMode.native }
        if previous?.opacity != value.opacity {
            let animator = existing == nil ? Animator(renderer: animator.renderer, entityID: animator.entityID, transaction: nil) : animator
            animateDrawingOpacity(value.opacity, on: shape, key: "shape.opacity", animator: animator)
        }
    }, present: { node, model in
        var value = model
        if let shape = node.childNode(withName: shapeNodeName) as? SKShapeNode { value.opacity = Float(shape.alpha) }
        return value
    })

    /// Highest local visual layer hit. A mixed sprite/text/shape entity is returned
    /// once. Explicit colliders and ancestor suppression are handled by the caller.
    func drawingHitZ(at point: CGPoint, on node: SKNode) -> CGFloat? {
        var hits: [CGFloat] = []
        if let sprite = node.childNode(withName: Self.spriteNodeName) as? SKSpriteNode, !sprite.isHidden, sprite.alpha > 0 {
            let bounds = CGRect(x: -sprite.size.width * sprite.anchorPoint.x, y: -sprite.size.height * sprite.anchorPoint.y,
                                width: sprite.size.width, height: sprite.size.height)
            if bounds.contains(sprite.convert(point, from: self)) { hits.append(sprite.zPosition) }
        }
        if let label = node.childNode(withName: Self.textNodeName) as? SKLabelNode, !label.isHidden, label.alpha > 0,
           label.fontSize > 0, label.fontColor?.cgColor.alpha ?? 0 > 0, (label.attributedText?.string ?? label.text ?? "").isEmpty == false,
           label.frame.contains(node.convert(point, from: self)) { hits.append(label.zPosition) }
        if let shape = node.childNode(withName: Self.shapeNodeName) as? SKShapeNode, !shape.isHidden, shape.alpha > 0, let path = shape.path {
            let local = shape.convert(point, from: self)
            let fill = shape.fillColor.cgColor.alpha > 0 && path.contains(local)
            let stroke = shape.lineWidth > 0 && shape.strokeColor.cgColor.alpha > 0 && path.copy(strokingWithWidth: shape.lineWidth,
                lineCap: shape.lineCap, lineJoin: shape.lineJoin, miterLimit: shape.miterLimit).contains(local)
            if fill || stroke { hits.append(shape.zPosition) }
        }
        return hits.max()
    }
}
