import Foundation

/// Something a world can publish and others can subscribe to.
public protocol Event {}

/// Keeps an event handler alive. The handler stops when this is cancelled or deallocated,
/// so store it somewhere (for example in a `[EventSubscription]` array).
@MainActor
public final class EventSubscription {
    fileprivate var isCancelled = false

    public func cancel() { isCancelled = true }
}

public enum WorldEvents {
    public struct DidChangeEntityActivation: Event {
        public let entity: Entity
        public let isEnabledInHierarchy: Bool
    }
    /// Scene simulation settings changed, including while paused.
    public struct SimulationDidChange: Event { public let world: World }

    /// Published once per frame, before systems run.
    public struct Update: Event {
        public let world: World
        public let deltaTime: TimeInterval
    }

    public struct DidAddEntity: Event {
        public let entity: Entity
    }

    public struct WillRemoveEntity: Event {
        public let entity: Entity
    }
}

public enum ComponentEvents {
    public struct DidAdd: Event {
        public let entity: Entity
        public let componentType: any Component.Type
    }

    public struct WillRemove: Event {
        public let entity: Entity
        public let componentType: any Component.Type
    }
}

@MainActor
struct EventBus {
    private struct Handler {
        weak var token: EventSubscription?
        let entityID: Entity.ID?
        let call: @MainActor (any Event) -> Void
    }

    private var handlers: [ObjectIdentifier: [Handler]] = [:]

    mutating func subscribe<E: Event>(
        to type: E.Type,
        on entity: Entity?,
        _ handler: @escaping @MainActor (E) -> Void
    ) -> EventSubscription {
        let token = EventSubscription()
        let entry = Handler(token: token, entityID: entity?.id) { event in
            if let event = event as? E { handler(event) }
        }
        handlers[ObjectIdentifier(type), default: []].append(entry)
        return token
    }

    /// The handlers for an event, pruning cancelled ones.
    ///
    /// The caller runs them after this returns, so a handler can publish, subscribe, or
    /// add and remove entities without re-entering the bus while it's being mutated.
    mutating func handlers<E: Event>(
        for type: E.Type,
        sources: [Entity]
    ) -> [@MainActor (any Event) -> Void] {
        let key = ObjectIdentifier(type)
        guard var list = handlers[key] else { return [] }
        list.removeAll { $0.token == nil || $0.token!.isCancelled }
        handlers[key] = list
        return list
            .filter { handler in handler.entityID.map { id in sources.contains { $0.id == id } } ?? true }
            .map(\.call)
    }
}
