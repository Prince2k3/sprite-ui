import Foundation

/// Per-frame logic that runs over entities.
///
/// ```swift
/// struct SpinSystem: System {
///     static let query = EntityQuery(where: .has(Spin.self))
///     init(world: World) {}
///     func update(context: UpdateContext) {
///         for entity in context.entities(matching: Self.query) {
///             let speed = entity.components[Spin.self]!.speed
///             entity.transform.rotation += speed * Float(context.deltaTime)
///         }
///     }
/// }
///
/// SpinSystem.registerSystem()   // every new World gets one
/// ```
@MainActor
public protocol System {
    init(world: World)
    mutating func update(context: UpdateContext)
}

extension System {
    /// Registers this system type so every ``World`` created afterward runs it.
    public static func registerSystem() {
        SystemRegistry.register(Self.self)
    }
}

@MainActor
enum SystemRegistry {
    private(set) static var types: [any System.Type] = []

    static func register(_ type: any System.Type) {
        guard !types.contains(where: { $0 == type }) else { return }
        types.append(type)
    }
}

/// What a system gets each frame.
@MainActor
public struct UpdateContext {
    public let world: World
    /// Seconds since the previous frame.
    public let deltaTime: TimeInterval

    public func entities(matching query: EntityQuery) -> [Entity] {
        world.performQuery(query)
    }
}
