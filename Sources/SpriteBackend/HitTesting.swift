import ECSCore
import SpriteKit

extension SpriteRenderer {
    /// Entities hit by a displayed point, front-most first. Explicit collision
    /// shapes can be invisible; physics shapes are used when no collider is set.
    /// Sprite bounds remain a compatibility fallback for hierarchies without a
    /// collider. A collider on an ancestor suppresses implicit child sprite bounds,
    /// while children with their own colliders remain independent targets.
    /// Uses displayed transforms, including camera-independent animation poses.
    public func entities(at scenePoint: CGPoint, filter: CollisionQueryFilter = .init()) -> [Entity] {
        var hits: [(entity: Entity, z: CGFloat, order: Int)] = []
        var order = 0
        func visit(_ entity: Entity, parentZ: CGFloat, hasColliderAncestor: Bool) {
            guard let node = node(for: entity), !node.isHidden else { return }
            let z = parentZ + node.zPosition
            let collider = entity.queryCollider
            if let collider {
                if collider.isEnabled, filter.includes(entity, filter: collider.filter) {
                    let matrix = displayedCollisionMatrix(for: node) * AffineTransform2D(tx: collider.offset.x, ty: collider.offset.y)
                    let geometry = collisionGeometry(shape: collider.shape, matrix: matrix)
                    if CollisionGeometry.contains([Float(scenePoint.x), Float(scenePoint.y)], in: geometry) {
                        hits.append((entity, z, order))
                    }
                }
            } else if !hasColliderAncestor, filter.includes(entity, filter: .init()),
                      let sprite = node.childNode(withName: Self.spriteNodeName) as? SKSpriteNode, sprite.alpha > 0 {
                let local = sprite.convert(scenePoint, from: self)
                let bounds = CGRect(x: -sprite.size.width * sprite.anchorPoint.x, y: -sprite.size.height * sprite.anchorPoint.y,
                                    width: sprite.size.width, height: sprite.size.height)
                if bounds.contains(local) { hits.append((entity, z + sprite.zPosition, order)) }
            }
            order += 1
            for child in entity.children { visit(child, parentZ: z, hasColliderAncestor: hasColliderAncestor || collider != nil) }
        }
        if node(for: world.root)?.isHidden != true {
            for entity in world.entities { visit(entity, parentZ: 0, hasColliderAncestor: false) }
        }
        return hits.sorted { ($0.z, $0.order) > ($1.z, $1.order) }.map(\.entity)
    }

    /// The front-most hit entity with an enabled InputTargetComponent on itself
    /// or an ancestor. Collision and query filters are independent of rendering.
    public func inputTarget(at scenePoint: CGPoint, filter: CollisionQueryFilter = .init()) -> Entity? {
        entities(at: scenePoint, filter: filter).first { $0.isInputTarget }
    }
}
