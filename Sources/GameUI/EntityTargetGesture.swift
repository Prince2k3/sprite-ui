import ECSCore
import SpriteBackend
import SpriteKit
import SwiftUI

// Targeted gestures, in the style of RealityKit:
//
//     GameView { ... }
//         .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { value in
//             value.entity.removeFromParent()
//         })
//
// The entity under the finger is picked when the touch goes down, from entities with
// an enabled `InputTargetComponent` (on themselves or an ancestor). A touch that starts
// on no target doesn't call `onChanged` or `onEnded`.
//
// Attach these gestures to the `GameView` itself: locations are read in its local space.

extension Gesture {
    /// Fires only for touches that start on an entity that accepts input.
    public func targetedToAnyEntity() -> EntityTargetGesture<Self> {
        EntityTargetGesture(base: self) { $0 }
    }

    /// Fires only for touches that start on `entity` or one of its descendants.
    /// `value.entity` is always `entity`.
    public func targetedToEntity(_ entity: Entity) -> EntityTargetGesture<Self> {
        EntityTargetGesture(base: self) { [weak entity] hit in
            guard let entity, hit === entity || hit.isDescendant(of: entity) else { return nil }
            return entity
        }
    }

    /// Fires only for touches that start on an entity matching `predicate`, or on a
    /// descendant of one. `value.entity` is the nearest match.
    public func targetedToEntity(where predicate: QueryPredicate<Entity>) -> EntityTargetGesture<Self> {
        EntityTargetGesture(base: self) { hit in
            var current: Entity? = hit
            while let entity = current {
                if predicate.matches(entity) { return entity }
                current = entity.parent
            }
            return nil
        }
    }
}

/// A gesture that only fires on entities. Make one with ``SwiftUICore/Gesture/targetedToAnyEntity()``.
///
/// Use its own `onChanged` and `onEnded`, which hand you an ``EntityTargetValue``.
public struct EntityTargetGesture<Base: Gesture>: Gesture {
    /// `nil` while the touch didn't start on a matching entity.
    /// The `onChanged`/`onEnded` overloads below filter those out.
    public typealias Value = EntityTargetValue<Base.Value>?

    let base: Base
    let resolve: @MainActor (Entity) -> Entity?

    public var body: some Gesture<Value> {
        base.map { value in
            MainActor.assumeIsolated {
                guard let touch = GameHost.touchTarget,
                      let host = touch.host,
                      let hit = touch.entity,
                      hit.world === host.world,
                      let entity = resolve(hit)
                else { return nil }
                return EntityTargetValue(entity: entity, gestureValue: value, host: host)
            }
        }
    }

    /// Runs `action` when the gesture ends on a targeted entity.
    public func onEnded(
        _ action: @escaping (EntityTargetValue<Base.Value>) -> Void
    ) -> _EndedGesture<Self> {
        let filtered: (Value) -> Void = { value in
            if let value { action(value) }
        }
        return onEnded(filtered)
    }
}

extension EntityTargetGesture where Base.Value: Equatable {
    /// Runs `action` each time the gesture's value changes on a targeted entity.
    public func onChanged(
        _ action: @escaping (EntityTargetValue<Base.Value>) -> Void
    ) -> _ChangedGesture<Self> {
        let filtered: (Value) -> Void = { value in
            if let value { action(value) }
        }
        return onChanged(filtered)
    }
}

extension _ChangedGesture {
    /// Lets `.onChanged { }.onEnded { }` chains on targeted gestures get a non-optional value.
    public func onEnded<Base: Gesture>(
        _ action: @escaping (EntityTargetValue<Base.Value>) -> Void
    ) -> _EndedGesture<Self> where Content == EntityTargetGesture<Base> {
        let filtered: (Value) -> Void = { value in
            if let value { action(value) }
        }
        return onEnded(filtered)
    }
}

/// The value of a targeted gesture: the entity it hit plus the underlying gesture's value.
///
/// Members of the underlying value are available directly, so `value.location` and
/// `value.translation` work as they do on the original gesture.
@MainActor
@dynamicMemberLookup
public struct EntityTargetValue<Value> {
    /// The entity the gesture targets.
    public let entity: Entity
    /// The underlying gesture's value.
    public let gestureValue: Value

    weak var host: GameHost?

    public subscript<T>(dynamicMember keyPath: KeyPath<Value, T>) -> T {
        gestureValue[keyPath: keyPath]
    }

    /// Converts a point in the `GameView`'s local space (such as `value.location`)
    /// to scene coordinates.
    public func convert(_ point: CGPoint, to space: GameCoordinateSpace) -> SIMD2<Float> {
        guard let renderer = host?.renderer else { return .zero }
        let scenePoint = renderer.convertPoint(fromView: point)
        return SIMD2(Float(scenePoint.x), Float(scenePoint.y))
    }

    /// Converts a point in the `GameView`'s local space to `entity`'s coordinate space,
    /// the space its children's positions are in.
    public func convert(_ point: CGPoint, to entity: Entity) -> SIMD2<Float> {
        guard let renderer = host?.renderer else { return .zero }
        // The world's root has no node of its own: its children sit in the scene.
        let node: SKNode? = entity === renderer.world.root ? renderer : renderer.node(for: entity)
        guard let node else { return .zero }
        let local = node.convert(renderer.convertPoint(fromView: point), from: renderer)
        return SIMD2(Float(local.x), Float(local.y))
    }
}

extension EntityTargetValue: Equatable where Value: Equatable {
    public nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated {
            lhs.entity === rhs.entity && lhs.gestureValue == rhs.gestureValue
        }
    }
}

/// A coordinate space in the game world, for ``EntityTargetValue/convert(_:to:)-(_,GameCoordinateSpace)``.
public struct GameCoordinateSpace: Sendable {
    /// The scene's space: the same space as top-level entities' positions.
    public static let scene = GameCoordinateSpace()
}
