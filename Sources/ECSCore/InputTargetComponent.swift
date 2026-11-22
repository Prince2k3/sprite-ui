/// Lets an entity, and everything under it, receive targeted gestures such as
/// `SpatialTapGesture().targetedToAnyEntity()`.
///
/// Like RealityKit, the component applies to the whole subtree: put it on a parent and
/// its children become targets too. A descendant with its own component overrides it,
/// so `InputTargetComponent(isEnabled: false)` opts a child out.
///
/// The shape that's hit-tested is the entity's sprite.
public struct InputTargetComponent: Component, Equatable, Sendable {
    public var isEnabled: Bool

    public init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }
}

extension Entity {
    /// Whether targeted gestures can hit this entity: the nearest
    /// ``InputTargetComponent`` on it or an ancestor is enabled.
    public var isInputTarget: Bool {
        var current: Entity? = self
        while let entity = current {
            if let target = entity.components[InputTargetComponent.self] {
                return target.isEnabled
            }
            current = entity.parent
        }
        return false
    }
}
