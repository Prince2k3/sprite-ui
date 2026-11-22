import ECSCore
import SpriteKit

extension SpriteRenderer {
    /// Entities whose sprite contains a point in scene coordinates, front-most first.
    ///
    /// Uses what's on screen, so an entity mid-animation is hit where it's drawn.
    /// Rotation and scale are respected; transparent pixels are not ignored.
    public func entities(at scenePoint: CGPoint) -> [Entity] {
        var hits: [(entity: Entity, z: CGFloat, order: Int)] = []
        var order = 0
        func visit(_ entity: Entity, parentZ: CGFloat) {
            guard let node = node(for: entity) else { return }
            let z = parentZ + node.zPosition
            if !node.isHidden,
               let sprite = node.childNode(withName: Self.spriteNodeName) as? SKSpriteNode,
               sprite.alpha > 0 {
                let local = sprite.convert(scenePoint, from: self)
                let bounds = CGRect(
                    x: -sprite.size.width * sprite.anchorPoint.x,
                    y: -sprite.size.height * sprite.anchorPoint.y,
                    width: sprite.size.width,
                    height: sprite.size.height
                )
                if bounds.contains(local) {
                    hits.append((entity, z + sprite.zPosition, order))
                }
            }
            order += 1
            guard !node.isHidden else { return }
            for child in entity.children { visit(child, parentZ: z) }
        }
        for entity in world.entities { visit(entity, parentZ: 0) }

        // Higher z draws on top; among equal z, later in the tree draws on top.
        return hits
            .sorted { ($0.z, $0.order) > ($1.z, $1.order) }
            .map(\.entity)
    }

    /// The front-most entity at a scene point that accepts targeted input.
    public func inputTarget(at scenePoint: CGPoint) -> Entity? {
        entities(at: scenePoint).first { $0.isInputTarget }
    }
}
