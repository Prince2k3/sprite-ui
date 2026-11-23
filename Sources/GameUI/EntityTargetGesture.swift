import ECSCore
import SpriteBackend
import SpriteKit
import SwiftUI

extension Gesture {
    /// Targets the entity under this gesture's starting pointer. Attach to a
    /// GameView or a wrapper containing exactly one GameView.
    public func targetedToAnyEntity() -> EntityTargetGesture<Self> { EntityTargetGesture(base: self) { $0 } }

    /// Targets this entity when the pointer starts on it or an enabled descendant.
    public func targetedToEntity(_ entity: Entity) -> EntityTargetGesture<Self> {
        EntityTargetGesture(base: self) { [weak entity] hit in
            guard let entity, hit === entity || hit.isDescendant(of: entity) else { return nil }
            return entity
        }
    }

    /// Targets the nearest matching ancestor of the entity under the pointer.
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

/// A view-scoped targeted gesture. Its handlers keep a stable capture for their
/// own pointer, rather than looking up a process-wide last touch. Tap and drag
/// values identify their starting location. Gestures without a starting location
/// are delivered only when a single contact is unambiguous.
public struct EntityTargetGesture<Base: Gesture>: Gesture {
    public typealias Value = EntityTargetValue<Base.Value>?
    let base: Base
    let resolve: @MainActor (Entity) -> Entity?
    var changed: [@MainActor (EntityTargetValue<Base.Value>) -> Void] = []
    var ended: [@MainActor (EntityTargetValue<Base.Value>) -> Void] = []
    var equals: ((Base.Value, Base.Value) -> Bool)?

    /// View's targeted-gesture overloads bind this value to their GameView.
    /// An unbound gesture intentionally produces no entity events.
    public var body: some Gesture<Value> { base.map { _ in nil as Value } }

    /// Runs when this gesture ends successfully on its captured entity.
    public func onEnded(_ action: @escaping @MainActor (EntityTargetValue<Base.Value>) -> Void) -> Self {
        var result = self; result.ended.append(action); return result
    }
}

extension EntityTargetGesture where Base.Value: Equatable {
    public func onChanged(_ action: @escaping @MainActor (EntityTargetValue<Base.Value>) -> Void) -> Self {
        var result = self; result.changed.append(action); result.equals = { $0 == $1 }; return result
    }
}

extension View {
    public func gesture<Base: Gesture>(_ gesture: EntityTargetGesture<Base>, including mask: GestureMask = .all) -> some View {
        modifier(TargetedGestureModifier(gesture: gesture, mask: mask, mode: .normal))
    }
    public func simultaneousGesture<Base: Gesture>(_ gesture: EntityTargetGesture<Base>, including mask: GestureMask = .all) -> some View {
        modifier(TargetedGestureModifier(gesture: gesture, mask: mask, mode: .simultaneous))
    }
    public func highPriorityGesture<Base: Gesture>(_ gesture: EntityTargetGesture<Base>, including mask: GestureMask = .all) -> some View {
        modifier(TargetedGestureModifier(gesture: gesture, mask: mask, mode: .highPriority))
    }
}

@MainActor
private struct TargetedGestureEvent<Value>: Equatable {
    let target: EntityTargetValue<Value>?
    let rawValue: Value
    let equals: ((Value, Value) -> Bool)?
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated {
            lhs.target?.entity === rhs.target?.entity && lhs.target?.viewportID == rhs.target?.viewportID &&
                (lhs.equals?(lhs.rawValue, rhs.rawValue) ?? true)
        }
    }
}

private enum TargetedGestureMode { case normal, simultaneous, highPriority }

@MainActor
private struct TargetedGestureModifier<Base: Gesture>: ViewModifier {
    let gesture: EntityTargetGesture<Base>
    let mask: GestureMask
    let mode: TargetedGestureMode
    @State private var hosts: [GameHostReference] = []
    @State private var origin = CGPoint.zero
    @State private var capture = TargetedInputCapture<Base.Value>()
    @GestureState private var isActive = false

