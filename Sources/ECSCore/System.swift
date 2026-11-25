import Foundation

/// Opt-in fixed ticks precede per-frame simulation and backend physics;
/// presentation runs afterward. Headless `World.update` preserves this order
/// without stepping a native physics backend.
public enum SystemPhase: Int, CaseIterable, Codable, Sendable, Comparable {
    case fixedSimulation = -1
    case simulation = 0
    case presentation = 1
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// An ordering constraint. A dependency does not install its target system;
/// constraints become effective when both systems are installed in the world.
public enum SystemDependency {
    case before(any System.Type)
    case after(any System.Type)
}

/// A rejected system installation. The previous schedule remains intact.
public enum SystemSchedulingError: Error, Equatable, Sendable {
    case cycle([String])
    case conflictingPhases(system: String, dependency: String)
}

/// Query-driven game logic. Dependencies order systems within a phase; all
/// simulation systems precede all presentation systems.
@MainActor
public protocol System {
    init(world: World)
    static var phase: SystemPhase { get }
    static var dependencies: [SystemDependency] { get }
    mutating func update(context: UpdateContext)
}

extension System {
    public static var phase: SystemPhase { .simulation }
    public static var dependencies: [SystemDependency] { [] }

    /// Registers a system for worlds created afterward. Per-world installation is
    /// also available through `try world.systems.add(MySystem.self)`.
    public static func registerSystem() { SystemRegistry.register(Self.self) }
}

@MainActor
enum SystemRegistry {
    private(set) static var types: [any System.Type] = []
    static func register(_ type: any System.Type) {
        guard !types.contains(where: { $0 == type }) else { return }
        types.append(type)
    }
}

@MainActor
final class SystemEntry {
    let type: any System.Type
    var instance: any System
    var isEnabled = true
    init(_ type: any System.Type, world: World) { self.type = type; instance = type.init(world: world) }
    var id: ObjectIdentifier { ObjectIdentifier(type) }
}

/// A safe view onto a world's installed systems. Keeping this value keeps the
/// world alive. Mutations during a frame affect additions on the next frame;
/// removing or disabling a not-yet-run system takes effect immediately.
@MainActor
public struct SystemCollection {
    let world: World

    /// Installed system types in resolved execution order.
    public var types: [any System.Type] { world.scheduledSystems.map(\.type) }

    /// Installs a system once. Throws for cycles or constraints that contradict
    /// phase order, without modifying the existing schedule.
    public func add<S: System>(_ type: S.Type) throws { try world.installSystem(type) }

    public func contains<S: System>(_ type: S.Type) -> Bool { world.systemEntry(type) != nil }
    public func remove<S: System>(_ type: S.Type) { world.uninstallSystem(type) }
    public func isEnabled<S: System>(_ type: S.Type) -> Bool? { world.systemEntry(type)?.isEnabled }
    public func setEnabled<S: System>(_ enabled: Bool, for type: S.Type) { world.systemEntry(type)?.isEnabled = enabled }
}

/// Input to one system update. `deltaTime` is scaled scene time;
/// `unscaledDeltaTime` is the caller's elapsed time before the scene time scale.
@MainActor
public struct UpdateContext {
    public let world: World
    public var scene: World { world }
    public let deltaTime: TimeInterval
    public let unscaledDeltaTime: TimeInterval
    public let phase: SystemPhase
    public let fixedTick: UInt64?
    public let interpolationAlpha: Double

    public init(world: World, deltaTime: TimeInterval, unscaledDeltaTime: TimeInterval,
                phase: SystemPhase, fixedTick: UInt64? = nil, interpolationAlpha: Double = 0) {
        self.world = world
        self.deltaTime = deltaTime
        self.unscaledDeltaTime = unscaledDeltaTime
        self.phase = phase
        self.fixedTick = fixedTick
        self.interpolationAlpha = interpolationAlpha
    }

    public func entities(matching query: EntityQuery) -> [Entity] { world.performQuery(query) }
}

@MainActor
enum SystemSchedule {
    static func ordered(_ types: [any System.Type]) throws -> [any System.Type] {
        let ids = types.map(ObjectIdentifier.init)
        let positions = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        var edges = [ObjectIdentifier: Set<ObjectIdentifier>]()
        var indegrees = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0) })
        for type in types {
            for dependency in type.dependencies {
                let before: any System.Type
                let after: any System.Type
                switch dependency {
                case .before(let target): before = type; after = target
                case .after(let target): before = target; after = type
                }
                let a = ObjectIdentifier(before), b = ObjectIdentifier(after)
                guard positions[a] != nil, positions[b] != nil else { continue }
                guard before.phase <= after.phase else {
                    throw SystemSchedulingError.conflictingPhases(system: String(reflecting: type), dependency: String(reflecting: before.phase > after.phase ? before : after))
                }
                if edges[a, default: []].insert(b).inserted { indegrees[b, default: 0] += 1 }
            }
        }
        // Phase edges make ordering independent of installation order too.
        for first in types {
            for second in types where first.phase < second.phase {
                let a = ObjectIdentifier(first), b = ObjectIdentifier(second)
                if edges[a, default: []].insert(b).inserted { indegrees[b, default: 0] += 1 }
            }
        }
        var result: [any System.Type] = []
        var remaining = Set(ids)
        while !remaining.isEmpty {
            guard let next = ids.first(where: { remaining.contains($0) && indegrees[$0] == 0 }),
                  let position = positions[next] else {
                throw SystemSchedulingError.cycle(types.filter { remaining.contains(ObjectIdentifier($0)) }.map { String(reflecting: $0) })
            }
            remaining.remove(next); result.append(types[position])
            for target in edges[next, default: []] { indegrees[target, default: 0] -= 1 }
        }
        return result
    }
}
