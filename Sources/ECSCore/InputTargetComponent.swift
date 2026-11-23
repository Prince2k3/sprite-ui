/// Lets an entity, and everything under it, receive targeted gestures such as
/// `SpatialTapGesture().targetedToAnyEntity()`.
///
/// Like RealityKit, the component applies to the whole subtree: put it on a parent and
/// its children become targets too. A descendant with its own component overrides it,
/// so `InputTargetComponent(isEnabled: false)` opts a child out.
///
/// The backend uses explicit collision shapes, then physics shapes. Sprite bounds
/// remain a compatibility fallback for hierarchies without a collider.
///
/// Add ``ManipulationComponent`` to opt a pickable entity into GameView's automatic
/// dragging, rotation, and scaling. Pickability alone never changes its transform.
///
/// This component controls entity-targeted gestures, independently of game actions
/// resolved by ``InputController``. It is not required for keyboard, controller,
/// or virtual action bindings. Disabling a target does not disable a player's
/// movement or firing actions; use action contexts or the controller's enablement
/// for that policy. A host's focus or inspection cancellation clears both paths.
public struct InputTargetComponent: Component, Equatable, Sendable, Codable {
    public var isEnabled: Bool

    public init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }
}

extension Entity {
    /// Whether targeted gestures can hit this entity: the nearest
    /// ``InputTargetComponent`` on it or an ancestor is enabled.
    public var isInputTarget: Bool {
        guard isEnabledInHierarchy else { return false }
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
