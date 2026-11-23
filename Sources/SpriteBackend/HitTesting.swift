import ECSCore
import SpriteKit

extension SpriteRenderer {
    /// Entities hit by a displayed point, front-most first. Explicit collision
    /// shapes can be invisible; physics shapes are used when no collider is set.
    /// Sprite/text bounds and drawn shape paths are a visual fallback without a
    /// collider. A collider on an ancestor suppresses implicit child visual hits,
    /// while children with their own colliders remain independent targets.
    /// Uses displayed transforms, including camera-independent animation poses.
    /// Every enabled ancestor mask clips input, including explicit colliders;
    /// model-space physics queries remain independent of visual masks.
    public func entities(at scenePoint: CGPoint, filter: CollisionQueryFilter = .init()) -> [Entity] {
        displayedEntities(at: scenePoint, filter: filter, inspectingVisuals: false)
    }

    /// Inspection sees visible children independently of gameplay collider
    /// ownership. It still obeys activation, displayed masks and draw ordering.
    func inspectedEntities(at scenePoint: CGPoint) -> [Entity] {
        displayedEntities(at: scenePoint, filter: .init(), inspectingVisuals: true)
    }

    private func displayedEntities(at scenePoint: CGPoint, filter: CollisionQueryFilter, inspectingVisuals: Bool) -> [Entity] {
        struct Layer { let z: CGFloat; let order: Int }
        var hits: [(entity: Entity, layers: [Layer])] = []
        var order = 0
        func visit(_ entity: Entity, parentZ: CGFloat, groups: [Layer], hasColliderAncestor: Bool) {
            guard entity.isActive, let node = node(for: entity), !node.isHidden, maskAllows(scenePoint, node: node) else { return }
            let z = parentZ + node.zPosition
            // A composited subtree is atomic relative to sibling layers. Child z
            // values only affect ordering inside that subtree, even for colliders.
            let grouped = (node as? SKEffectNode)?.shouldEnableEffects == true
                || (Self.contentRoot(node) as? MaskCropNode)?.maskNode != nil
            let scope = grouped ? groups + [Layer(z: z, order: order)] : groups
            let localZ = grouped ? 0 : z
            let collider = entity.queryCollider
            var colliderHit = false
            if let collider {
                if collider.isEnabled, filter.includes(entity, filter: collider.filter) {
                    let matrix = displayedCollisionMatrix(for: node) * AffineTransform2D(tx: collider.offset.x, ty: collider.offset.y)
                    let geometry = collisionGeometry(shape: collider.shape, matrix: matrix)
                    if CollisionGeometry.contains([Float(scenePoint.x), Float(scenePoint.y)], in: geometry) {
                        hits.append((entity, scope + [Layer(z: localZ, order: order)]))
                        colliderHit = true
                    }
                }
            }
            if !colliderHit, (inspectingVisuals || (collider == nil && !hasColliderAncestor)), filter.includes(entity, filter: .init()),
                      let visualZ = drawingHitZ(at: scenePoint, on: Self.contentRoot(node)) {
                hits.append((entity, scope + [Layer(z: localZ + visualZ, order: order)]))
            }
            order += 1
            for child in entity.children { visit(child, parentZ: localZ, groups: scope, hasColliderAncestor: hasColliderAncestor || collider != nil) }
        }
        if let root = node(for: world.root), !root.isHidden, maskAllows(scenePoint, node: root) {
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
