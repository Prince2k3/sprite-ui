/// A piece of data attached to an ``Entity``.
///
/// Components are plain value types. Mutate them through the entity and the
/// change is recorded so backends can pick it up:
///
/// ```swift
/// struct Health: Component { var hp: Int }
///
/// entity.components.set(Health(hp: 3))
/// entity.components[Health.self]?.hp -= 1
/// ```
public protocol Component {
    /// Copies this component for a clone or snapshot instance. The default copies by value.
    /// Override to deep-copy mutable reference storage, or return nil to exclude
    /// runtime state. Immutable resources may safely remain shared.
    @MainActor func cloned() -> Self?
}

extension Component {
    public func cloned() -> Self? { self }
}

extension Component {
    @inlinable
    static var componentID: ObjectIdentifier { ObjectIdentifier(Self.self) }
}

/// A view onto an entity's components. Reads and writes go straight to the entity.
@MainActor
public struct ComponentSet {
    @usableFromInline
    let entity: Entity

    init(entity: Entity) {
        self.entity = entity
    }

    /// Gets or sets the component of the given type. Setting `nil` removes it.
    public subscript<T: Component>(_ type: T.Type) -> T? {
        get { entity.storage[ObjectIdentifier(type)] as? T }
        nonmutating set {
            if let newValue {
                entity.setComponent(newValue)
            } else {
                entity.removeComponent(type)
            }
        }
    }

    /// Adds or replaces a component.
    public func set<T: Component>(_ component: T) {
        entity.setComponent(component)
    }

    /// Adds or replaces several components at once.
    public func set(_ components: [any Component]) {
        for component in components {
            entity.setComponent(component)
        }
    }

    public func has<T: Component>(_ type: T.Type) -> Bool {
        entity.storage[ObjectIdentifier(type)] != nil
    }

    public func has(_ type: any Component.Type) -> Bool {
        entity.storage[ObjectIdentifier(type)] != nil
    }

    public func remove<T: Component>(_ type: T.Type) {
        entity.removeComponent(type)
    }

    public var count: Int { entity.storage.count }
}
