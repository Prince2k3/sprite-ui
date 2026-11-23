import ECSCore
import SpriteKit

extension SpriteRenderer {
    /// Entities hit by a displayed point, front-most first. Explicit collision
    /// shapes can be invisible; physics shapes are used when no collider is set.
    /// Sprite/text bounds and drawn shape paths are a visual fallback without a
    /// collider. A collider on an ancestor suppresses implicit child visual hits,
    /// while children with their own colliders remain independent targets.
    /// Uses displayed transforms, including camera-independent animation poses.
    public func entities(at scenePoint: CGPoint, filter: CollisionQueryFilter = .init()) -> [Entity] {
        struct Layer { let z: CGFloat; let order: Int }
        var hits: [(entity: Entity, layers: [Layer])] = []
        var order = 0
        func visit(_ entity: Entity, parentZ: CGFloat, groups: [Layer], hasColliderAncestor: Bool) {
            guard entity.isActive, let node = node(for: entity), !node.isHidden else { return }
            let z = parentZ + node.zPosition
            // A composited subtree is atomic relative to sibling layers. Child z
            // values only affect ordering inside that subtree, even for colliders.
            let grouped = (node as? SKEffectNode)?.shouldEnableEffects == true
            let scope = grouped ? groups + [Layer(z: z, order: order)] : groups
            let localZ = grouped ? 0 : z
            let collider = entity.queryCollider
            if let collider {
                if collider.isEnabled, filter.includes(entity, filter: collider.filter) {
                    let matrix = displayedCollisionMatrix(for: node) * AffineTransform2D(tx: collider.offset.x, ty: collider.offset.y)
                    let geometry = collisionGeometry(shape: collider.shape, matrix: matrix)
                    if CollisionGeometry.contains([Float(scenePoint.x), Float(scenePoint.y)], in: geometry) {
                        hits.append((entity, scope + [Layer(z: localZ, order: order)]))
                    }
                }
            } else if !hasColliderAncestor, filter.includes(entity, filter: .init()),
                      let visualZ = drawingHitZ(at: scenePoint, on: node) {
                hits.append((entity, scope + [Layer(z: localZ + visualZ, order: order)]))
            }
            order += 1
            for child in entity.children { visit(child, parentZ: localZ, groups: scope, hasColliderAncestor: hasColliderAncestor || collider != nil) }
        }
        if node(for: world.root)?.isHidden != true {
            for entity in world.entities { visit(entity, parentZ: 0, groups: [], hasColliderAncestor: false) }
        }
        return hits.sorted { a, b in
            for (left, right) in zip(a.layers, b.layers) {
                if left.z != right.z { return left.z > right.z }
                if left.order != right.order { return left.order > right.order }
            }
            return a.layers.count > b.layers.count
        }.map(\.entity)
    }

    /// The front-most hit entity with an enabled InputTargetComponent on itself
    /// or an ancestor. Collision and query filters are independent of rendering.
    public func inputTarget(at scenePoint: CGPoint, filter: CollisionQueryFilter = .init()) -> Entity? {
        entities(at: scenePoint, filter: filter).first { $0.isInputTarget }
    }
}