    func body(content: Content) -> some View {
        let native = gesture.base.map { value -> TargetedGestureEvent<Base.Value> in
            MainActor.assumeIsolated {
                var target: EntityTargetValue<Base.Value>?
                if hosts.count == 1, let host = hosts.first?.host {
                    let offset = CGPoint(x: host.viewFrame.minX - origin.x, y: host.viewFrame.minY - origin.y)
                    let start = startPoint(value).map { CGPoint(x: $0.x - offset.x, y: $0.y - offset.y) }
                    target = capture.resolve(value, start: start, host: host, resolver: gesture.resolve)
                    target?.viewOffset = offset
                }
                return TargetedGestureEvent(target: target, rawValue: value, equals: gesture.equals)
            }
        }.updating($isActive) { _, active, _ in active = true }
        .onChanged { event in
            MainActor.assumeIsolated {
                guard let target = event.target else { return }
                for action in gesture.changed { action(target) }
            }
        }.onEnded { event in
            MainActor.assumeIsolated {
                defer { capture.end() }
                if let target = event.target { for action in gesture.ended { action(target) } }
            }
        }
        return attach(native, to: content)
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { origin = $0 }
            .onPreferenceChange(GameHostPreferenceKey.self) { references in
                Task { @MainActor in
                    if references != hosts { capture.end() }
                    hosts = references
                }
            }
            .onChange(of: isActive) { _, active in if !active { capture.end() } }
            .onDisappear { capture.end() }
    }

    @ViewBuilder
    private func attach<G: Gesture>(_ native: G, to content: Content) -> some View {
        switch mode {
        case .normal: content.gesture(native, including: mask)
        case .simultaneous: content.simultaneousGesture(native, including: mask)
        case .highPriority: content.highPriorityGesture(native, including: mask)
        }
    }

    private func startPoint(_ value: Base.Value) -> CGPoint? {
        if let drag = value as? DragGesture.Value { return drag.startLocation }
        if let tap = value as? SpatialTapGesture.Value { return tap.location }
        return nil
    }
}

/// A captured entity and the underlying gesture's value. Point conversions use
/// the displayed transforms, including camera zoom, rotation, and animation.
@MainActor @dynamicMemberLookup
public struct EntityTargetValue<Value> {
    public let entity: Entity
    public let gestureValue: Value
    /// The pane captured at pointer-down, or nil for a legacy single-view host.
    /// Conversions keep using this pane's camera even after crossing a split.
    public let viewportID: String?
    weak var host: GameHost?
    var viewOffset = CGPoint.zero
    var viewportLatch: InputViewportLatch?
    var contact: InputContact?

    init(entity: Entity, gestureValue: Value, host: GameHost?, viewportID: String? = nil) {
        self.entity = entity; self.gestureValue = gestureValue; self.host = host; self.viewportID = viewportID
    }

    public subscript<T>(dynamicMember keyPath: KeyPath<Value, T>) -> T { gestureValue[keyPath: keyPath] }

    /// Converts a gesture point into scene space. Prefer `convertIfAvailable` when
    /// retaining a gesture value beyond the view's lifetime; this returns zero if detached.
    public func convert(_ point: CGPoint, to space: GameCoordinateSpace) -> SIMD2<Float> {
        convertIfAvailable(point, to: space) ?? .zero
    }
    public func convertIfAvailable(_ point: CGPoint, to space: GameCoordinateSpace) -> SIMD2<Float>? {
        scenePoint(point)
    }
    public func convert(_ point: CGPoint, to entity: Entity) -> SIMD2<Float> {
        convertIfAvailable(point, to: entity) ?? .zero
    }
    public func convertIfAvailable(_ point: CGPoint, to entity: Entity) -> SIMD2<Float>? {
        guard let host, entity.world === host.world, let node = host.renderer.node(for: entity) else { return nil }
        guard let scene = scenePoint(point) else { return nil }
        let point = node.convert(CGPoint(x: CGFloat(scene.x), y: CGFloat(scene.y)), from: host.renderer)
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return [Float(point.x), Float(point.y)]
    }
    private func scenePoint(_ point: CGPoint) -> SIMD2<Float>? {
        guard let host, contact?.cancelled != true else { return nil }
        if let viewportLatch, !viewportLatch.isValid(in: host.renderer) {
            contact?.cancelled = true
            return nil
        }
        return host.inputScenePoint(fromView: localPoint(point), viewportID: viewportID)
    }
    private func localPoint(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - viewOffset.x, y: point.y - viewOffset.y) }
}

extension EntityTargetValue: Equatable where Value: Equatable {
    public nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated { lhs.entity === rhs.entity && lhs.viewportID == rhs.viewportID && lhs.gestureValue == rhs.gestureValue }
    }
}

public struct GameCoordinateSpace: Sendable {
    public static let scene = GameCoordinateSpace()
}
