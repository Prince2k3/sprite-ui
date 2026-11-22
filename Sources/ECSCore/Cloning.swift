/// A two-pass reference update after all destination entities exist. Internal
/// references map to copies; IDs outside the copied/restored set stay external.
@MainActor
public struct EntityReferenceRemapping {
    public enum Operation: Equatable, Sendable { case clone, restore }
    public let operation: Operation
    /// The copied root, or nil when restoring an entire world.
    public let root: Entity?
    let destinations: [Entity.ID: Entity]
    let names: [(Entity.ID, String)]
    let transforms: [Entity.ID: AffineTransform2D]
    let sourceRootID: Entity.ID?

    /// The destination of a source entity, or nil for an external reference.
    public func entity(for sourceID: Entity.ID) -> Entity? { destinations[sourceID] }
    /// The destination ID, preserving external references unchanged.
    public func id(for sourceID: Entity.ID) -> Entity.ID { destinations[sourceID]?.id ?? sourceID }
    /// The first copied entity with this source name, in hierarchy order.
    public func entity(named name: String) -> Entity? {
        names.first(where: { $0.1 == name }).flatMap { destinations[$0.0] }
    }
    /// A source pose captured before copying, used to relocate saved coordinate frames.
    public func sourceTransform(for sourceID: Entity.ID) -> AffineTransform2D? { transforms[sourceID] }
    /// The original root's scene-space pose, when copying a hierarchy.
    public var sourceRootTransform: AffineTransform2D? { sourceRootID.flatMap { transforms[$0] } }
}

/// Adopt on components that store entity references. Called after cloning and
/// snapshot restoration, before anything is attached to a world. Remap only
/// entity IDs/references, not unrelated numeric values.
public protocol EntityReferencingComponent: Component {
    @MainActor mutating func remapEntityReferences(_ context: EntityReferenceRemapping)
}

extension Entity {
    /// Returns a detached copy with fresh IDs. Recursive copies preserve child
    /// order and remap references within the copied subtree. Nonrecursive copies
    /// leave child references external. Names and local transforms are retained.
    /// Components use `cloned()`; custom reference storage must implement that
    /// hook for deep copying. Actions, subscriptions and playback aren't copied.
    /// Dynamic entity types use their required initializer; subclass properties
    /// outside components retain initializer defaults.
    /// - Complexity: O(entities + components + ancestor depth), plus custom copy/remapping hooks.
    public func clone(recursive: Bool = true) -> Self {
        var sources: [Entity] = [], sourceTransforms: [Entity.ID: AffineTransform2D] = [:]
        func collect(_ entity: Entity, pose: AffineTransform2D) {
            sources.append(entity); sourceTransforms[entity.id] = pose
            if recursive { for child in entity.children { collect(child, pose: pose * child.transform.matrix) } }
        }
        collect(self, pose: sceneTransformMatrix)
        let copies = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, type(of: $0).init()) })
        for source in sources {
            let copy = copies[source.id]!
            for child in copy.children { child.removeFromParent() }
            copy.name = source.name
            copy.isEnabled = source.isEnabled
            copy.storage = source.storage.compactMapValues { $0.cloned() }
        }
        if recursive {
            for source in sources {
                for child in source.children { copies[source.id]!.addChild(copies[child.id]!) }
            }
        }
        let root = copies[id]!
        let context = EntityReferenceRemapping(operation: .clone, root: root, destinations: copies,
            names: sources.map { ($0.id, $0.name) }, transforms: sourceTransforms, sourceRootID: id)
        remapComponents(in: sources.map { copies[$0.id]! }, using: context)
        return root as! Self // Each destination was created with its source's dynamic type.
    }
}

@MainActor
func remapComponents(in entities: [Entity], using context: EntityReferenceRemapping) {
    for entity in entities {
        for (key, component) in entity.storage {
            if var referencing = component as? any EntityReferencingComponent {
                referencing.remapEntityReferences(context)
                entity.storage[key] = referencing
            }
        }
    }
}
