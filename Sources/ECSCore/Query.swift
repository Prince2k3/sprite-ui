/// A condition used to select entities, combinable with `&&`, `||` and `!`.
///
/// ```swift
/// EntityQuery(where: .has(Health.self) && !.has(Dead.self))
/// ```
public struct QueryPredicate<Value>: Sendable {
    let evaluate: @MainActor @Sendable (Value) -> Bool

    public init(_ evaluate: @escaping @MainActor @Sendable (Value) -> Bool) {
        self.evaluate = evaluate
    }

    /// Whether `value` satisfies the predicate.
    @MainActor
    public func matches(_ value: Value) -> Bool { evaluate(value) }

    public static func && (lhs: Self, rhs: Self) -> Self {
        Self { lhs.evaluate($0) && rhs.evaluate($0) }
    }

    public static func || (lhs: Self, rhs: Self) -> Self {
        Self { lhs.evaluate($0) || rhs.evaluate($0) }
    }

    public static prefix func ! (predicate: Self) -> Self {
        Self { !predicate.evaluate($0) }
    }
}

extension QueryPredicate where Value == Entity {
    public static func has<T: Component>(_ type: T.Type) -> Self {
        let key = ObjectIdentifier(type)
        return Self { $0.storage[key] != nil }
    }

    public static var all: Self { Self { _ in true } }
}

/// Selects the entities in a world that match a predicate.
public struct EntityQuery: Sendable {
    public let predicate: QueryPredicate<Entity>

    public init(where predicate: QueryPredicate<Entity> = .all) {
        self.predicate = predicate
    }
}
